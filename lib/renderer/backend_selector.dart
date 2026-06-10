import 'package:flutter/foundation.dart';
import 'package:flutter_gaussian_splatter/renderer/renderer.dart';
import 'package:flutter_gaussian_splatter/renderer/splat_renderer.dart';

/// Available renderer backends.
enum SplatBackend {
  /// Select the best available backend for the current platform.
  auto,

  /// Use the experimental Impeller/flutter_gpu backend.
  flutterGpu,

  /// Use the existing flutter_angle backend.
  angle,
}

/// Creates a renderer for [choice].
SplatRenderer createRenderer(
  SplatBackend choice, {
  bool disableAlphaWrite = false,
}) {
  switch (choice) {
    case SplatBackend.flutterGpu:
      throw UnimplementedError(
        'The flutter_gpu backend is not implemented yet.',
      );
    case SplatBackend.angle:
      return AngleSplatRenderer(disableAlphaWrite: disableAlphaWrite);
    case SplatBackend.auto:
      // TODO(phase2): Probe flutter_gpu here and fall back to ANGLE on failure.
      if (kIsWeb) {
        return AngleSplatRenderer(disableAlphaWrite: disableAlphaWrite);
      }
      return AngleSplatRenderer(disableAlphaWrite: disableAlphaWrite);
  }
}
