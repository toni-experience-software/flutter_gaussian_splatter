import 'package:flutter_angle/desktop/wrapper.dart';
import 'package:flutter_gaussian_splatter/core/camera.dart';

/// Minimal contract all render passes implement.
///
/// Lifecycle rules:
/// - `init` is called once after construction.
/// - `resize` is called when the backbuffer size changes.
/// - `execute` is called every frame (in pipeline order).
/// - `dispose` is called once at shutdown or context loss.
abstract class RenderPass {
  /// Stable, human-readable name for logs/profiling.
  String get name;

  /// Create GL objects, compile shaders, cache uniform locations.
  Future<void> init(RenderingContext gl);

  /// Resize/retarget any size-dependent resources (if any).
  void resize(RenderingContext gl, int width, int height) {}

  /// Record commands and draw.
  void execute(RenderingContext gl, GaussianCamera camera);

  /// Free GL resources. Safe to call multiple times.
  void dispose(RenderingContext gl);
}