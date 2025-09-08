import 'dart:core';
import 'package:flutter_gaussian_splatter/perf/ewma.dart';
import 'package:flutter_gaussian_splatter/perf/perf_profiler.dart';

/// CPU-only performance profiler fallback implementation.
class CpuOnlyProfiler implements PerfProfiler {
  final Stopwatch _sw = Stopwatch();
  final Ewma _cpu = Ewma();

  @override
  void beginFrame() => _sw..reset()..start();

  @override
  void markGpuBegin(dynamic _) {}

  @override
  void markGpuEnd(dynamic _) {}

  @override
  PerfStats endFrame(dynamic _) {
    _sw.stop();
    final cpuMs = _sw.elapsedMicroseconds / 1000.0;
    return PerfStats(cpuMsAvg: _cpu.add(cpuMs));
  }

  @override
  void dispose() {}
}
