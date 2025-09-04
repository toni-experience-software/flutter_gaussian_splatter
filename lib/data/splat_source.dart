import 'dart:typed_data';
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/constants.dart';

/// Manages the GPU texture representation of Gaussian splat data.
///
/// This class handles the conversion of raw splat data into a WebGL texture
/// optimized for rendering. Each splat is packed into 5 consecutive RGBA
/// pixels in the texture, containing position, rotation, scale, color, and
/// spherical harmonics coefficients.
class SplatSource {
  /// The WebGL texture containing the packed splat data.
  WebGLTexture? texture;

  /// Fixed width of the texture in pixels.
  int texWidth = GsConst.texWidth;

  /// Current height of the texture in pixels, calculated based on splat count.
  int texHeight = 0;

  /// Total number of splats currently stored in the texture.
  int splatCount = 0;

  /// Reused staging buffer to avoid repeated allocations.
  Float32Array? _scratch;

  /// Uploads splat data from a binary buffer to a WebGL texture.
  ///
  /// The [buffer] must contain data for one or more splats, where each splat
  /// uses exactly [GsConst.bytesPerSplat] bytes. The data is converted from
  /// the compact binary format into a 2D RGBA32F texture suitable for GPU
  /// rendering.
  ///
  /// Immediately updates [splatCount], [texHeight], and [texture] upon
  /// successful upload.
  void upload(RenderingContext gl, Uint8List buffer) {
    assert(
      buffer.length % GsConst.bytesPerSplat == 0,
      'Splat buffer must be multiple of ${GsConst.bytesPerSplat} bytes',
    );

    final count = buffer.length ~/ GsConst.bytesPerSplat;
    const pixelsPerSplat = GsConst.pixelsPerSplat;
    final height = ((pixelsPerSplat * count) / texWidth).ceil();

    // Reuse staging
    final neededFloats = texWidth * height * 4;
    _scratch ??= Float32Array(neededFloats);
    if (_scratch!.length < neededFloats) _scratch = Float32Array(neededFloats);
    final texData = _scratch!;

    final f32 = Float32List.view(buffer.buffer);
    final u8 = Uint8List.view(buffer.buffer);
    const floatsPerSplat = GsConst.bytesPerSplat ~/ 4;

    for (var idx = 0; idx < count; idx++) {
      final x = (idx & 0x1ff) * pixelsPerSplat; // (idx & 511) * 5
      final y = idx >> 9;

      final p0 = (y * texWidth + x + 0) * 4;
      final p1 = (y * texWidth + x + 1) * 4;
      final p2 = (y * texWidth + x + 2) * 4;
      final p3 = (y * texWidth + x + 3) * 4;
      final p4 = (y * texWidth + x + 4) * 4;

      final fBase = floatsPerSplat * idx;
      final bBase = GsConst.bytesPerSplat * idx;

      // P0: pos.xyz + packed quat (u32-as-f32)
      texData[p0 + 0] = f32[fBase + 0];
      texData[p0 + 1] = f32[fBase + 1];
      texData[p0 + 2] = f32[fBase + 2];
      final qx = u8[bBase + 28 + 0];
      final qy = u8[bBase + 28 + 1];
      final qz = u8[bBase + 28 + 2];
      final qw = u8[bBase + 28 + 3];
      final packedQuat = qx | (qy << 8) | (qz << 16) | (qw << 24);
      texData[p0 + 3] = _u32AsF32(packedQuat);

      // P1: scale.xyz + packed rgba
      texData[p1 + 0] = f32[fBase + 3];
      texData[p1 + 1] = f32[fBase + 4];
      texData[p1 + 2] = f32[fBase + 5];
      final r = u8[bBase + 24 + 0];
      final g = u8[bBase + 24 + 1];
      final b = u8[bBase + 24 + 2];
      final a = u8[bBase + 24 + 3];
      final packedColor = r | (g << 8) | (b << 16) | (a << 24);
      texData[p1 + 3] = _u32AsF32(packedColor);

      // P2..P4: 12 floats of SH (we keep first 12 floats)
      final shStart = (bBase + 32) >> 2;
      texData[p2 + 0] = f32[shStart + 0];
      texData[p2 + 1] = f32[shStart + 1];
      texData[p2 + 2] = f32[shStart + 2];
      texData[p2 + 3] = f32[shStart + 3];
      texData[p3 + 0] = f32[shStart + 4];
      texData[p3 + 1] = f32[shStart + 5];
      texData[p3 + 2] = f32[shStart + 6];
      texData[p3 + 3] = f32[shStart + 7];
      texData[p4 + 0] = f32[shStart + 8];
      texData[p4 + 1] = f32[shStart + 9];
      texData[p4 + 2] = f32[shStart + 10];
      texData[p4 + 3] = f32[shStart + 11];
    }

    // Create/replace texture
    if (texture != null) {
      try {
        gl.deleteTexture(texture!);
      } catch (_) {}
    }
    texture = gl.createTexture();
    gl
      ..bindTexture(WebGL.TEXTURE_2D, texture)
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
        WebGL.NEAREST,
      )
      ..texParameteri(
        WebGL.TEXTURE_2D,
        WebGL.TEXTURE_MAG_FILTER,
        WebGL.NEAREST,
      )
      ..texImage2D(
        WebGL.TEXTURE_2D,
        0,
        WebGL.RGBA32F,
        texWidth,
        height,
        0,
        WebGL.RGBA,
        WebGL.FLOAT,
        texData,
      );

    splatCount = count;
    texHeight = height;
  }

  /// Releases all GPU resources and resets the state.
  ///
  /// This method should be called when the splat data is no longer needed
  /// to prevent memory leaks. After calling dispose, the object can be
  /// reused by calling [upload] with new data.
  void dispose(RenderingContext gl) {
    _scratch = null;
    if (texture != null) {
      try {
        gl.deleteTexture(texture!);
      } catch (_) {}
      texture = null;
    }
    splatCount = 0;
    texHeight = 0;
  }

  @pragma('vm:prefer-inline')
  static double _u32AsF32(int u) =>
      Float32List.view((Uint32List(1)..[0] = u).buffer)[0];
}
