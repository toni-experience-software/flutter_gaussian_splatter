// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/camera.dart';
import 'package:flutter_gaussian_splatter/core/covariance_calculator.dart';
import 'package:flutter_gaussian_splatter/core/depth_sorter.dart' as depth;
import 'package:vector_math/vector_math.dart';

/// Signature for callbacks delivered by [TextureGaussianRenderer].
typedef RendererCallback = void Function();

/// Immutable per‑frame rendering statistics.
@immutable
class RenderStats {
  /// Creates a new instance of [RenderStats].
  const RenderStats({
    required this.fps,
    required this.vertexCount,
    required this.lastFrameTime,
  });

  /// Estimated frames‑per‑second calculated from the last frame.
  final double fps;

  /// Number of vertices drawn in the last frame.
  final int vertexCount;

  /// Timestamp of the last rendered frame.
  final DateTime lastFrameTime;

  @override
  String toString() =>
      'RenderStats(fps: ${fps.toStringAsFixed(1)}, vtx: $vertexCount)';
}

/// Renders Gaussian splats into an in‑memory [FlutterAngleTexture].
///
/// This class encapsulates the full WebGL / ANGLE pipeline required by Gaussian
/// Splatting.  Life‑cycle:
/// ```dart
/// final renderer = TextureGaussianRenderer();
/// await renderer.initialize();
/// await renderer.setupTexture(width: 800, height: 600, vertexShaderCode: vs,
/// fragmentShaderCode: fs);
/// renderer.createAndSetDefaultCamera();
/// renderer.setSplatData(myBinarySplatBuffer);
/// renderer.startRenderLoop();
/// // drive [frame] from a SchedulerBinding / Ticker.
/// ```
///
/// All public APIs are `@mustCallSuper` lifecycle‑aware.
class TextureGaussianRenderer {
  // Dependencies & context
  late final FlutterAngle _angle;
  late FlutterAngleTexture _targetTexture;
  late RenderingContext _gl;

  // Shader program & uniforms
  Program? _program;
  UniformLocation? _uProjection;
  UniformLocation? _uView;
  UniformLocation? _uFocal;
  UniformLocation? _uViewport;
  UniformLocation? _uTexture;

  // Attribute locations (cached for perf)
  int? _aPosition;
  int? _aIndex;

  // Buffers & textures
  Buffer? _vertexBuffer;
  Buffer? _indexBuffer;
  WebGLTexture? _texture; // Splat data texture

  // Core helpers
  late final depth.DepthSorterImpl _depthSorter;

  // Render state & matrices
  var _viewMatrix = Matrix4.identity();
  var _projectionMatrix = Matrix4.identity();
  GaussianCamera? _camera;

  // Splat data & vertices
  int _vertexCount = 0;
  Uint8List? _splatBuffer;
  int _splatCount = 0;

  // Timing & FPS
  bool _isRendering = false;
  DateTime _lastFrameTime = DateTime.timestamp();
  double _fps = 0;

  // Viewport size (logical px)
  double _width = 1;
  double _height = 1;

  // Shader sources (kept for context‑loss recovery)
  late final String _vertexShaderSource;
  late final String _fragmentShaderSource;

  // Scratch arrays (re‑used to avoid per‑frame allocs)
  Float32Array? _scratchDepthArray;
  Float32Array? _persistentIndexArray;

  // Public API

  /// Latest frame statistics.
  RenderStats get renderStats => RenderStats(
        fps: _fps,
        vertexCount: _vertexCount,
        lastFrameTime: _lastFrameTime,
      );

  /// Currently active camera (immutable).
  GaussianCamera? get camera => _camera;

  /// The texture that can be composed into UI using [FlutterAngleTexture]
  /// widget helpers.
  FlutterAngleTexture get targetTexture => _targetTexture;

  // Life‑cycle

  /// Initializes ANGLE and the depth‑sorter. Must be called before any other
  /// method.
  Future<void> initialize({bool debug = true}) async {
    _angle = FlutterAngle();
    await _angle.init(debug);

    _depthSorter = depth.DepthSorterImpl(onSortComplete: _onDepthSortComplete);
    await _depthSorter.initialize();
  }

  /// Creates a texture and compiles the shaders.  Safe to call multiple times –
  /// resources are recreated if needed.
  Future<void> setupTexture({
    required double width,
    required double height,
    required String vertexShaderCode,
    required String fragmentShaderCode,
  }) async {
    assert(width > 0 && height > 0, 'Viewport must be non‑zero');

    _width = width;
    _height = height;
    _vertexShaderSource = vertexShaderCode;
    _fragmentShaderSource = fragmentShaderCode;

    _targetTexture = await _angle.createTexture(
      AngleOptions(
        width: width.toInt(),
        height: height.toInt(),
        dpr: 1,
        alpha: true, // RGBA8888 everywhere.
        useSurfaceProducer: true, // Avoid legacy pbuffers.
        customRenderer: false,
      ),
    );

    _gl = _targetTexture.getContext();
    await _compileShaders();
    await _createBuffers();
    _updateProjectionMatrix();
  }

  /// Starts the internal render loop. Idempotent.
  void startRenderLoop() => _isRendering = true;

  /// Stops the internal render loop. Idempotent.
  void stopRenderLoop() => _isRendering = false;

  /// Drives a single frame.  Call from a `Ticker` / `SchedulerBinding`.
  Future<void> frame() async {
    if (!_isRendering) return;

    _updateFps();

    if (_splatBuffer != null && _camera != null && _splatCount > 0) {
      final vp = _projectionMatrix.multiplied(_viewMatrix);
      _depthSorter.throttledSort(vp, _splatBuffer!, _splatCount);
    }

    _draw();
  }

  /// Sets the active [GaussianCamera] and updates matrices.
  void setCamera(GaussianCamera camera) {
    _camera = camera;
    _updateViewMatrix();
    _updateProjectionMatrix();
  }

  /// Creates a reasonable default camera and makes it active. Returns the newly
  /// created camera so that callers can further tweak it if desired.
  GaussianCamera createDefaultCamera({
    double horizontalFovDegrees = 70.0,
    Vector3? position,
    Matrix3? rotation,
  }) {
    final cam = GaussianCamera.createDefault(
      width: _width,
      height: _height,
      horizontalFovDegrees: horizontalFovDegrees,
      position: position,
      rotation: rotation,
    );
    setCamera(cam);
    return cam;
  }

  /// Supplies raw splat data (32 bytes per splat) and rebuilds the GPU texture.
  /// Throws [ArgumentError] if the buffer length is not a multiple of 32.
  void setSplatData(Uint8List data) {
    if (data.length % _bytesPerSplat != 0) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'Must be a multiple of 32',
      );
    }
    _splatBuffer = data;
    _splatCount = data.length ~/ _bytesPerSplat;
    _uploadSplatTexture(data);
  }

  /// Resizes the render target. If a camera is set, its intrinsics are updated
  /// to preserve the current field‑of‑view.
  Future<void> resize(double width, double height) async {
    if (width == _width && height == _height) return;

    final previousTexture = _targetTexture;
    final previousWidth = _width;
    final previousHeight = _height;

    _width = width;
    _height = height;

    // Preserve FOV.
    _camera = _camera?.withUpdatedViewport(newWidth: width, newHeight: height);

    try {
      _targetTexture = await _angle.createTexture(
        AngleOptions(
          width: width.toInt(),
          height: height.toInt(),
          dpr: 1,
          alpha: true,
          useSurfaceProducer: true,
          customRenderer: false,
        ),
      );

      final newGl = _targetTexture.getContext();
      final contextSurvived =
          _gl == newGl && _program != null && _gl.isProgram(_program!) == true;

      _gl = newGl;
      _angle.dispose([previousTexture]);

      if (contextSurvived) {
        _updateProjectionMatrix();
        _updateViewMatrix();
      } else {
        await _recoverFromContextLoss();
      }
    } catch (error, stack) {
      // Roll back so caller sees a consistent state.
      _width = previousWidth;
      _height = previousHeight;
      debugPrint('Resize failed: $error\n$stack');
      rethrow;
    }
  }

  /// Disposes *all* resources. The instance must not be used afterwards.
  void dispose() {
    stopRenderLoop();

    _scratchDepthArray = null;
    _persistentIndexArray = null;

    _disposeGlResources();

    try {
      _angle.dispose([_targetTexture]);
    } catch (e) {
      debugPrint('Warning: error disposing target texture: $e');
    }

    try {
      _depthSorter.dispose();
    } catch (e) {
      debugPrint('Warning: error disposing depth sorter: $e');
    }
  }

  // Internal helpers – shader compilation & buffers

  Future<void> _compileShaders() async {
    if (_program != null && _gl.isProgram(_program!) == true) return;

    _disposeProgram();

    final vs = _compileShader(WebGL.VERTEX_SHADER, _vertexShaderSource);
    final fs = _compileShader(WebGL.FRAGMENT_SHADER, _fragmentShaderSource);

    final program = _gl.createProgram();
    _gl
      ..attachShader(program, vs)
      ..attachShader(program, fs)
      ..linkProgram(program);

    final linked = _gl.getProgramParameter(program, WebGL.LINK_STATUS).id == 1;
    if (!linked) {
      final log = _gl.getProgramInfoLog(program);
      _gl
        ..deleteShader(vs)
        ..deleteShader(fs)
        ..deleteProgram(program);
      throw StateError('Program link failed: $log');
    }

    // Shaders no longer needed after linking.
    _gl
      ..deleteShader(vs)
      ..deleteShader(fs);

    _program = program;

    _cacheUniformLocations();
    _cacheAttributeLocations();
  }

  WebGLShader _compileShader(int type, String source) {
    final shader = _gl.createShader(type);
    _gl
      ..shaderSource(shader, source)
      ..compileShader(shader);

    final compiled = _gl.getShaderParameter(shader, WebGL.COMPILE_STATUS);
    if (!compiled) {
      final log = _gl.getShaderInfoLog(shader);
      _gl.deleteShader(shader);
      throw StateError(
        '${type == WebGL.VERTEX_SHADER ? 'Ver' : 'Frag'} shader fail:\n$log',
      );
    }
    return shader;
  }

  Future<void> _createBuffers() async {
    _disposeBuffers();

    const quadVertices = <double>[-2, -2, 2, -2, 2, 2, -2, 2];

    _vertexBuffer = _gl.createBuffer();
    _gl
      ..bindBuffer(WebGL.ARRAY_BUFFER, _vertexBuffer)
      ..bufferData(
        WebGL.ARRAY_BUFFER,
        Float32Array.fromList(Float32List.fromList(quadVertices)),
        WebGL.STATIC_DRAW,
      );

    _indexBuffer = _gl.createBuffer();
  }

  void _disposeProgram() {
    _uniformLocationCache.clear();
    if (_program != null) {
      _gl.deleteProgram(_program!);
      _program = null;
    }
  }

  void _disposeBuffers() {
    if (_vertexBuffer != null) {
      _gl.deleteBuffer(_vertexBuffer!);
      _vertexBuffer = null;
    }
    if (_indexBuffer != null) {
      _gl.deleteBuffer(_indexBuffer!);
      _indexBuffer = null;
    }
  }

  // Uniform / attribute cache helpers

  final Map<String, UniformLocation?> _uniformLocationCache = {};

  void _cacheUniformLocations() {
    _uProjection = _uniform('projection');
    _uView = _uniform('view');
    _uFocal = _uniform('focal'); // might be null if not in shader.
    _uViewport = _uniform('viewport');
    _uTexture = _uniform('u_texture');
  }

  void _cacheAttributeLocations() {
    _aPosition = _gl.getAttribLocation(_program!, 'position').id as int?;
    _aIndex = _gl.getAttribLocation(_program!, 'index').id as int?;
  }

  UniformLocation? _uniform(String name) => _uniformLocationCache.putIfAbsent(
        name,
        () => _gl.getUniformLocation(_program!, name),
      );

  // Depth‑sorting callback

  void _onDepthSortComplete(depth.SortResult result) {
    _gl.bindBuffer(WebGL.ARRAY_BUFFER, _indexBuffer);

    _scratchDepthArray ??= Float32Array(result.vertexCount);
    if (_scratchDepthArray!.length < result.vertexCount) {
      _scratchDepthArray = Float32Array(result.vertexCount);
    }

    for (var i = 0; i < result.vertexCount; i++) {
      _scratchDepthArray![i] = result.depthIndex[i].toDouble();
    }

    _gl.bufferData(WebGL.ARRAY_BUFFER, _scratchDepthArray, WebGL.DYNAMIC_DRAW);
    _vertexCount = result.vertexCount;
  }

  // Splat texture upload

  static const int _bytesPerSplat = 32;
  static const int _texWidth = 2048; // JS reference uses 1024*2.

  void _uploadSplatTexture(Uint8List buffer) {
    final splatCount = buffer.length ~/ _bytesPerSplat;
    final texHeight = ((2 * splatCount) / _texWidth).ceil();

    final fBuffer = Float32List.view(buffer.buffer);
    final uBuffer = Uint8List.view(buffer.buffer);

    // Send to depth‑sorter immediately (no throttling) so first frame is crisp.
    if (_camera != null) {
      final vp = _projectionMatrix.multiplied(_viewMatrix);
      _depthSorter.runSort(vp, buffer, splatCount);
    }

    final texData = Float32List(_texWidth * texHeight * 4);

    for (var original = 0; original < splatCount; original++) {
      final x = (original & 0x3ff) << 1; // lower 10 bits → column, doubled
      final y = original >> 10; // higher bits → row

      final p0Index = (y * _texWidth + x) * 4;
      final p1Index = p0Index + 4; // (x + 1, y)

      // Position (P0)
      texData[p0Index + 0] = fBuffer[8 * original + 0];
      texData[p0Index + 1] = fBuffer[8 * original + 1];
      texData[p0Index + 2] = fBuffer[8 * original + 2];
      texData[p0Index + 3] = 0; // Unused alpha per spec

      // Covariance & colour (P1)
      final scaleX = fBuffer[8 * original + 3];
      final scaleY = fBuffer[8 * original + 4];
      final scaleZ = fBuffer[8 * original + 5];

      final qx = uBuffer[32 * original + 28 + 0];
      final qy = uBuffer[32 * original + 28 + 1];
      final qz = uBuffer[32 * original + 28 + 2];
      final qw = uBuffer[32 * original + 28 + 3];

      final packedCov = packedCovariance(
        scaleX: scaleX,
        scaleY: scaleY,
        scaleZ: scaleZ,
        q0Byte: qx,
        q1Byte: qy,
        q2Byte: qz,
        q3Byte: qw,
      );

      texData[p1Index + 0] = intBitsToFloat(packedCov[0]);
      texData[p1Index + 1] = intBitsToFloat(packedCov[1]);
      texData[p1Index + 2] = intBitsToFloat(packedCov[2]);

      final r = uBuffer[32 * original + 24 + 0];
      final g = uBuffer[32 * original + 24 + 1];
      final b = uBuffer[32 * original + 24 + 2];
      var a = uBuffer[32 * original + 24 + 3];

      // 1) keep exponent < 255 → no NaNs, no driver canonicalisation
      if (a == 0xFF) a = 0xFE; // Clamp.

      final packedColour = r | (g << 8) | (b << 16) | (a << 24);
      texData[p1Index + 3] = Float32List.view(
        (Uint32List(1)..[0] = packedColour).buffer,
      )[0];
    }

    if (_texture != null) {
      _gl.deleteTexture(_texture!);
    }

    _texture = _gl.createTexture();
    _gl
      ..bindTexture(WebGL.TEXTURE_2D, _texture)
      ..texParameteri(
        WebGL.TEXTURE_2D,
        WebGL.TEXTURE_WRAP_S,
        WebGL.CLAMP_TO_EDGE,
      )
      ..texParameteri(
        WebGL.TEXTURE_2D,
        WebGL.TEXTURE_WRAP_T,
        WebGL.CLAMP_TO_EDGE,
      )
      ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MIN_FILTER, WebGL.NEAREST)
      ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MAG_FILTER, WebGL.NEAREST)
      ..texImage2D(
        WebGL.TEXTURE_2D,
        0,
        WebGL.RGBA32F,
        _texWidth,
        texHeight,
        0,
        WebGL.RGBA,
        WebGL.FLOAT,
        Float32Array.fromList(texData),
      );

    _uploadIndexBuffer(splatCount);
  }

  void _uploadIndexBuffer(int splatCount) {
    // Lazily create / resize persistent index array.
    _persistentIndexArray ??= Float32Array(splatCount);
    if (_persistentIndexArray!.length < splatCount) {
      _persistentIndexArray = Float32Array(splatCount);
    }

    for (var i = 0; i < splatCount; i++) {
      _persistentIndexArray![i] = i.toDouble();
    }

    _gl
      ..bindBuffer(WebGL.ARRAY_BUFFER, _indexBuffer)
      ..bufferData(
        WebGL.ARRAY_BUFFER,
        _persistentIndexArray,
        WebGL.DYNAMIC_DRAW,
      );

    _vertexCount = splatCount;
  }

  // Render helpers

  void _draw() {
    _gl
      ..viewport(0, 0, _width.toInt(), _height.toInt())
      ..clearColor(0, 0, 0, 0)
      ..clear(WebGL.COLOR_BUFFER_BIT | WebGL.DEPTH_BUFFER_BIT)
      ..disable(WebGL.DEPTH_TEST)
      ..enable(WebGL.BLEND)
      ..blendFuncSeparate(
        WebGL.ONE,
        WebGL.ONE_MINUS_SRC_ALPHA,
        WebGL.ONE,
        WebGL.ONE_MINUS_SRC_ALPHA,
      )
      ..blendEquationSeparate(WebGL.FUNC_ADD, WebGL.FUNC_ADD)
      ..useProgram(_program);

    if (_uProjection != null) {
      _gl.uniformMatrix4fv(_uProjection!, false, _projectionMatrix.storage);
    }
    if (_uView != null) {
      _gl.uniformMatrix4fv(_uView!, false, _viewMatrix.storage);
    }
    if (_uFocal != null && _camera != null) {
      _gl.uniform2f(_uFocal!, _camera!.fx, _camera!.fy);
    }
    if (_uViewport != null) {
      _gl.uniform2f(_uViewport!, _width, _height);
    }
    if (_uTexture != null) {
      _gl.uniform1i(_uTexture!, 0);
    }

    _gl
      ..activeTexture(WebGL.TEXTURE0)
      ..bindTexture(WebGL.TEXTURE_2D, _texture);

    if (_aPosition != null) {
      _gl
        ..enableVertexAttribArray(_aPosition!)
        ..bindBuffer(WebGL.ARRAY_BUFFER, _vertexBuffer)
        ..vertexAttribPointer(_aPosition!, 2, WebGL.FLOAT, false, 0, 0);
    }

    if (_aIndex != null) {
      _gl
        ..enableVertexAttribArray(_aIndex!)
        ..bindBuffer(WebGL.ARRAY_BUFFER, _indexBuffer)
        ..vertexAttribPointer(_aIndex!, 1, WebGL.FLOAT, false, 0, 0)
        ..vertexAttribDivisor(_aIndex!, 1);
    }

    _gl.drawArraysInstanced(WebGL.TRIANGLE_FAN, 0, 4, _vertexCount);
    _gl.gl.glFlush();
  }

  // Matrix helpers

  void _updateFps() {
    final now = DateTime.timestamp();
    final deltaMs = now.difference(_lastFrameTime).inMilliseconds;
    _fps = deltaMs > 0 ? 1000 / deltaMs : 0;
    _lastFrameTime = now;
  }

  void _updateProjectionMatrix() {
    if (_camera == null) return;
    _projectionMatrix = _makeProjectionMatrix(
      _camera!.fx,
      _camera!.fy,
      _width,
      _height,
    );
  }

  void _updateViewMatrix() {
    if (_camera == null) return;
    _viewMatrix = _makeViewMatrix(_camera!);
  }

  Matrix4 _makeProjectionMatrix(
    double fx,
    double fy,
    double width,
    double height,
  ) {
    const znear = 0.2;
    const zfar = 200.0;

    final fovX = (2 * fx) / width;
    final fovY = -(2 * fy) / height;
    const farNearRatio = zfar / (zfar - znear);
    const farNearProduct = -(zfar * znear) / (zfar - znear);

    return Matrix4(
      fovX, 0, 0, 0, // column 0
      0, fovY, 0, 0, // column 1
      0, 0, farNearRatio, 1, // column 2
      0, 0, farNearProduct, 0, // column 3
    );
  }

  Matrix4 _makeViewMatrix(GaussianCamera cam) {
    final R = cam.rotation;
    final t = cam.position;

    return Matrix4(
      R.row0.x,
      R.row0.y,
      R.row0.z,
      0,
      R.row1.x,
      R.row1.y,
      R.row1.z,
      0,
      R.row2.x,
      R.row2.y,
      R.row2.z,
      0,
      -t.x * R.row0.x - t.y * R.row1.x - t.z * R.row2.x,
      -t.x * R.row0.y - t.y * R.row1.y - t.z * R.row2.y,
      -t.x * R.row0.z - t.y * R.row1.z - t.z * R.row2.z,
      1,
    );
  }

  // Context‑loss recovery

  Future<void> _recoverFromContextLoss() async {
    _scratchDepthArray = null;
    _persistentIndexArray = null;

    _disposeGlResources();
    await _compileShaders();
    await _createBuffers();

    _updateProjectionMatrix();

    if (_splatBuffer != null && _splatCount > 0) {
      _uploadSplatTexture(_splatBuffer!);
    }
  }

  void _disposeGlResources() {
    _disposeProgram();
    _disposeBuffers();
    if (_texture != null) {
      _gl.deleteTexture(_texture!);
      _texture = null;
    }
  }
}
