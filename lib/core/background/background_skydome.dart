import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter/foundation.dart';

/// Minimal, optional equirectangular skydome background.
/// Draw *before* your splat pass; no blending needed here.
class SkydomeBackground {
  SkydomeBackground(this._gl);

  final RenderingContext _gl;

  Program? _prog;
  UniformLocation? _uBg, _uViewport, _uFocal, _uInvViewRot;
  WebGLTexture? _tex;
  int _imgW = 0, _imgH = 0;
  bool _ready = false;

  bool get isReady => _ready;

  // ---- Public API -----------------------------------------------------------

  /// Loads an image from the asset bundle and uploads it as a texture.
  Future<void> setImageFromAsset(String assetPath) async {
  _ensureProgram();
  _tex ??= _gl.createTexture();
  _gl
    ..bindTexture(WebGL.TEXTURE_2D, _tex)
    ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_S, WebGL.CLAMP_TO_EDGE)
    ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_T, WebGL.CLAMP_TO_EDGE)
    ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MIN_FILTER, WebGL.LINEAR_MIPMAP_LINEAR)
    ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MAG_FILTER, WebGL.LINEAR)
    ..pixelStorei(WebGL.UNPACK_ALIGNMENT, 1);

  // IMPORTANT: override the bad defaults (RGBA32UI/UNSIGNED_INT)
  await _gl.texImage2DfromAsset(
    WebGL.TEXTURE_2D,
    assetPath,
    internalformat: WebGL.RGBA,
    format: WebGL.RGBA,
    type: WebGL.UNSIGNED_BYTE,
  );

  // Query width/height if you need them later (optional)
  // If not easily available, you can ignore _imgW/_imgH for assets.
  _gl.generateMipmap(WebGL.TEXTURE_2D);
  _ready = true;
}

  /// Draws the skydome to the current framebuffer. Call before enabling blending.
  void draw(int width, int height, double fx, double fy, Float32List invViewRot3x3) {
    if (!_ready || _prog == null || _tex == null) return;

    // State for opaque background
    _gl
      ..useProgram(_prog)
      ..disable(WebGL.BLEND)
      ..disable(WebGL.DEPTH_TEST)
      ..activeTexture(WebGL.TEXTURE0)
      ..bindTexture(WebGL.TEXTURE_2D, _tex);

    // Uniforms
    _gl
      ..uniform1i(_uBg!, 0)
      ..uniform2f(_uViewport!, width.toDouble(), height.toDouble())
      ..uniform2f(_uFocal!, fx, fy)
      ..uniformMatrix3fv(_uInvViewRot!, false, invViewRot3x3);

    // Fullscreen triangle (gl_VertexID; no VBOs)
    _gl.drawArrays(WebGL.TRIANGLES, 0, 3);
  }

  void dispose() {
    if (_tex != null) {
      try { _gl.deleteTexture(_tex!); } catch (_) {}
      _tex = null;
    }
    if (_prog != null) {
      try { _gl.deleteProgram(_prog!); } catch (_) {}
      _prog = null;
    }
    _uBg = _uViewport = _uFocal = _uInvViewRot = null;
    _ready = false;
  }

  // ---- Internals ------------------------------------------------------------

  void _ensureProgram() {
    if (_prog != null && _gl.isProgram(_prog!) == true) return;

    // Compile shaders
    final vs = _compile(WebGL.VERTEX_SHADER, _bgVertSrc);
    final fs = _compile(WebGL.FRAGMENT_SHADER, _bgFragSrc);

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
    _uBg        = _gl.getUniformLocation(_prog!, 'u_bg');
    _uViewport  = _gl.getUniformLocation(_prog!, 'u_viewport');
    _uFocal     = _gl.getUniformLocation(_prog!, 'u_focal');
    _uInvViewRot= _gl.getUniformLocation(_prog!, 'u_invViewRot');
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

// ---- Embedded shader sources -------------------------------------------------

const String _bgVertSrc = r'''
#version 300 es
void main() {
  const vec2 verts[3] = vec2[3](
    vec2(-1.0, -1.0),
    vec2( 3.0, -1.0),
    vec2(-1.0,  3.0)
  );
  gl_Position = vec4(verts[gl_VertexID], 0.0, 1.0);
}
''';

const String _bgFragSrc = r'''
#version 300 es
precision mediump float;

uniform sampler2D u_bg;
uniform vec2      u_viewport;
uniform vec2      u_focal;
uniform mat3      u_invViewRot;

out vec4 frag;

void main() {
  vec2 ndc = (gl_FragCoord.xy / u_viewport) * 2.0 - 1.0;

  float fovX = (2.0 * u_focal.x) / u_viewport.x;
  float fovY = (2.0 * u_focal.y) / u_viewport.y;

  vec3 dir_cam = normalize(vec3(ndc.x / fovX, ndc.y / fovY, -1.0));
  vec3 dir = normalize(u_invViewRot * dir_cam);

  float u = atan(-dir.z, dir.x) / (2.0 * 3.14159265359) + 0.5;
  float v = 0.5 - asin(clamp(dir.y, -1.0, 1.0)) / 3.14159265359;

  frag = vec4(texture(u_bg, vec2(u, v)).rgb, 1.0);
}
''';
