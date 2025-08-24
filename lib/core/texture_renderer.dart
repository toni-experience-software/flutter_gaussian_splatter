import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/background/background_skydome.dart';
import 'package:flutter_gaussian_splatter/core/camera.dart';
import 'package:flutter_gaussian_splatter/core/constants.dart';
import 'package:flutter_gaussian_splatter/core/depth_sorter.dart' as depth;
import 'package:flutter_gaussian_splatter/core/perf/disjoint_query_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/glfinish_sampler_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/perf_profiler.dart';
import 'package:vector_math/vector_math.dart';

/// Signature for callbacks delivered by [TextureGaussianRenderer].
typedef RendererCallback = void Function();

/// Immutable per‑frame rendering performance statistics.
///
/// Performance is measured using exponentially weighted moving averages (EWMA)
/// with automatic GPU profiling when supported by the WebGL context.
@immutable
class RenderStats {
  /// Creates a new instance of [RenderStats].
  const RenderStats({
    required this.fps,
    required this.vertexCount,
    required this.lastFrameTime,
    this.cpuFrameTimeMs,
    this.gpuFrameTimeMs,
    this.profilerType,
  });

  /// CPU-based frames per second (smoothed with EWMA).
  ///
  /// This measures the total frame time from start to finish on the main
  /// thread.
  final double fps;

  /// Number of Gaussian splat vertices rendered in the last frame.
  final int vertexCount;

  /// Timestamp when the last frame was completed.
  final DateTime lastFrameTime;

  /// Average CPU frame time in milliseconds (smoothed with EWMA).
  ///
  /// Measures the time spent on the main thread per frame.
  final double? cpuFrameTimeMs;

  /// Average GPU frame time in milliseconds (smoothed with EWMA), if available.
  ///
  /// Only available when GPU timing extensions are supported. May be null
  /// if GPU profiling is unavailable or if measurements are not ready.
  final double? gpuFrameTimeMs;

  /// Type of performance profiler being used.
  ///
  /// - 'GPU': Using EXT_disjoint_timer_query for accurate GPU timing
  /// - 'Sampled': Using glFinish() sampling for approximate GPU timing
  /// - 'CPU': CPU-only timing fallback
  final String? profilerType;

  /// GPU-based frames per second, if GPU timing is available.
  double? get gpuFps => gpuFrameTimeMs != null && gpuFrameTimeMs! > 0
      ? 1000.0 / gpuFrameTimeMs!
      : null;

  /// True if GPU timing measurements are available.
  bool get hasGpuTiming => gpuFrameTimeMs != null;

  @override
  String toString() {
    final gpuInfo =
        hasGpuTiming ? ', gpu: ${gpuFrameTimeMs!.toStringAsFixed(1)}ms' : '';
    final profilerInfo = profilerType != null ? ' [$profilerType]' : '';
    return 'RenderStats(fps: ${fps.toStringAsFixed(1)}, vtx: $vertexCount$gpuInfo$profilerInfo)';
  }
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

  //Background
  SkydomeBackground? _bg;
  String? _bgAssetPath; // for reload after context loss

  // Attribute locations (cached for perf)
  int? _aPosition;
  int? _aIndex;

  // Buffers & textures
  Buffer? _vertexBuffer;
  Buffer? _indexBuffer;
  WebGLTexture? _texture; // Splat data texture

  // Core helpers
  late final depth.DepthSorterImpl _depthSorter;
  PerfProfiler? _perf;

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
  bool _inFrame = false;
  bool _needDepthSort = true;
  DateTime _lastFrameTime = DateTime.timestamp();
  double _fps = 0;
  double? _cpuFrameTimeMs;
  double? _gpuFrameTimeMs;
  String? _profilerType;
  bool _isResizing = false;

  // Shader sources (kept for context‑loss recovery)
  late final String _vertexShaderSource;
  late final String _fragmentShaderSource;

  // Scratch arrays (re‑used to avoid per‑frame allocs)
  Float32Array? _scratchDepthArray;
  Float32Array? _persistentIndexArray;

  // Public API

  /// Latest frame statistics with detailed performance profiling.
  RenderStats get renderStats => RenderStats(
        fps: _fps,
        vertexCount: _vertexCount,
        lastFrameTime: _lastFrameTime,
        cpuFrameTimeMs: _cpuFrameTimeMs,
        gpuFrameTimeMs: _gpuFrameTimeMs,
        profilerType: _profilerType,
      );

  /// The texture that can be composed into UI using [FlutterAngleTexture]
  /// widget helpers.
  FlutterAngleTexture get targetTexture => _targetTexture;

  /// Current viewport size that the renderer is configured for.
  Size? get currentSize => _camera == null
      ? null
      : Size(_camera!.width.toDouble(), _camera!.height.toDouble());

  /// The currently active [GaussianCamera], or `null` if not set.
  GaussianCamera? get camera => _camera;

  /// Sets the active [GaussianCamera] and updates matrices.
  set camera(GaussianCamera? camera) {
    if (camera == _camera) return;
    _camera = camera;
    _updateViewMatrix();
    _updateProjectionMatrix();
    _needDepthSort = true;
  }

  /// Enables the background using an asset image.
  Future<void> enableBackgroundFromAsset(String assetPath) async {
    _bg ??= SkydomeBackground(_gl);
    await _bg!.setImageFromAsset(assetPath);
    _bgAssetPath = assetPath;
  }

  /// Disables the background.
  void disableBackground() {
    _bg?.dispose();
    _bg = null;
    _bgAssetPath = null;
  }

  Float32List _invViewRot3x3() {
    final m = _viewMatrix.storage; // column-major
    final m00 = m[0], m01 = m[4], m02 = m[8];
    final m10 = m[1], m11 = m[5], m12 = m[9];
    final m20 = m[2], m21 = m[6], m22 = m[10];
    // inv(R) = R^T; pack column-major
    return Float32List.fromList([
      m00, m01, m02, // col0
      m10, m11, m12, // col1
      m20, m21, m22, // col2
    ]);
  }

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
    bool enableProfiling = false,
  }) async {
    assert(width > 0 && height > 0, 'Viewport must be non‑zero');

    _vertexShaderSource = vertexShaderCode;
    _fragmentShaderSource = fragmentShaderCode;

    _targetTexture = await _angle.createTexture(
      AngleOptions(
        width: width.toInt(),
        height: height.toInt(),
        dpr: 1, // TODO(jesper): support dpr?
        alpha: true,
        useSurfaceProducer: true,
      ),
    );

    _gl = _targetTexture.getContext();
    await _compileShaders();
    await _createBuffers();
    _updateProjectionMatrix();

    if (enableProfiling) {
      _perf = PerfProfiler.auto(_gl);

      // Determine profiler type for display
      if (_perf is DisjointQueryGpuProfiler) {
        _profilerType = 'GPU';
      } else if (_perf is GlFinishSamplerProfiler) {
        _profilerType = 'Sampled';
      } else {
        _profilerType = 'CPU';
      }
    } else {
      _perf = null;
      _profilerType = null;
    }
  }

  /// Starts the internal render loop. Idempotent.
  void startRenderLoop() => _isRendering = true;

  /// Stops the internal render loop. Idempotent.
  void stopRenderLoop() => _isRendering = false;

  /// Drives a single frame.  Call from a `Ticker` / `SchedulerBinding`.
  Future<void> frame() async {
    // Bail during resize/context swap
    // Reentrancy guard
    if (!_isRendering || _isResizing || _inFrame) return;

    // Guard readiness up front
    if (_program == null || _camera == null) return;

    _inFrame = true;
    try {
      _perf?.beginFrame();

      // Only sort when needed (camera changed)
      if (_needDepthSort && _splatBuffer != null && _splatCount > 0) {
        final vp = _projectionMatrix.multiplied(_viewMatrix);
        _depthSorter.throttledSort(vp, _splatBuffer!, _splatCount);
      }

      _perf?.markGpuBegin(_gl);
      _draw();
      _perf?.markGpuEnd(_gl);

      if (_perf != null) {
        final perfStats = _perf!.endFrame(_gl);
        _fps = perfStats.fps;
        _cpuFrameTimeMs = perfStats.cpuMsAvg;
        _gpuFrameTimeMs = perfStats.gpuMsAvg;
      }
      _lastFrameTime = DateTime.timestamp();
    } catch (_) {
      // Recovery path on GL/Program invalidation
      await _recoverFromContextLoss();
    } finally {
      _inFrame = false;
    }
  }

  /// Supplies raw splat data (32 bytes per splat) and rebuilds the GPU texture.
  /// Throws [ArgumentError] if the buffer length is not a multiple of 32.
  void setSplatData(Uint8List data) {
    if (data.length % GsConst.bytesPerSplat != 0) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'Must be a multiple of 32',
      );
    }
    _splatBuffer = data;
    _splatCount = data.length ~/ GsConst.bytesPerSplat;
    _needDepthSort = true;
    _uploadSplatTexture(data);
  }

  /// Resizes the render target. If a camera is set, its intrinsics are updated
  /// to preserve the current field‑of‑view.
  Future<bool> resize(GaussianCamera camera) async {
    if (_isResizing) return false;

    // No-op if size unchanged
    if (_camera != null &&
        camera.width == _camera!.width &&
        camera.height == _camera!.height) {
      return false;
    }

    _isResizing = true;
    try {
      // Camera becomes the source of truth - use setter to trigger depth sort
      this.camera = camera;

      final desired = AngleOptions(
        width: _camera!.width,
        height: _camera!.height,
        dpr: 1,
        alpha: true,
        useSurfaceProducer: true,
        customRenderer: false,
      );

      // ---- 1) Try in-place resize (preserves GL context & GL objects)
      try {
        await _angle.resize(_targetTexture, desired);
      } catch (_) {
        debugPrint('resize failed');
        // ignore and fall back below
      }

      // If resize worked, the plugin updates texture.options in place.
      if (_targetTexture.options.width == desired.width &&
          _targetTexture.options.height == desired.height) {
        _updateProjectionMatrix();
        _updateViewMatrix();
        return true;
      }

      // ---- 2) Fallback: create a new texture, switch, then free the old one
      final previousTexture = _targetTexture;
      final previousGl = _gl;

      FlutterAngleTexture? newTexture;
      try {
        newTexture = await _angle.createTexture(desired);
        final newGl = newTexture.getContext();

        // Switch targets
        _gl = newGl;
        _targetTexture = newTexture;

        // Since the RenderingContext wrapper instance changed,
        // rebuild GL objects
        _disposeGlResourcesForContext(previousGl);
        await _recoverFromContextLoss();

        // Free the old native texture (fixes leak)
        try {
          await _angle.deleteTexture(previousTexture);
        } catch (e) {
          debugPrint('Warning: deleting previous texture failed: $e');
        }

        _updateProjectionMatrix();
        _updateViewMatrix();
        return true;
      } catch (e, st) {
        // If we created a new texture, free it
        if (newTexture != null) {
          try {
            await _angle.deleteTexture(newTexture);
          } catch (ee) {
            debugPrint('Warning: deleting failed texture during rollback: $ee');
          }
        }
        // Roll back to previous target/context if still valid
        try {
          _targetTexture = previousTexture;
          _gl = previousTexture.getContext();
        } catch (ee) {
          debugPrint('Warning: cannot roll back to previous texture: $ee');
          rethrow;
        }
        debugPrint('Resize failed: $e\n$st');
        rethrow;
      }
    } finally {
      _isResizing = false;
    }
  }

  /// Disposes *all* resources. The instance must not be used afterwards.
  void dispose() {
    stopRenderLoop();

    _scratchDepthArray = null;
    _persistentIndexArray = null;

    _disposeGlResourcesForContext(_gl);

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

    try {
      _perf?.dispose();
    } catch (e) {
      debugPrint('Warning: error disposing profiler: $e');
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
        Float32Array.fromList(quadVertices),
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
    _needDepthSort = false;
  }

  // Splat texture upload

  // In texture_gaussian_renderer.dart, replace the _uploadSplatTexture method:
// ---- helper for int32 -> float32 bitcast ----
  @pragma('vm:prefer-inline')
  double _u32AsF32(int u) =>
      Float32List.view((Uint32List(1)..[0] = u).buffer)[0];

  void _uploadSplatTexture(Uint8List buffer) {
    final splatCount = buffer.length ~/ GsConst.bytesPerSplat;
    // New compact layout: 5 texels per splat
    const pixelsPerSplat = GsConst.pixelsPerSplat;
    final texHeight = ((pixelsPerSplat * splatCount) / GsConst.texWidth).ceil();

    final fBuffer = Float32List.view(buffer.buffer);
    final uBuffer = Uint8List.view(buffer.buffer);
    const floatsPerSplat = GsConst.bytesPerSplat ~/ 4; // e.g., 32

    // Send to depth-sorter immediately (no throttling) so first frame is crisp.
    if (_camera != null) {
      final vp = _projectionMatrix.multiplied(_viewMatrix);
      _depthSorter.runSort(vp, buffer, splatCount);
    }

    final texData = Float32Array(GsConst.texWidth * texHeight * 4);

    for (var idx = 0; idx < splatCount; idx++) {
      // MUST match vertex.glsl base_uv logic: (idx & 0x1ff) * 5 , idx >> 9
      final x = (idx & 0x1ff) * pixelsPerSplat;
      final y = idx >> 9;

      final p0Index = (y * GsConst.texWidth + x + 0) * 4;
      final p1Index = (y * GsConst.texWidth + x + 1) * 4;
      final p2Index = (y * GsConst.texWidth + x + 2) * 4;
      final p3Index = (y * GsConst.texWidth + x + 3) * 4;
      final p4Index = (y * GsConst.texWidth + x + 4) * 4;

      final fBase = floatsPerSplat * idx;
      final bBase = GsConst.bytesPerSplat * idx;

      // --- P0: position (xyz) + packed quaternion (w) ---
      texData[p0Index + 0] = fBuffer[fBase + 0]; // x
      texData[p0Index + 1] = fBuffer[fBase + 1]; // y
      texData[p0Index + 2] = fBuffer[fBase + 2]; // z
      // quaternion bytes at offsets 28..31
      final qx = uBuffer[bBase + 28 + 0];
      final qy = uBuffer[bBase + 28 + 1];
      final qz = uBuffer[bBase + 28 + 2];
      final qw = uBuffer[bBase + 28 + 3];
      final packedQuat = qx | (qy << 8) | (qz << 16) | (qw << 24);
      texData[p0Index + 3] = _u32AsF32(packedQuat);

      // --- P1: scale (xyz) + packed color (w) ---
      texData[p1Index + 0] = fBuffer[fBase + 3]; // sx
      texData[p1Index + 1] = fBuffer[fBase + 4]; // sy
      texData[p1Index + 2] = fBuffer[fBase + 5]; // sz
      // color bytes at offsets 24..27
      final r = uBuffer[bBase + 24 + 0];
      final g = uBuffer[bBase + 24 + 1];
      final b = uBuffer[bBase + 24 + 2];
      final a = uBuffer[bBase + 24 + 3];
      final packedColor = r | (g << 8) | (b << 16) | (a << 24);
      texData[p1Index + 3] = _u32AsF32(packedColor);

      // --- P2..P4: SH block (12 packed words) ---
      // We only need the *first 12 floats* (48 bytes) for the shader.
      final shFloatStart = (bBase + 32) >> 2; // float index
      // P2
      texData[p2Index + 0] = fBuffer[shFloatStart + 0];
      texData[p2Index + 1] = fBuffer[shFloatStart + 1];
      texData[p2Index + 2] = fBuffer[shFloatStart + 2];
      texData[p2Index + 3] = fBuffer[shFloatStart + 3];
      // P3
      texData[p3Index + 0] = fBuffer[shFloatStart + 4];
      texData[p3Index + 1] = fBuffer[shFloatStart + 5];
      texData[p3Index + 2] = fBuffer[shFloatStart + 6];
      texData[p3Index + 3] = fBuffer[shFloatStart + 7];
      // P4
      texData[p4Index + 0] = fBuffer[shFloatStart + 8];
      texData[p4Index + 1] = fBuffer[shFloatStart + 9];
      texData[p4Index + 2] = fBuffer[shFloatStart + 10];
      texData[p4Index + 3] = fBuffer[shFloatStart + 11];
    }

    // Upload
    if (_texture != null) _gl.deleteTexture(_texture!);

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
        GsConst.texWidth,
        texHeight,
        0,
        WebGL.RGBA,
        WebGL.FLOAT,
        texData,
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
    if (camera == null) return;

    _gl
      ..viewport(0, 0, camera!.width, camera!.height)
      ..clearColor(0, 0, 0, 0)
      ..clear(WebGL.COLOR_BUFFER_BIT | WebGL.DEPTH_BUFFER_BIT)
      ..disable(WebGL.DEPTH_TEST)
      ..disable(WebGL.BLEND); // no blend for skydome

    // --- optional background ---
    if (_bg?.isReady ?? false) {
      _bg!.draw(
        camera!.width,
        camera!.height,
        _camera!.fx,
        _camera!.fy,
        _invViewRot3x3(),
      );
    }

    if (camera == null || _splatBuffer == null || _splatCount <= 0) {
      return; // Nothing to draw
    }

    _gl
      // ..viewport(0, 0, camera!.width, camera!.height)
      // ..clearColor(0, 0, 0, 0)
      // ..clear(WebGL.COLOR_BUFFER_BIT | WebGL.DEPTH_BUFFER_BIT)
      // ..disable(WebGL.DEPTH_TEST)
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
      _gl.uniform2f(
        _uViewport!,
        camera!.width.toDouble(),
        camera!.height.toDouble(),
      );
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

    // Unbind resources after drawing to prevent disposal issues
    _gl.bindTexture(WebGL.TEXTURE_2D, null);
  }

  // Matrix helpers

  void _updateProjectionMatrix() {
    if (_camera == null) return;
    _projectionMatrix = _makeProjectionMatrix(
      _camera!.fx,
      _camera!.fy,
      _camera!.width.toDouble(),
      _camera!.height.toDouble(),
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
    final fovY = (2 * fy) / height;
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
    // Drop stale CPU-side caches
    _scratchDepthArray = null;
    _persistentIndexArray = null;

    // Ensure any leftover GL objects (if any) are gone on the *current* context.
    // Safe no-op when nothing exists.
    try {
      _disposeGlResourcesForContext(_gl);
    } catch (_) {}

    // Rebuild GPU state; if this fails once, leave things null and let next
    //frame retry.
    try {
      await _compileShaders();
      await _createBuffers();
    } catch (e) {
      debugPrint('Recover failed, will retry next frame: $e');
      return; // leave program/buffers null; next call to frame() can try again
    }

    _updateProjectionMatrix();

    //old profiler holds queries & GL pointers from the previous context.
    try {
      _perf?.dispose();
    } catch (_) {}

    // Recreate profiler with same settings as original setup
    final enableProfiling = _profilerType != null;
    if (enableProfiling) {
      _perf = PerfProfiler.auto(_gl);
      if (_perf is DisjointQueryGpuProfiler) {
        _profilerType = 'GPU';
      } else if (_perf is GlFinishSamplerProfiler) {
        _profilerType = 'Sampled';
      } else {
        _profilerType = 'CPU';
      }
    } else {
      _perf = null;
    }

    // Re-upload content if available
    if (_splatBuffer != null && _splatCount > 0) {
      _uploadSplatTexture(_splatBuffer!);
    }

    // Recreate background with new context if previously enabled
    if (_bg != null) {
      try {
        _bg!.dispose();
      } catch (_) {}
      _bg = SkydomeBackground(_gl);
      if (_bgAssetPath != null) {
        try {
          await _bg!.setImageFromAsset(_bgAssetPath!);
        } catch (_) {}
      }
    }
  }

  void _disposeGlResourcesForContext(RenderingContext gl) {
    try {
      gl
        ..bindTexture(WebGL.TEXTURE_2D, null)
        ..bindBuffer(WebGL.ARRAY_BUFFER, null)
        ..useProgram(null);
    } catch (_) {}

    if (_program != null && gl.isProgram(_program!) == true) {
      try {
        gl.deleteProgram(_program!);
      } catch (_) {}
    }
    _program = null;
    _uProjection = null;
    _uView = null;
    _uFocal = null;
    _uViewport = null;
    _uTexture = null;
    _aPosition = null;
    _aIndex = null;
    _uniformLocationCache.clear();

    if (_vertexBuffer != null) {
      try {
        gl.deleteBuffer(_vertexBuffer!);
      } catch (_) {}
      _vertexBuffer = null;
    }

    if (_indexBuffer != null) {
      try {
        gl.deleteBuffer(_indexBuffer!);
      } catch (_) {}
      _indexBuffer = null;
    }

    if (_texture != null) {
      try {
        gl.deleteTexture(_texture!);
      } catch (_) {}
      _texture = null;
    }
  }
}
