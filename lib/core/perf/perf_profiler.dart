// ignore_for_file: avoid_dynamic_calls

import 'package:flutter/foundation.dart';
import 'package:flutter_gaussian_splatter/core/perf/cpu_only_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/disjoint_query_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/glfinish_sampler_profiler.dart';

/// Performance statistics from a single frame.
@immutable
class PerfStats {
  /// Creates performance statistics.
  const PerfStats({required this.cpuMsAvg, this.gpuMsAvg});

  /// Average CPU frame time in milliseconds.
  final double cpuMsAvg;

  /// Average GPU frame time in milliseconds, if available.
  final double? gpuMsAvg;

  /// Frames per second based on CPU timing.
  double get fps => 1000.0 / cpuMsAvg;

  /// Frames per second based on CPU timing.
  double get fpsCpu => 1000.0 / cpuMsAvg;

  /// Frames per second based on GPU timing, if available.
  double? get fpsGpu =>
      (gpuMsAvg != null && gpuMsAvg! > 0) ? 1000.0 / gpuMsAvg! : null;

  @override
  String toString() => 'PerfStats(cpu: ${cpuMsAvg.toStringAsFixed(2)}ms, '
      'gpu: ${gpuMsAvg?.toStringAsFixed(2) ?? 'N/A'}ms, '
      'fps: ${fps.toStringAsFixed(1)})';
}

/// Interface for performance profiling implementations.
abstract class PerfProfiler {
  /// Creates the best available profiler for the given WebGL context.
  factory PerfProfiler.auto(dynamic gl) =>
      DisjointQueryGpuProfiler.tryCreate(gl.gl) ?? // pass the gl binding
      GlFinishSamplerProfiler.tryCreate(gl) ??
      CpuOnlyProfiler();

  /// Starts timing a new frame.
  void beginFrame();

  /// Marks the beginning of GPU work.
  void markGpuBegin(dynamic gl);

  /// Marks the end of GPU work.
  void markGpuEnd(dynamic gl);

  /// Completes frame timing and returns statistics.
  PerfStats endFrame(dynamic gl);

  /// Releases resources.
  void dispose();
}
