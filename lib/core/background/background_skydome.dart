import 'dart:async'; // For unawaited
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' as services;
import 'package:flutter_angle/flutter_angle.dart';

/// Minimal, optional equirectangular skydome background.
class SkydomeBackground {
  /// Creates a [SkydomeBackground] bound to the provided WebGL context.
  SkydomeBackground(this._gl);

  /// Underlying WebGL rendering context.
  final RenderingContext _gl;

  Program? _prog;
  UniformLocation? _uBg;
  UniformLocation? _uViewport;
  UniformLocation? _uFocal;
  UniformLocation? _uInvViewRot;
  UniformLocation? _uBgRot;

  WebGLTexture? _tex;
  bool _ready = false;

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

  /// Whether the skydome is initialized and ready to be drawn.
  bool get isReady => _ready;

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
    _ready = true;
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
    if (!_ready || _prog == null || _tex == null) return;

    _gl
      ..useProgram(_prog)
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
      0.0,
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
    if (_prog != null) {
      try {
        _gl.deleteProgram(_prog!);
      } catch (_) {}
      _prog = null;
    }
    _uBg = _uViewport = _uFocal = _uInvViewRot = _uBgRot = null;
    _ready = false;
  }

  /// Compiles and links the skydome shader program and caches uniform locations.
  Future<void> _ensureProgram() async {
    if (_prog != null && _gl.isProgram(_prog!) == true) return;

    final vertexShaderCode = await services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_vert.glsl',
    );
    final fragmentShaderCode = await services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_frag.glsl',
    );

    final vs = _compile(WebGL.VERTEX_SHADER, vertexShaderCode);
    final fs = _compile(WebGL.FRAGMENT_SHADER, fragmentShaderCode);

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
      throw StateError('Skydome program link failed: $log');
    }

    _gl
      ..deleteShader(vs)
      ..deleteShader(fs);

    _prog = program;

    _uBg = _gl.getUniformLocation(_prog!, 'u_bg');
    _uViewport = _gl.getUniformLocation(_prog!, 'u_viewport');
    _uFocal = _gl.getUniformLocation(_prog!, 'u_focal');
    _uInvViewRot = _gl.getUniformLocation(_prog!, 'u_invViewRot');
    _uBgRot = _gl.getUniformLocation(_prog!, 'u_bgRot');
  }

  /// Compiles a shader of [type] from [src] and returns the created shader.
  ///
  /// Throws a [StateError] if compilation fails.
  WebGLShader _compile(int type, String src) {
    final sh = _gl.createShader(type);
    _gl
      ..shaderSource(sh, src)
      ..compileShader(sh);
    final ok = _gl.getShaderParameter(sh, WebGL.COMPILE_STATUS);
    if (!ok) {
      final log = _gl.getShaderInfoLog(sh);
      _gl.deleteShader(sh);
      throw StateError(
        '${type == WebGL.VERTEX_SHADER ? 'Vertex' : 'Fragment'} compile failed:\n$log',
      );
    }
    return sh;
  }
}
