import 'package:flutter/foundation.dart';

/// Immutable per‑frame rendering performance statistics.
///
/// Performance is measured using exponentially weighted moving averages (EWMA)
/// with automatic GPU profiling when supported by the WebGL context.
@immutable
class RenderStats {
  /// Creates a new instance of [RenderStats].
  const RenderStats({
    required this.fps,
    required this.vertexCount,
    required this.lastFrameTime,
    this.cpuFrameTimeMs,
    this.gpuFrameTimeMs,
    this.profilerType,
  });

  /// CPU-based frames per second (smoothed with EWMA).
  ///
  /// This measures the total frame time from start to finish on the main
  /// thread.
  final double fps;

  /// Number of Gaussian splat vertices rendered in the last frame.
  final int vertexCount;

  /// Timestamp when the last frame was completed.
  final DateTime lastFrameTime;

  /// Average CPU frame time in milliseconds (smoothed with EWMA).
  ///
  /// Measures the time spent on the main thread per frame.
  final double? cpuFrameTimeMs;

  /// Average GPU frame time in milliseconds (smoothed with EWMA), if available.
  ///
  /// Only available when GPU timing extensions are supported. May be null
  /// if GPU profiling is unavailable or if measurements are not ready.
  final double? gpuFrameTimeMs;

  /// Type of performance profiler being used.
  ///
  /// - 'GPU': Using EXT_disjoint_timer_query for accurate GPU timing
  /// - 'Sampled': Using glFinish() sampling for approximate GPU timing
  /// - 'CPU': CPU-only timing fallback
  final String? profilerType;

  /// GPU-based frames per second, if GPU timing is available.
  double? get gpuFps => gpuFrameTimeMs != null && gpuFrameTimeMs! > 0
      ? 1000.0 / gpuFrameTimeMs!
      : null;

  /// True if GPU timing measurements are available.
  bool get hasGpuTiming => gpuFrameTimeMs != null;

  @override
  String toString() {
    final gpuInfo =
        hasGpuTiming ? ', gpu: ${gpuFrameTimeMs!.toStringAsFixed(1)}ms' : '';
    final profilerInfo = profilerType != null ? ' [$profilerType]' : '';
    return 'RenderStats(fps: ${fps.toStringAsFixed(1)},'
    ' vtx: $vertexCount$gpuInfo$profilerInfo)';
  }
}
