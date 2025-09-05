// ignore_for_file: public_member_api_docs

/// Global renderer/packer constants.
///
/// Two layouts exist:
/// 1) CPU/file-packed splat = 128 B (legacy)
///    We actively use the first 80 B; the remaining 48 B are reserved.
/// 2) GPU texture atlas = 5 texels per splat (RGBA32F → 5 * 16 B = 80 B).
///
/// SH0 (DC) is folded into base RGB. The 45 residual SH coeffs (l=1..3)
/// are stored as 12 packed uint32 words (48 B) and unpacked in the shader.
abstract final class GsConst {
  // ───────────────────────────── CPU / File-packed splat ─────────────────────────────
  /// Total bytes per splat in the binary file / CPU buffer (aligned).
  static const int bytesPerSplat = 128;

  /// Bytes per row written by the file processor (must equal [bytesPerSplat]).
  static const int outputRowLength = bytesPerSplat;

  /// Portion of the 128 B actually consumed by the uploader 
  /// (mirrors GPU footprint).
  static const int usedBytesPerSplat = 80; // 12 + 12 + 4 + 4 + 48 = 80

  // Offsets inside the 128-byte CPU splat:
  // P0: position.xyz (float32×3)              →  0..11
  // P1: scale.xyz    (float32×3, linear)      → 12..23
  // P1: base color RGBA8 (DC term in RGB)     → 24..27
  // P0: rotation quaternion RGBA8 (packed)    → 28..31
  // P2–P4: SH residuals as 12×uint32 (48 B)   → 32..79
  // 80..127: reserved
  static const int posOffset   = 0;
  static const int scaleOffset = 12;
  static const int colorOffset = 24;
  static const int quatOffset  = 28;
  static const int shOffset    = 32;
  static const int shPackedWords = 12; // 12×uint32 = 48 B @ [32..79]

  // ───────────────────────────── GPU texture atlas ───────────────────────────
  /// Texels per splat in the atlas:
  ///   P0: pos.xyz + quat(w) | P1: scale.xyz + color(w) | P2–P4: SH words
  static const int pixelsPerSplat = 5;

  /// Bytes per texel for RGBA32F.
  static const int bytesPerTexel = 16;

  /// Bytes per splat once uploaded to the GPU.
  static const int bytesPerSplatInTexture = pixelsPerSplat * bytesPerTexel;

  /// Atlas width in pixels. With bit-addressing in the shader we require:
  ///   texWidth == pixelsPerSplat * 512 (= 2560), so
  ///   base_uv = ((idx & 0x1ff) * pixelsPerSplat, idx >> 9)
  static const int texWidth = 2560;
  static const int splatsPerRow = texWidth ~/ pixelsPerSplat;   // 512
  static const int splatIdxColMask = splatsPerRow - 1;          // 0x1ff

  // ───────────────────────────── Instancing / batching ────────────────────────────
  /// Number of Gaussian splats to draw per instanced batch.
  ///
  /// PlayCanvas batches 128 splats per draw call to improve vertex shader
  /// occupancy and reduce overhead.  Grouping multiple splats into a single
  /// instanced mesh means the vertex shader runs only once per batch for
  /// operations common across splats (e.g. base index lookup), and the
  /// hardware can process more vertices per invocation.
  ///
  /// A value of 32 is a conservative default that balances GPU vertex cache
  /// utilization against attribute bandwidth.  You can increase this (e.g.
  /// 64 or 128) to further reduce the number of instanced draws at the
  /// expense of a larger static vertex buffer.
  static const int splatsPerInstance = 128;

  // ───────────────────────────── Quaternion pack/unpack ─────────────────────────────
  /// CPU packing: q_byte = clamp(round(q * quatScale + quatByteMid), 0, 255)
  /// Shader decode: q = (byte - quatByteMid) / quatScale, then normalized.
  static const int quatByteMid = 128;
  static const int quatScale   = 128;
  static const int byteMax     = 255;

  // ───────────────────────────── Covariance (renderer) ───────────────────────
  /// Σ' = covarianceScale * (M * Mᵀ) as in the paper/reference implementation.
  static const double covarianceScale = 4;

  // ───────────────────────────── Colour / Spherical Harmonics ─────────────────────────
  /// Real Y₀⁰ normalization (DC basis). Base RGB stores 0.5 + shC0 * f_dc.
  static const double shC0   = 0.28209479177387814;

  /// Quantization range for residual SH (l=1..3).
  /// Pack:   byte = round((clamp(c, shMin, shMax) - shMin) * 255 / (shMax - shMin))
  /// Unpack: value = byte * 8/255 - 4
  static const double shMin  = -4;
  static const double shMax  =  4;
  static const double shSpan = shMax - shMin; // 8.0

  /// Bias used when folding DC into 8-bit RGB: baseRGB = clamp01(baseColourBias
  ///  + shC0 * f_dc).
  static const double baseColourBias = 0.5;

  // ───────────────────────────── Defaults ─────────────────────────────
  /// Fallback linear scale if PLY lacks scale_* properties.
  static const double defaultScale = 0.01;

  /// Maximum pixel diameter for a single splat in screen space.
  ///
  /// When zooming in close to a Gaussian, its projected ellipse can
  /// cover a very large portion of the viewport.  Rendering such
  /// extremely large splats is expensive because it forces the fragment
  /// shader to run over many pixels and all overlapping splats still
  /// contribute to the scene due to alpha blending.  PlayCanvas
  /// addresses this with a work‑buffer pipeline; as a lightweight
  /// approximation we provide a configurable threshold in pixels
  /// beyond which splats are culled completely.  This reduces
  /// overdraw at close distances and improves performance without
  /// affecting distant views.  Users can adjust this value based on
  /// their target device performance.
  static const double maxSplatPixelSize = 256;

}
