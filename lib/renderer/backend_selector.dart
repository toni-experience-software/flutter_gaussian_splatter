import 'package:flutter/foundation.dart';
import 'package:flutter_gaussian_splatter/renderer/gpu/flutter_gpu_splat_renderer.dart';
import 'package:flutter_gaussian_splatter/renderer/renderer.dart';
import 'package:flutter_gaussian_splatter/renderer/splat_renderer.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;

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
      return FlutterGpuSplatRenderer();
    case SplatBackend.angle:
      return AngleSplatRenderer(disableAlphaWrite: disableAlphaWrite);
    case SplatBackend.auto:
      if (kIsWeb) {
        return AngleSplatRenderer(disableAlphaWrite: disableAlphaWrite);
      }
      try {
        gpu.gpuContext.defaultColorFormat;
        return FlutterGpuSplatRenderer();
      } catch (error) {
        debugPrint('flutter_gpu unavailable; falling back to ANGLE: $error');
      }
      return AngleSplatRenderer(disableAlphaWrite: disableAlphaWrite);
  }
}
