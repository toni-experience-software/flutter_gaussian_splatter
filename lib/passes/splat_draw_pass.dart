// lib/passes/splat_draw_pass.dart
//
// Draws Gaussian splats using the uploaded SplatSource and OrderTexture.
// Loads its own program once, caches uniform locations, sets all GL state it needs.

import 'package:flutter/services.dart' as flutter_services;
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/camera.dart';
import 'package:flutter_gaussian_splatter/core/constants.dart';
import 'package:flutter_gaussian_splatter/data/order_texture.dart';
import 'package:flutter_gaussian_splatter/data/splat_source.dart';
import 'package:flutter_gaussian_splatter/gl/shader_factory.dart';
import 'package:vector_math/vector_math.dart';

class SplatDrawPass /* implements RenderPass */ {
  SplatDrawPass({
    required this.source,
    required this.order,
    this.disableAlphaWrite = true,
    this.maxSplatPixelSize = 1024.0,
    this.vsAsset = 'packages/flutter_gaussian_splatter/shaders/vertex.glsl',
    this.fsAsset = 'packages/flutter_gaussian_splatter/shaders/frag.glsl',
  });

  final SplatSource source;
  final OrderTexture order;
  final bool disableAlphaWrite;
  final double maxSplatPixelSize;
  final String vsAsset;
  final String fsAsset;

  Program? _prog;
  UniformLocation? _uProjection,
      _uView,
      _uFocal,
      _uViewport,
      _uSplatCount,
      _uOrderTexture,
      _uTexture,
      _uMaxSplatSize;
  int? _aPosition;
  Buffer? _vbo, _ebo;
  int _indicesPerBatch = 0;
  int _instanceCount = 0;

  Future<void> init(RenderingContext gl) async {
    final vs = await flutter_services.rootBundle.loadString(vsAsset);
    final fs = await flutter_services.rootBundle.loadString(fsAsset);
    _prog = ShaderFactory.compile(gl,
        vertexSource: vs, fragmentSource: fs, attribBindings: {'position': 0});

    _uProjection = gl.getUniformLocation(_prog!, 'projection');
    _uView = gl.getUniformLocation(_prog!, 'view');
    _uFocal = gl.getUniformLocation(_prog!, 'focal');
    _uViewport = gl.getUniformLocation(_prog!, 'viewport');
    _uSplatCount = gl.getUniformLocation(_prog!, 'splatCount');
    _uOrderTexture = gl.getUniformLocation(_prog!, 'u_orderTexture');
    _uTexture = gl.getUniformLocation(_prog!, 'u_texture');
    _uMaxSplatSize = gl.getUniformLocation(_prog!, 'uMaxSplatSize');
    _cacheAttributeLocations(gl);

    _createQuadBuffers(gl);
    _recomputeInstanceCount();

    // Bind samplers to fixed texture units once (no per-frame cost).
    gl.useProgram(_prog);
    if (_uTexture != null) gl.uniform1i(_uTexture!, 0); // splat atlas -> TEXTURE0
    if (_uOrderTexture != null) gl.uniform1i(_uOrderTexture!, 1); // order map -> TEXTURE1
  }

    void _cacheAttributeLocations(RenderingContext gl) {
    final positionLoc = gl.getAttribLocation(_prog!, 'position').id as int?;

    // Guard against -1 (not found) or null
    _aPosition = (positionLoc != null && positionLoc >= 0) ? positionLoc : null;
  }
  

  

  void dispose(RenderingContext gl) {
    if (_prog != null) gl.deleteProgram(_prog!);
    if (_vbo != null) gl.deleteBuffer(_vbo!);
    if (_ebo != null) gl.deleteBuffer(_ebo!);
    _prog = null;
    _vbo = null;
    _ebo = null;
    _aPosition = null;
    _uProjection = _uView = _uFocal =
        _uViewport = _uSplatCount = _uOrderTexture = _uTexture = _uMaxSplatSize = null;
  }

  /// Call when splat count changes.
  void onSourceChanged() => _recomputeInstanceCount();

  void execute(RenderingContext gl, GaussianCamera cam, {Matrix4? projectionMatrix, Matrix4? viewMatrix}) {
    if (_prog == null || source.texture == null || source.splatCount == 0) {
      return;
    }

    final proj = projectionMatrix ?? _makeProjection(
        cam.fx, cam.fy, cam.width.toDouble(), cam.height.toDouble());
    final view = viewMatrix ?? _makeView(cam);

    // Pipeline state (viewport already set by main renderer)
    gl..enable(WebGL.DEPTH_TEST)
      ..depthMask(false)
      ..depthFunc(WebGL.LEQUAL)
      ..enable(WebGL.BLEND)
      ..blendFuncSeparate(WebGL.ONE, WebGL.ONE_MINUS_SRC_ALPHA, WebGL.ONE,
          WebGL.ONE_MINUS_SRC_ALPHA)
      ..blendEquationSeparate(WebGL.FUNC_ADD, WebGL.FUNC_ADD);

    if (disableAlphaWrite) gl.colorMask(true, true, true, false);

    // Program + uniforms
    gl.useProgram(_prog);
    if (_uProjection != null)
      gl.uniformMatrix4fv(_uProjection!, false, proj.storage);
    if (_uView != null) gl.uniformMatrix4fv(_uView!, false, view.storage);
    if (_uFocal != null) gl.uniform2f(_uFocal!, cam.fx, cam.fy);
    if (_uViewport != null)
      gl.uniform2f(_uViewport!, cam.width.toDouble(), cam.height.toDouble());
    if (_uSplatCount != null) gl.uniform1i(_uSplatCount!, source.splatCount);
    if (_uMaxSplatSize != null)
      gl.uniform1f(_uMaxSplatSize!, maxSplatPixelSize);

    // Bind textures to the units we fixed above.
    gl
      ..activeTexture(WebGL.TEXTURE0)
      ..bindTexture(WebGL.TEXTURE_2D, source.texture);

    if (order.texture != null) {
      gl
        ..activeTexture(WebGL.TEXTURE1)
        ..bindTexture(WebGL.TEXTURE_2D, order.texture);
    }

    // Geometry
    if (_aPosition != null) {
      gl
        ..enableVertexAttribArray(_aPosition!)
        ..bindBuffer(WebGL.ARRAY_BUFFER, _vbo)
        ..vertexAttribPointer(_aPosition!, 3, WebGL.FLOAT, false, 0, 0);
    }

    gl
      ..bindBuffer(WebGL.ELEMENT_ARRAY_BUFFER, _ebo)
      ..drawElementsInstanced(WebGL.TRIANGLES, _indicesPerBatch,
          WebGL.UNSIGNED_SHORT, 0, _instanceCount);

    if (_aPosition != null) gl.disableVertexAttribArray(_aPosition!);
    if (disableAlphaWrite) gl.colorMask(true, true, true, true);
  }

  // --- helpers ---

  void _createQuadBuffers(RenderingContext gl) {
    final verts = <double>[];
    for (var q = 0; q < GsConst.splatsPerInstance; q++) {
      const corners = [
        [-1.0, -1.0],
        [1.0, -1.0],
        [1.0, 1.0],
        [-1.0, 1.0],
      ];
      for (final c in corners) {
        verts.addAll([c[0], c[1], q.toDouble()]);
      }
    }
    _vbo = gl.createBuffer();
    gl
      ..bindBuffer(WebGL.ARRAY_BUFFER, _vbo)
      ..bufferData(
          WebGL.ARRAY_BUFFER, Float32Array.fromList(verts), WebGL.STATIC_DRAW);

    final idx = <int>[];
    for (var q = 0; q < GsConst.splatsPerInstance; q++) {
      final b = q * 4;
      idx
        ..addAll([b + 0, b + 1, b + 2])
        ..addAll([b + 0, b + 2, b + 3]);
    }
    _ebo = gl.createBuffer();
    gl
      ..bindBuffer(WebGL.ELEMENT_ARRAY_BUFFER, _ebo)
      ..bufferData(WebGL.ELEMENT_ARRAY_BUFFER, Uint16Array.fromList(idx),
          WebGL.STATIC_DRAW);

    _indicesPerBatch = GsConst.splatsPerInstance * 6;
  }

  void _recomputeInstanceCount() {
    const batch = GsConst.splatsPerInstance;
    _instanceCount = (source.splatCount + batch - 1) ~/ batch;
  }

  static Matrix4 _makeProjection(double fx, double fy, double w, double h) {
    const zn = 0.2, zf = 200.0;
    final fovX = (2 * fx) / w;
    final fovY = (2 * fy) / h;
    const a = zf / (zf - zn);
    const b = -(zf * zn) / (zf - zn);
    return Matrix4(
      fovX,
      0,
      0,
      0,
      0,
      fovY,
      0,
      0,
      0,
      0,
      a,
      1,
      0,
      0,
      b,
      0,
    );
  }

  static Matrix4 _makeView(GaussianCamera cam) {
    final R = cam.rotation, t = cam.position;
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
}
