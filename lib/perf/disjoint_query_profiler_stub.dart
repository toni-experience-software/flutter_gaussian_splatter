import 'package:flutter_gaussian_splatter/perf/perf_profiler.dart';

/// Web stub: timer queries not provided here — force fallback.
class DisjointQueryGpuProfiler implements PerfProfiler {
  /// Stub implementation
  static DisjointQueryGpuProfiler? tryCreate(dynamic gl) => null;

  @override
  void beginFrame() {}
  @override
  void markGpuBegin(dynamic gl) {}
  @override
  void markGpuEnd(dynamic gl) {}
  @override
  PerfStats endFrame(dynamic gl) => const PerfStats(cpuMsAvg: 0);
  @override
  void dispose() {}
}
