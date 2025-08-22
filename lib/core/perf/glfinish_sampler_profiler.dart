// ignore_for_file: avoid_dynamic_calls

import 'package:flutter_gaussian_splatter/core/perf/ewma.dart';
import 'package:flutter_gaussian_splatter/core/perf/perf_profiler.dart';

/// GPU profiler using glFinish() sampling for approximate GPU timing.
class GlFinishSamplerProfiler implements PerfProfiler {

  GlFinishSamplerProfiler._(this.gl, this._stride);
  /// WebGL rendering context.
  final dynamic gl;
  final Stopwatch _sw = Stopwatch();
  final Ewma _cpu = Ewma();
  final Ewma _gpu = Ewma();
  final int _stride;
  int _frame = 0;
  bool _pendingFinish = false;

  /// Attempts to create a glFinish sampler profiler if supported.
  static GlFinishSamplerProfiler? tryCreate(dynamic gl, {int stride = 30}) {
    try {
      if (gl.gl?.glFinish == null) return null;
      return GlFinishSamplerProfiler._(gl, stride);
    } catch (_) {
      return null;
    }
  }

  @override
  void beginFrame() => _sw..reset()..start();

  @override
  void markGpuBegin(dynamic _) {}

  @override
  void markGpuEnd(dynamic _) {
    _frame++;
    _pendingFinish = (_frame % _stride == 0);
  }

  @override
  PerfStats endFrame(dynamic _) {
    _sw.stop();
    final cpuMs = _sw.elapsedMicroseconds / 1000.0;
    final cpuAvg = _cpu.add(cpuMs);
    
    if (_pendingFinish) {
      final s = Stopwatch()..start();
      gl.gl.glFinish();
      s.stop();
      _gpu.add(s.elapsedMicroseconds / 1000.0);
      _pendingFinish = false;
    }
    
    return PerfStats(
      cpuMsAvg: cpuAvg,
      gpuMsAvg: _gpu.value == 0 ? null : _gpu.value,
    );
  }

  @override
  void dispose() {}
}
