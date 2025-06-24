

/// Grouped as an immutable namespace.
abstract final class GsConst {
  // ───────────────────────────────────── Vertex / Buffer ──────────────────────
  /// Bytes per packed splat row (must be power-of-two for alignment on GPU).
  static const int outputRowLength = 128;

  /// Default linear scale when scale_* properties are missing.
  static const double defaultScale = 0.01;

  /// Number of bytes that make up *one* packed splat.
  static const int bytesPerSplat = 128;

  // ───────────────────────────────────── Texture Atlas ────────────────────────
  /// Fixed atlas width (pixels); height is computed on upload.
  static const int texWidth = 2048;

  // ───────────────────────────────────── Quaternion ───────────────────────────
  /// Centre byte when mapping quaternion components ↔ [-1,1] float.
  static const int quatByteMid = 128;      // (byte-128) / 128
  static const int quatScale   = 128;      // multiply by this before +mid

  // ───────────────────────────────────── Covariance ───────────────────────────
  /// Specifies Σ' = 4 · (M Mᵀ) per paper / reference implementation.
  static const double covarianceScale = 4.0;

  // ───────────────────────────────────── Colour / SH ──────────────────────────
  /// Real Y₀⁰ normalisation factor (0-th SH basis).
  static const double shC0 = 0.28209479177387814;

  /// Range used when quantising the 45 residual coefficients.
  static const double shMin  = -4.0;
  static const double shMax  =  4.0;
  static const double shSpan = shMax - shMin; // == 8.0

  /// Byte range [0,255] used for all 8-bit packing.
  static const int byteMax = 255;

  /// Bias used when folding DC term into 8-bit RGB.
  static const double baseColourBias = 0.5;
}
