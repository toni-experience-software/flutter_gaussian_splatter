import 'dart:async'; // For unawaited
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' as services;
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/gl/shader_factory.dart';

/// Minimal, optional equirectangular skydome background.
class SkydomeBackground {
  /// Creates a [SkydomeBackground] bound to the provided WebGL context.
  SkydomeBackground(this._gl);

  /// Underlying WebGL rendering context.
  final RenderingContext _gl;

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

  /// Loads the skydome texture from a Flutter asset and prepares mipmaps.
  ///
  /// The shader program is ensured (compiled/linked) in the background; drawing
  /// safely no-ops until both the program and texture are available.
  Future<void> setImageFromAsset(String assetPath) async {
    // Intentionally don't await; draw() will early-return until ready.
    unawaited(_ensureProgram());

    _tex ??= _gl.createTexture();

    _gl
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

    await _gl.texImage2DfromAsset(
      WebGL.TEXTURE_2D,
      assetPath,
      internalformat: WebGL.RGBA,
      type: WebGL.UNSIGNED_BYTE,
    );

    _gl.generateMipmap(WebGL.TEXTURE_2D);
  }

  /// Draws the skydome using the provided viewport and camera parameters.
  ///
  /// - [width], [height]: current viewport size in logical pixels.
  /// - [fx], [fy]: focal lengths in pixels.
  /// - [invViewRot3x3]: camera inverse view rotation (3x3 matrix).
  void draw(
    int width,
    int height,
    double fx,
    double fy,
    Float32List invViewRot3x3,
  ) {
    if (_program == null || _tex == null) return;

    _gl
      ..useProgram(_program)
      ..disable(WebGL.BLEND)
      ..disable(WebGL.DEPTH_TEST)
      ..activeTexture(WebGL.TEXTURE0)
      ..bindTexture(WebGL.TEXTURE_2D, _tex)
      ..uniform1i(_uBg!, 0)
      ..uniform2f(_uViewport!, width.toDouble(), height.toDouble())
      ..uniform2f(_uFocal!, fx, fy)
      ..uniformMatrix3fv(_uInvViewRot!, false, invViewRot3x3)
      ..uniformMatrix3fv(_uBgRot!, false, _bgRot)
      ..drawArrays(WebGL.TRIANGLES, 0, 3);
  }

  /// Applies a yaw/pitch rotation (in **degrees**) to the background.
  ///
  /// Positive yaw rotates to the right around the Y axis; positive pitch
  /// rotates upward around the X axis. The resulting matrix is stored
  /// internally and
  /// applied during [draw].
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
  void dispose() {
    if (_tex != null) {
      try {
        _gl.deleteTexture(_tex!);
      } catch (_) {}
      _tex = null;
    }
    if (_program != null) {
      try {
        _gl.deleteProgram(_program!);
      } catch (_) {}
      _program = null;
    }
    _uBg = _uViewport = _uFocal = _uInvViewRot = _uBgRot = null;
  }

  /// Compiles and links the skydome shader program and caches uniform locations
  Future<void> _ensureProgram() async {
    if (_program != null && _gl.isProgram(_program!) == true) return;

    final vertexShaderCode = await services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_vert.glsl',
    );
    final fragmentShaderCode = await services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_frag.glsl',
    );

    _program = ShaderFactory.compile(
      _gl,
      vertexSource: vertexShaderCode,
      fragmentSource: fragmentShaderCode,
    );

    _uBg = _gl.getUniformLocation(_program!, 'u_bg');
    _uViewport = _gl.getUniformLocation(_program!, 'u_viewport');
    _uFocal = _gl.getUniformLocation(_program!, 'u_focal');
    _uInvViewRot = _gl.getUniformLocation(_program!, 'u_invViewRot');
    _uBgRot = _gl.getUniformLocation(_program!, 'u_bgRot');
  }
}
