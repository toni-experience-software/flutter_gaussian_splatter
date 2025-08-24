import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' as flutter_services;
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter/foundation.dart';

/// Minimal, optional equirectangular skydome background.
/// Draw *before* your splat pass; no blending needed here.
class SkydomeBackground {
  SkydomeBackground(this._gl);

  final RenderingContext _gl;

  Program? _prog;
  UniformLocation? _uBg;
  UniformLocation? _uViewport;
  UniformLocation? _uFocal;
  UniformLocation? _uInvViewRot;
  WebGLTexture? _tex;
  int _imgW = 0;
  int _imgH = 0;
  bool _ready = false;
  UniformLocation? _uBgRot;
  Float32List _bgRot = Float32List.fromList([
    1, 0, 0, 0, 1, 0, 0, 0, 1 // identity
  ]);

  bool get isReady => _ready;

  // ---- Public API -----------------------------------------------------------

  /// Loads an image from the asset bundle and uploads it as a texture.
  Future<void> setImageFromAsset(String assetPath) async {
    _ensureProgram();
    _tex ??= _gl.createTexture();
    _gl
      ..bindTexture(WebGL.TEXTURE_2D, _tex)
      ..texParameteri(
          WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_S, WebGL.CLAMP_TO_EDGE)
      ..texParameteri(
          WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_T, WebGL.CLAMP_TO_EDGE)
      ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MIN_FILTER,
          WebGL.LINEAR_MIPMAP_LINEAR)
      ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MAG_FILTER, WebGL.LINEAR)
      ..pixelStorei(WebGL.UNPACK_ALIGNMENT, 1);

    // IMPORTANT: override the bad defaults (RGBA32UI/UNSIGNED_INT)
    await _gl.texImage2DfromAsset(
      WebGL.TEXTURE_2D,
      assetPath,
      internalformat: WebGL.RGBA,
      type: WebGL.UNSIGNED_BYTE,
    );

    // Query width/height if you need them later (optional)
    // If not easily available, you can ignore _imgW/_imgH for assets.
    _gl.generateMipmap(WebGL.TEXTURE_2D);
    _ready = true;
  }

  /// Draws the skydome to the current framebuffer. Call before enabling blending.
  void draw(
      int width, int height, double fx, double fy, Float32List invViewRot3x3) {
    if (!_ready || _prog == null || _tex == null) return;

    // State for opaque background
    _gl
      ..useProgram(_prog)
      ..disable(WebGL.BLEND)
      ..disable(WebGL.DEPTH_TEST)
      ..activeTexture(WebGL.TEXTURE0)
      ..bindTexture(WebGL.TEXTURE_2D, _tex)

      // Uniforms

      ..uniform1i(_uBg!, 0)
      ..uniform2f(_uViewport!, width.toDouble(), height.toDouble())
      ..uniform2f(_uFocal!, fx, fy)
      ..uniformMatrix3fv(_uInvViewRot!, false, invViewRot3x3)
      ..uniformMatrix3fv(_uBgRot!, false, _bgRot)

      // Fullscreen triangle (gl_VertexID; no VBOs)
      ..drawArrays(WebGL.TRIANGLES, 0, 3);
  }

  /// Set yaw pitch for simple sphere rotation
  void setYawPitchDegrees(double yawDeg, double pitchDeg) {
    final y = yawDeg * math.pi / 180.0; // yaw around +Y (left/right)
    final p = pitchDeg * math.pi / 180.0; // pitch around +X (up/down)
    final cy = math.cos(y), sy = math.sin(y);
    final cp = math.cos(p), sp = math.sin(p);

    // Simple rotation matrix: Ry(yaw) * Rx(pitch) in column-major order
    _bgRot = Float32List.fromList([
      // col0: X basis
      cy, sy * sp, sy * cp,
      // col1: Y basis  
      0.0, cp, -sp,
      // col2: Z basis
      -sy, cy * sp, cy * cp,
    ]);
  }

  /// Cleans up resources.
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
    _uBg = _uViewport = _uFocal = _uInvViewRot = null;
    _ready = false;
  }

  // ---- Internals ------------------------------------------------------------

  Future<void> _ensureProgram() async {
    if (_prog != null && _gl.isProgram(_prog!) == true) return;

    final vertexShaderCode = await flutter_services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_vert.glsl',
    );
    final fragmentShaderCode = await flutter_services.rootBundle.loadString(
      'packages/flutter_gaussian_splatter/shaders/bg_frag.glsl',
    );

    // Compile shaders
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

    // Shaders can be deleted after linking
    _gl
      ..deleteShader(vs)
      ..deleteShader(fs);

    _prog = program;

    // Cache uniforms
    _uBg = _gl.getUniformLocation(_prog!, 'u_bg');
    _uViewport = _gl.getUniformLocation(_prog!, 'u_viewport');
    _uFocal = _gl.getUniformLocation(_prog!, 'u_focal');
    _uInvViewRot = _gl.getUniformLocation(_prog!, 'u_invViewRot');
    _uBgRot = _gl.getUniformLocation(_prog!, 'u_bgRot');
  }

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
