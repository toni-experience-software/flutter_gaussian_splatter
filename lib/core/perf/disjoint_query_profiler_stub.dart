import 'package:flutter_gaussian_splatter/core/perf/perf_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/cpu_only_profiler.dart';

/// Web stub: timer queries not provided here — force fallback.
class DisjointQueryGpuProfiler implements PerfProfiler {
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
