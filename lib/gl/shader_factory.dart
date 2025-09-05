import 'package:flutter_angle/desktop/wrapper.dart';
import 'package:flutter_angle/shared/classes.dart';
import 'package:flutter_angle/shared/webgl.dart';

/// Builds GLSL programs with optional preprocessor defines and attribute 
abstract class ShaderFactory {
  /// Compiles and links a program. Throws on compile/link errors.
  static Program compile(
    RenderingContext gl, {
    required String vertexSource,
    required String fragmentSource,
    Map<String, String> defines = const {},
    Map<String, int> attribBindings = const {},
  }) {
    final vsText = _injectDefines(vertexSource, defines);
    final fsText = _injectDefines(fragmentSource, defines);

    final vs = gl.createShader(WebGL.VERTEX_SHADER);
    gl
      ..shaderSource(vs, vsText)
      ..compileShader(vs); // throws with info log on failure

    final fs = gl.createShader(WebGL.FRAGMENT_SHADER);
    gl
      ..shaderSource(fs, fsText)
      ..compileShader(fs);

    final program = gl.createProgram();

    // Attach shaders, bind attributes (stable locations), then link.
    gl
      ..attachShader(program, vs)
      ..attachShader(program, fs);

    if (attribBindings.isNotEmpty) {
      attribBindings.forEach((name, index) {
        gl.bindAttribLocation(program, index, name);
      });
    }

    gl
      ..linkProgram(program) 

      // Shaders no longer needed after a successful link.
      ..deleteShader(vs)
      ..deleteShader(fs);

    return program;
  }

  /// Inserts `#define KEY VALUE` after an initial `#version` line if present.
  static String _injectDefines(String src, Map<String, String> defines) {
    if (defines.isEmpty) return src;

    final buf = StringBuffer();
    defines.forEach((k, v) => buf.writeln('#define $k $v'));
    final defs = buf.toString();

    final lines = src.split('\n');
    if (lines.isNotEmpty && lines.first.trimLeft().startsWith('#version')) {
      final head = lines.first;
      final rest = lines.sublist(1).join('\n');
      return '$head\n$defs$rest';
    }
    return '$defs$src';
  }
}
