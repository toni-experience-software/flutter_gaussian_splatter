// lib/data/order_texture.dart
//
// Integer order map: each texel holds a splat index.
// Uses R32UI if available; you can add RGBA8 fallback later if needed.

import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/constants.dart';
import 'package:flutter_gaussian_splatter/gl/gl_capabilities.dart';

/// Manages a GPU texture containing ordered splat indices for rendering.
///
/// This texture stores integer indices that determine the rendering order
/// of splats. Each texel contains a single 32-bit unsigned integer representing
/// a splat index. The texture uses R32UI format for optimal performance and
/// memory usage, with RGBA32F fallback for compatibility.
class OrderTexture {
  /// The WebGL texture containing the ordered splat indices.
  WebGLTexture? texture;

  /// Fixed width of the texture in texels (typically 512).
  int width = GsConst.splatsPerRow;

  /// Current number of rows in use by the texture.
  int height = 0;

  /// Allocated height with headroom to avoid frequent reallocations.
  int _allocHeight = 0;

  /// Texture format capability - determined on first use
  bool _useR32UI = false;

  /// Uploads a complete array of splat indices to the texture.
  ///
  /// The [indices] array contains the rendering order of splats, stored in
  /// row-major order within the 2D texture. If the required texture size
  /// exceeds the current allocation, the texture will be resized with
  /// additional headroom to minimize future reallocations.
  ///
  /// Returns immediately if [indices] is empty.
  void uploadFull(RenderingContext gl, List<int> indices, {Caps? caps}) {
    if (indices.isEmpty) return;
    if (texture == null) {
      // decide once when we first allocate
      _useR32UI = caps?.hasIntegerTex ?? false;
    }
    final neededRows = (indices.length + width - 1) ~/ width;
    if (texture == null || _allocHeight < neededRows) {
      _allocHeight = (neededRows * 5) ~/ 4 + 1;
      _createOrResize(gl, _allocHeight);
    } else {
      gl.bindTexture(WebGL.TEXTURE_2D, texture);
    }

    final totalTexels = neededRows * width;
    if (_useR32UI) {
      final u32 = Uint32Array(totalTexels); // zero-initialized
      for (var i = 0; i < indices.length; ++i) {
        u32[i] = indices[i];
      }
      gl.texSubImage2D(WebGL.TEXTURE_2D, 0, 0, 0, width, neededRows,
          WebGL.RED_INTEGER, WebGL.UNSIGNED_INT, u32,);
    } else {
      // pack into R channel of RGBA32F
      final f32 = Float32Array(totalTexels * 4); // zero-initialized
      for (var i = 0; i < indices.length; ++i) {
        f32[i * 4] = indices[i].toDouble();
      }
      gl.texSubImage2D(WebGL.TEXTURE_2D, 0, 0, 0, width, neededRows, WebGL.RGBA,
          WebGL.FLOAT, f32,);
    }
    height = neededRows;
  }

  /// Releases all GPU resources and resets the texture state.
  ///
  /// This method should be called when the order texture is no longer needed
  /// to prevent memory leaks. After disposal, the object can be reused by
  /// calling [uploadFull] with new data.
  void dispose(RenderingContext gl) {
    if (texture != null) {
      try {
        gl.deleteTexture(texture!);
      } catch (_) {}
      texture = null;
    }
    height = _allocHeight = 0;
  }

  void _createOrResize(RenderingContext gl, int rows) {
    if (texture != null) {
      try {
        gl.deleteTexture(texture!);
      } catch (_) {}
    }
    texture = gl.createTexture();
    gl
      ..bindTexture(WebGL.TEXTURE_2D, texture)
      ..texParameteri(
          WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_S, WebGL.CLAMP_TO_EDGE,)
      ..texParameteri(
          WebGL.TEXTURE_2D, WebGL.TEXTURE_WRAP_T, WebGL.CLAMP_TO_EDGE,)
      ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MIN_FILTER, WebGL.NEAREST)
      ..texParameteri(WebGL.TEXTURE_2D, WebGL.TEXTURE_MAG_FILTER, WebGL.NEAREST)
      ..texImage2D(
          WebGL.TEXTURE_2D,
          0,
          _useR32UI ? WebGL.R32UI : WebGL.RGBA32F,
          width,
          rows,
          0,
          _useR32UI ? WebGL.RED_INTEGER : WebGL.RGBA,
          _useR32UI ? WebGL.UNSIGNED_INT : WebGL.FLOAT,
          null,);
  }
}
