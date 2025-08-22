// ignore_for_file: avoid_dynamic_calls
import 'dart:collection';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as ffix;
// Pull in the GLES constants (re-exported by flutter_angle)
import 'package:flutter_angle/flutter_angle.dart' as angle;
import 'package:flutter_gaussian_splatter/core/perf/ewma.dart';
import 'package:flutter_gaussian_splatter/core/perf/perf_profiler.dart';

/// GPU profiler using EXT_disjoint_timer_query on ANGLE / OpenGL ES.
/// Pass the **native GL binding object directly**
/// (the one with glGenQueries, glBeginQuery, …).
class DisjointQueryGpuProfiler implements PerfProfiler {
  DisjointQueryGpuProfiler._(this.gl);

  /// The native GLES FFI binding (e.g., the object that has glGenQueries,
  /// glGetQueryiv, etc.)
  final dynamic gl;

  final Stopwatch _sw = Stopwatch();
  final Ewma _cpu = Ewma();
  final Ewma _gpu = Ewma();

  static const int _poolSize = 6;
  final List<int> _pool = <int>[];
  final Queue<int> _inFlight = Queue<int>();
  bool _beganThisFrame = false;

  /// Create if supported; otherwise return null so the caller can fall back.
  static DisjointQueryGpuProfiler? tryCreate(dynamic gl) {
    try {
      // Quick capability probe: counter bits for TIME_ELAPSED must be > 0
      final bits = _queryCounterBits(gl);
      if (bits <= 0) return null;

      final profiler = DisjointQueryGpuProfiler._(gl);
      // Pre-allocate a small pool of query objects.
      for (var i = 0; i < _poolSize; i++) {
        profiler._pool.add(profiler._genQuery());
      }
      return profiler;
    } catch (_) {
      // If any symbol is missing or lookup fails, bail out cleanly.
      return null;
    }
  }

  // ---- GLES helpers --------------------------------------------------------

  static int _queryCounterBits(dynamic gl) {
    final p = ffix.calloc<ffi.Int32>();
    try {
      // glGetQueryiv(GL_TIME_ELAPSED_EXT, GL_QUERY_COUNTER_BITS_EXT, &bits)
      gl.glGetQueryiv(
          angle.GL_TIME_ELAPSED_EXT, angle.GL_QUERY_COUNTER_BITS_EXT, p,);
      return p.value;
    } finally {
      ffix.calloc.free(p);
    }
  }

  int _genQuery() {
    final p = ffix.calloc<ffi.Uint32>();
    try {
      gl.glGenQueries(1, p);
      return p.value;
    } finally {
      ffix.calloc.free(p);
    }
  }

  void _deleteQuery(int id) {
    final p = ffix.calloc<ffi.Uint32>();
    try {
      p.value = id;
      gl.glDeleteQueries(1, p);
    } finally {
      ffix.calloc.free(p);
    }
  }

  int _getQueryObjectuiv(int id, int pname) {
    final p = ffix.calloc<ffi.Uint32>();
    try {
      gl.glGetQueryObjectuiv(id, pname, p);
      return p.value;
    } finally {
      ffix.calloc.free(p);
    }
  }

  /// Prefer 64-bit results if your binding exposes `glGetQueryObjectui64vEXT`.
  num _getQueryResultNs(int id) {
    try {
      final f = (gl as dynamic).glGetQueryObjectui64vEXT;
      if (f != null) {
        final p64 = ffix.calloc<ffi.Uint64>();
        try {
          f(id, angle.GL_QUERY_RESULT_EXT, p64);
          return p64.value; // nanoseconds
        } finally {
          ffix.calloc.free(p64);
        }
      }
    } catch (_) {
      // 64-bit path not present—fall through to 32-bit.
    }
    return _getQueryObjectuiv(
        id, angle.GL_QUERY_RESULT_EXT,); // ns (lower 32 bits)
  }

  bool _gpuDisjoint() {
    // EXT says read GPU_DISJOINT_EXT via GetBooleanv or GetIntegerv.
    // Use GetIntegerv for compatibility; treat nonzero as "true".
    final p = ffix.calloc<ffi.Int32>();
    try {
      gl.glGetIntegerv(angle.GL_GPU_DISJOINT_EXT, p);
      return p.value != 0;
    } finally {
      ffix.calloc.free(p);
    }
  }

  // ---- PerfProfiler API ----------------------------------------------------

  @override
  void beginFrame() {
    _beganThisFrame = false;
    _sw
      ..reset()
      ..start();
  }

  int? _alloc() => _pool.isNotEmpty ? _pool.removeLast() : null;
  void _recycle(int id) => _pool.add(id);

  @override
  void markGpuBegin(dynamic _) {
    final q = _alloc();
    if (q == null) return; // No free query this frame.
    gl.glBeginQuery(angle.GL_TIME_ELAPSED_EXT, q);
    _inFlight.addLast(q);
    _beganThisFrame = true;
  }

  @override
  void markGpuEnd(dynamic _) {
    if (_beganThisFrame) {
      gl.glEndQuery(angle.GL_TIME_ELAPSED_EXT);
    }
  }

  double? _harvest() {
    // If GPU became disjoint, pending results are invalid—drop them.
    if (_gpuDisjoint()) {
      while (_inFlight.isNotEmpty) {
        _recycle(_inFlight.removeFirst());
      }
      return null;
    }

    double? ms;
    while (_inFlight.isNotEmpty) {
      final id = _inFlight.first;

      // Non-blocking readiness check
      final ready =
          _getQueryObjectuiv(id, angle.GL_QUERY_RESULT_AVAILABLE_EXT) != 0;
      if (!ready) break;

      _inFlight.removeFirst();

      final ns = _getQueryResultNs(id); // nanoseconds
      ms = ns / 1e6; // → milliseconds
      _recycle(id);
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
      for (final id in _pool) {
        try {
          _deleteQuery(id);
        } catch (_) {}
      }
    } catch (_) {}
    _pool.clear();
  }
}
