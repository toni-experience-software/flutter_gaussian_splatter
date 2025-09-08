import 'dart:io';
import 'package:flutter_angle/flutter_angle.dart';

/// Checks capabilities of the render pipeline
class Caps {

  /// Creates a capabilities detector for the given GL context.
  Caps(RenderingContext gl)
      : hasIntegerTex = !Platform.isAndroid && _probeR32UI(gl);
  
  /// Whether R32UI integer textures are supported.
  final bool hasIntegerTex;

  static bool _probeR32UI(RenderingContext gl) {
    try {
      final tex = gl.createTexture();
      gl
        ..bindTexture(WebGL.TEXTURE_2D, tex)
        ..texParameteri(
            WebGL.TEXTURE_2D, WebGL.TEXTURE_MIN_FILTER, WebGL.NEAREST,)
        ..texParameteri(
            WebGL.TEXTURE_2D, WebGL.TEXTURE_MAG_FILTER, WebGL.NEAREST,)
        ..texParameteri(
            WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_S, WebGL.CLAMP_TO_EDGE,)
        ..texParameteri(
            WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_T, WebGL.CLAMP_TO_EDGE,)
        ..texImage2D(WebGL.TEXTURE_2D, 0, WebGL.R32UI, 1, 1, 0,
            WebGL.RED_INTEGER, WebGL.UNSIGNED_INT, null,);
      final ok = gl.getError() == WebGL.NO_ERROR;
      gl.deleteTexture(tex);
      return ok;
    } catch (_) {
      return false;
    }
  }
}
