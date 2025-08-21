// ignore_for_file: avoid_dynamic_calls, unnecessary_lambdas

import 'dart:collection';
import 'package:flutter_gaussian_splatter/core/perf/ewma.dart';
import 'package:flutter_gaussian_splatter/core/perf/perf_profiler.dart';

/// GPU profiler using EXT_disjoint_timer_query for accurate GPU timing.
class DisjointQueryGpuProfiler implements PerfProfiler {

  DisjointQueryGpuProfiler._(this.gl, this.ext) {
    // Detect path
    _isWebGL2Path = gl.createQuery != null; // WebGL2 provides createQuery on gl
    
    if (_isWebGL2Path) {
      _createQuery      = () => gl.createQuery();
      _beginQuery       = (q) => gl.beginQuery(ext.TIME_ELAPSED_EXT, q);
      _endQuery         = () => gl.endQuery(ext.TIME_ELAPSED_EXT);
      _getQueryAvailable= (q) => 
      gl.getQueryParameter(q, gl.QUERY_RESULT_AVAILABLE);
      _getQueryResult   = (q) => gl.getQueryParameter(q, gl.QUERY_RESULT);
    } else {
      _createQuery      = () => ext.createQueryEXT();
      _beginQuery       = (q) => ext.beginQueryEXT(ext.TIME_ELAPSED_EXT, q);
      _endQuery         = () => ext.endQueryEXT(ext.TIME_ELAPSED_EXT);
      _getQueryAvailable= (q) => 
      ext.getQueryObjectEXT(q, ext.QUERY_RESULT_AVAILABLE_EXT);
      _getQueryResult   = (q) => ext.getQueryObjectEXT(q, ext.QUERY_RESULT_EXT);
    }
    
    for (var i = 0; i < _poolSize; i++) {
      _pool.add(_createQuery());
    }
  }
  /// WebGL rendering context.
  final dynamic gl;
  /// Timer query extension object.
  final dynamic ext;
  final Stopwatch _sw = Stopwatch();
  final Ewma _cpu = Ewma();
  final Ewma _gpu = Ewma();
  
  final List<dynamic> _pool = [];
  final Queue<dynamic> _inFlight = Queue();
  final int _poolSize = 6;

  // Method handles chosen at init
  late final bool _isWebGL2Path;
  late final dynamic Function() _createQuery;
  late final dynamic Function(dynamic) _beginQuery;
  late final dynamic Function() _endQuery;
  late final dynamic Function(dynamic) _getQueryAvailable;
  late final dynamic Function(dynamic) _getQueryResult;

  bool _beganThisFrame = false;

  /// Attempts to create a disjoint query profiler if supported.
  static DisjointQueryGpuProfiler? tryCreate(dynamic gl) {
    try {
      final ext = gl.getExtension?.call('EXT_disjoint_timer_query') ??
                  gl.getExtension?.call('EXT_disjoint_timer_query_webgl2');
      return (ext != null) ? DisjointQueryGpuProfiler._(gl, ext) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void beginFrame() {
    _beganThisFrame = false;
    _sw..reset()..start();
  }

  dynamic _alloc() => _pool.isNotEmpty ? _pool.removeLast() : null;

  void _recycle(dynamic q) => _pool.add(q);

  @override
  void markGpuBegin(dynamic _) {
    final q = _alloc();
    if (q == null) return;             // no query this frame
    _beginQuery(q);
    _inFlight.addLast(q);
    _beganThisFrame = true;
  }

  @override
  void markGpuEnd(dynamic _) {
    if (_beganThisFrame) {
      _endQuery();
    }
  }

  double? _harvest() {
    final dj = gl.getParameter?.call(ext.GPU_DISJOINT_EXT);
    final disjoint = (dj == true) || (dj == 1);
    if (disjoint) {
      while (_inFlight.isNotEmpty) {
        _recycle(_inFlight.removeFirst());
      }
      return null;
    }

    double? ms;
    while (_inFlight.isNotEmpty) {
      final q = _inFlight.first;
      final ready = _getQueryAvailable(q) == true || _getQueryAvailable(q) == 1;
      if (!ready) break;
      _inFlight.removeFirst();
      final ns = _getQueryResult(q) as num;
      ms = ns / 1e6;
      _recycle(q);
    }
    return ms;
  }

  @override
  PerfStats endFrame(dynamic _) {
    _sw.stop();
    final cpuMs = _sw.elapsedMicroseconds / 1000.0;
    _cpu.add(cpuMs);
    
    final harvestedMs = _harvest();
    if (harvestedMs != null) _gpu.add(harvestedMs);
    
    return PerfStats(
      cpuMsAvg: _cpu.value,
      gpuMsAvg: _gpu.value == 0 ? null : _gpu.value,
    );
  }

  @override
  void dispose() {
    try {
      while (_inFlight.isNotEmpty) {
        _recycle(_inFlight.removeFirst());
      }
      for (final q in _pool) {
        try {
          if (_isWebGL2Path) { 
            gl.deleteQuery(q); 
          } else { 
            ext.deleteQueryEXT(q); 
          }
        } catch (_) {}
      }
    } catch (_) {}
    _pool.clear();
  }
}
