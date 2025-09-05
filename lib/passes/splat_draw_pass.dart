// lib/passes/splat_draw_pass.dart
//
// Draws Gaussian splats using the uploaded SplatSource and OrderTexture.
// Loads its own program once, caches uniform locations, sets all GL state it needs.

import 'package:flutter/services.dart' as flutter_services;
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/camera/camera.dart';
import 'package:flutter_gaussian_splatter/constants.dart';
import 'package:flutter_gaussian_splatter/data/order_texture.dart';
import 'package:flutter_gaussian_splatter/data/splat_source.dart';
import 'package:flutter_gaussian_splatter/gl/gl_capabilities.dart';
import 'package:flutter_gaussian_splatter/gl/shader_factory.dart';
import 'package:flutter_gaussian_splatter/renderer/render_pass.dart';
import 'package:vector_math/vector_math.dart';

/// Renders Gaussian splats using depth-sorted order and instanced drawing.
class SplatDrawPass extends RenderPass {
  /// Creates a splat drawing pass with the given source data and order texture.
  SplatDrawPass({
    required this.source,
    required this.order,
    this.disableAlphaWrite = true,
    this.maxSplatPixelSize = 1024.0,
    this.vsAsset = 'packages/flutter_gaussian_splatter/shaders/vertex.glsl',
    this.fsAsset = 'packages/flutter_gaussian_splatter/shaders/frag.glsl',
  });

  /// Source of Gaussian splat data and textures.
  final SplatSource source;
  
  /// Texture containing depth-sorted splat indices.
  final OrderTexture order;

  /// Saves GPU memory bandwidth by preventing writes to the alpha channel of
  /// the framebuffer.
  /// Benefit: Reduces GPU memory bandwidth by ~25%
  /// (writing 3 channels instead of 4)
  /// Cost: Can't composite the rendered texture with other elements using its
  ///  alpha channel (needed to blend with Flutter UI)
  bool disableAlphaWrite;
  
  /// Maximum allowed splat size in pixels before culling.
  final double maxSplatPixelSize;
  
  /// Asset path to the vertex shader.
  final String vsAsset;
  
  /// Asset path to the fragment shader.  
  final String fsAsset;

  Program? _prog;
  UniformLocation? _uProjection;
  UniformLocation? _uView;
  UniformLocation? _uFocal;
  UniformLocation? _uViewport;
  UniformLocation? _uSplatCount;
  UniformLocation? _uOrderTexture;
  UniformLocation? _uTexture;
  UniformLocation? _uMaxSplatSize;
  int? _aPosition;
  Buffer? _vbo;
  Buffer? _ebo;
  int _indicesPerBatch = 0;
  int _instanceCount = 0;

  @override
  String get name => 'splatt_pass';

  @override
  Future<void> init(RenderingContext gl, {Caps? caps}) async {
    var vs = await flutter_services.rootBundle.loadString(vsAsset);
    final fs = await flutter_services.rootBundle.loadString(fsAsset);

    // Add shader define based on texture format support
    if (caps?.hasIntegerTex ?? false) {
      vs = injectAfterVersion(vs, '#define USE_INTEGER_TEXTURE');
    }

    _prog = ShaderFactory.compile(gl,
        vertexSource: vs, fragmentSource: fs, attribBindings: {'position': 0},);

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
    if (_uTexture != null) {
      gl.uniform1i(_uTexture!, 0); // splat atlas -> TEXTURE0
    }
    if (_uOrderTexture != null) {
      gl.uniform1i(_uOrderTexture!, 1); // order map -> TEXTURE1
    }
  }

  void _cacheAttributeLocations(RenderingContext gl) {
    final positionLoc = gl.getAttribLocation(_prog!, 'position').id as int?;

    // Guard against -1 (not found) or null
    _aPosition = (positionLoc != null && positionLoc >= 0) ? positionLoc : null;
  }

  @override
  void dispose(RenderingContext gl) {
    if (_prog != null) gl.deleteProgram(_prog!);
    if (_vbo != null) gl.deleteBuffer(_vbo!);
    if (_ebo != null) gl.deleteBuffer(_ebo!);
    _prog = null;
    _vbo = null;
    _ebo = null;
    _aPosition = null;
    _uProjection = _uView = _uFocal = _uViewport =
        _uSplatCount = _uOrderTexture = _uTexture = _uMaxSplatSize = null;
  }

  /// Enables or disables alpha channel writes to the framebuffer.
  void setDisableAlphaWrite(bool v) => disableAlphaWrite = v;

  /// Call when splat count changes.
  void onSourceChanged() => _recomputeInstanceCount();

  @override
  void execute(
    RenderingContext gl,
    Camera cam, {
    Matrix4? projectionMatrix,
    Matrix4? viewMatrix,
  }) {
    if (_prog == null ||
        source.texture == null ||
        source.splatCount == 0 ||
        projectionMatrix == null ||
        viewMatrix == null) {
      return;
    }

    // Pipeline state (viewport already set by main renderer)
    gl
      // We need to enable if we want to merge with 3D content
      ..disable(WebGL.DEPTH_TEST)
      ..depthMask(false)
      // ..depthFunc(WebGL.LEQUAL)
      ..enable(WebGL.BLEND)
      ..blendFuncSeparate(WebGL.ONE, WebGL.ONE_MINUS_SRC_ALPHA, WebGL.ONE,
          WebGL.ONE_MINUS_SRC_ALPHA,)
      ..blendEquationSeparate(WebGL.FUNC_ADD, WebGL.FUNC_ADD);

    if (disableAlphaWrite) gl.colorMask(true, true, true, false);

    // Program + uniforms
    gl.useProgram(_prog);
    if (_uProjection != null) {
      gl.uniformMatrix4fv(_uProjection!, false, projectionMatrix.storage);
    }
    if (_uView != null) {
      gl.uniformMatrix4fv(_uView!, false, viewMatrix.storage);
    }
    if (_uFocal != null) {
      gl.uniform2f(_uFocal!, cam.focalXForShader(), cam.focalYForShader());
    }
    if (_uViewport != null) {
      gl.uniform2f(_uViewport!, cam.width.toDouble(), cam.height.toDouble());
    }
    if (_uSplatCount != null) gl.uniform1i(_uSplatCount!, source.splatCount);
    if (_uMaxSplatSize != null) {
      gl.uniform1f(_uMaxSplatSize!, maxSplatPixelSize);
    }

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
          WebGL.UNSIGNED_SHORT, 0, _instanceCount,);

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
          WebGL.ARRAY_BUFFER, Float32Array.fromList(verts), WebGL.STATIC_DRAW,);

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
          WebGL.STATIC_DRAW,);

    _indicesPerBatch = GsConst.splatsPerInstance * 6;
  }

  void _recomputeInstanceCount() {
    const batch = GsConst.splatsPerInstance;
    _instanceCount = (source.splatCount + batch - 1) ~/ batch;
  }

  /// Injects a shader define after the #version directive.
  String injectAfterVersion(String src, String defineLine) {
    // Strip UTF-8 BOM if present (some editors add it)
    if (src.isNotEmpty && src.codeUnitAt(0) == 0xFEFF) {
      src = src.substring(1);
    }
    final lines = src.split('\n');
    final v = lines.indexWhere((l) => l.trimLeft().startsWith('#version'));
    if (v >= 0) {
      lines.insert(v + 1, defineLine);
      return lines.join('\n');
    }
    // If no #version is present (shouldn’t happen), don’t inject before it.
    return src;
  }
}
