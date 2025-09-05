import 'dart:async'; // For unawaited
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' as services;
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/camera.dart';
import 'package:flutter_gaussian_splatter/core/gl_capabilities.dart';
import 'package:flutter_gaussian_splatter/gl/shader_factory.dart';
import 'package:flutter_gaussian_splatter/renderer/render_pass.dart';
import 'package:vector_math/vector_math.dart';

/// Minimal, optional equirectangular skydome background.
class SkyPass extends RenderPass {
  /// Creates a [SkyPass] bound to the provided WebGL context.
  SkyPass({required this.assetPath});

  @override
  String get name => 'Skydome';

  /// Assetpath
  final String assetPath;

  Program? _program;
  UniformLocation? _uBg;
  UniformLocation? _uViewport;
  UniformLocation? _uFocal;
  UniformLocation? _uInvViewRot;
  UniformLocation? _uBgRot;

  WebGLTexture? _tex;

  /// Whether the skydome is initialized and ready to be drawn.
  bool get isReady => _program != null && _tex != null;

  /// Background rotation as a 3x3 matrix (column-major).
  ///
  /// Initialized to identity.
  Float32List _bgRot = Float32List.fromList(<double>[
    1,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
  ]);

  /// Applies a yaw/pitch rotation (in **degrees**) to the background.
  ///
  /// Positive yaw rotates to the right around the Y axis; positive pitch
  /// rotates upward around the X axis. The resulting matrix is stored
  /// internally and
  /// applied during [execute].
  void setYawPitchDegrees(double yawDeg, double pitchDeg) {
    final y = yawDeg * math.pi / 180.0;
    final p = pitchDeg * math.pi / 180.0;
    final cy = math.cos(y);
    final sy = math.sin(y);
    final cp = math.cos(p);
    final sp = math.sin(p);

    _bgRot = Float32List.fromList(<double>[
      cy,
      sy * sp,
      sy * cp,
      0,
      cp,
      -sp,
      -sy,
      cy * sp,
      cy * cp,
    ]);
  }

  /// Releases GPU resources and resets internal state.
  @override
  void dispose(RenderingContext gl) {
    if (_tex != null) {
      try {
        gl.deleteTexture(_tex!);
      } catch (_) {}
      _tex = null;
    }
    if (_program != null) {
      try {
        gl.deleteProgram(_program!);
      } catch (_) {}
      _program = null;
    }
    _uBg = _uViewport = _uFocal = _uInvViewRot = _uBgRot = null;
  }

  @override

  /// Draws the skydome using the provided viewport and camera parameters.
  void execute(RenderingContext gl, GaussianCamera camera,
      {Matrix4? projectionMatrix, Matrix4? viewMatrix}) {
    if (_program == null || _tex == null) return;

    gl
      ..useProgram(_program)
      ..disable(WebGL.BLEND)
      ..disable(WebGL.DEPTH_TEST)
      ..activeTexture(WebGL.TEXTURE0)
      ..bindTexture(WebGL.TEXTURE_2D, _tex)
      ..uniform1i(_uBg!, 0)
      ..uniform2f(
        _uViewport!,
        camera.width.toDouble(),
        camera.height.toDouble(),
      )
      ..uniform2f(_uFocal!, camera.focalXForShader(), camera.focalYForShader())
      ..uniformMatrix3fv(_uInvViewRot!, false, camera.invViewRotation3x3())
      ..uniformMatrix3fv(_uBgRot!, false, _bgRot)
      ..drawArrays(WebGL.TRIANGLES, 0, 3);
  }

  @override
  Future<void> init(RenderingContext gl, {Caps? caps}) async {
    // Intentionally don't await; draw() will early-return until ready.
    unawaited(_ensureProgram(gl));
    // Loads the skydome texture from a Flutter asset and prepares mipmaps.
    // The shader program is ensured (compiled/linked) in the background; drawing
    // safely no-ops until both the program and texture are available.

    _tex ??= gl.createTexture();

    gl
      ..bindTexture(WebGL.TEXTURE_2D, _tex)
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
      ..texParameteri(
        WebGL.TEXTURE_2D,
        WebGL.TEXTURE_MIN_FILTER,
        WebGL.LINEAR_MIPMAP_LINEAR,
      )
      ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MAG_FILTER, WebGL.LINEAR)
      ..pixelStorei(WebGL.UNPACK_ALIGNMENT, 1);

    await gl.texImage2DfromAsset(
      WebGL.TEXTURE_2D,
      assetPath,
      internalformat: WebGL.RGBA,
      type: WebGL.UNSIGNED_BYTE,
    );

    gl.generateMipmap(WebGL.TEXTURE_2D);
  }

  /// Compiles and links the skydome shader program and caches uniform locations
  Future<void> _ensureProgram(RenderingContext gl) async {
    if (_program != null && gl.isProgram(_program!) == true) return;

    final vertexShaderCode = await services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_vert.glsl',
    );
    final fragmentShaderCode = await services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_frag.glsl',
    );

    _program = ShaderFactory.compile(
      gl,
      vertexSource: vertexShaderCode,
      fragmentSource: fragmentShaderCode,
    );

    _uBg = gl.getUniformLocation(_program!, 'u_bg');
    _uViewport = gl.getUniformLocation(_program!, 'u_viewport');
    _uFocal = gl.getUniformLocation(_program!, 'u_focal');
    _uInvViewRot = gl.getUniformLocation(_program!, 'u_invViewRot');
    _uBgRot = gl.getUniformLocation(_program!, 'u_bgRot');
  }
}
