import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

/// Abstract interface for depth sorting Gaussian splats.
///
/// Depth sorting is essential for proper alpha blending of Gaussian splats.
/// This interface provides both immediate and throttled sorting capabilities.
abstract class DepthSorter {
  /// Initialize the depth sorter and any background resources.
  Future<void> initialize();

  /// Dispose of resources and clean up background processes.
  void dispose();

  /// Perform immediate depth sorting.
  ///
  /// Parameters:
  /// - [viewProjection]: Current view-projection matrix
  /// - [buffer]: Gaussian splat data buffer
  /// - [vertexCount]: Number of vertices to sort
  ///
  /// Returns [SortResult] with depth-sorted indices.
  SortResult runSort(Matrix4 viewProjection, Uint8List buffer, int vertexCount);

  /// Perform throttled depth sorting to reduce computational overhead.
  ///
  /// This method implements frame-based throttling and camera movement
  /// detection to avoid unnecessary sorting operations.
  ///
  /// Parameters:
  /// - [viewProjection]: Current view-projection matrix
  /// - [buffer]: Gaussian splat data buffer
  /// - [vertexCount]: Number of vertices to sort
  void throttledSort(
    Matrix4 viewProjection,
    Uint8List buffer,
    int vertexCount,
  );
}

/// Result of a depth sorting operation.
///
/// Contains the sorted indices and metadata about the sorting operation.
class SortResult {
  /// Creates a new [SortResult] with the specified parameters.
  ///
  /// Parameters:
  /// - [depthIndex]: Array of depth-sorted vertex indices
  /// - [viewProjection]: View-projection matrix used for sorting
  /// - [vertexCount]: Number of vertices that were sorted
  const SortResult({
    required this.depthIndex,
    required this.viewProjection,
    required this.vertexCount,
  });

  /// Depth-sorted indices array.
  final Uint32List depthIndex;

  /// View-projection matrix used for sorting.
  final Matrix4 viewProjection;

  /// Number of vertices that were sorted.
  final int vertexCount;
}

/// Implementation of [DepthSorter] using isolate-based processing.
///
/// This implementation provides efficient depth sorting with the following
/// optimizations:
/// - Background isolate processing to avoid blocking the main thread
/// - Memory reuse to reduce garbage collection pressure
/// - Frame-based throttling to reduce sorting frequency
/// - Camera movement detection to skip unnecessary sorts
class DepthSorterImpl implements DepthSorter {
  /// Creates a new [DepthSorterImpl] with optional sort completion callback.
  ///
  /// Parameters:
  /// - [onSortComplete]: Optional callback invoked when asynchronous sorting 
  /// completes
  DepthSorterImpl({this.onSortComplete});

  /// Callback invoked when asynchronous sorting completes.
  final void Function(SortResult result)? onSortComplete;

  late final ReceivePort _receivePort;
  late final Isolate _isolate;
  late SendPort _sendPort;

  Completer<void>? _ready;

  Matrix4? _lastProjection;
  int? _lastVertexCount;
  SortResult? _lastResult;
  bool _sortRunning = false;

  // Frame-based throttling configuration
  int _frameCounter = 0;
  static const int _sortEveryNFrames = 3;

  // Reusable arrays for matrix operations
  final List<double> _viewProjectionList = List<double>.filled(16, 0);

  @override
  Future<void> initialize() {
    if (_ready != null) return _ready!.future;

    _ready = Completer<void>();
    _receivePort = ReceivePort();

    final sendPortCompleter = Completer<SendPort>();
    _receivePort.listen((msg) {
      if (msg is SendPort) {
        if (!sendPortCompleter.isCompleted) {
          _sendPort = msg;
          sendPortCompleter.complete(msg);
        }
        return;
      }
      if (msg is SortResult) {
        _lastResult = msg;
        _sortRunning = false;
        onSortComplete?.call(msg);
      }
    });

    Isolate.spawn<_SorterIsolateConfig>(
      _sortIsolateEntry,
      _SorterIsolateConfig(_receivePort.sendPort),
      debugName: 'DepthSortIsolate',
    ).then((iso) => _isolate = iso);

    return sendPortCompleter.future.then((_) => _ready!.complete());
  }

  @override
  void dispose() {
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  @override
  SortResult runSort(
    Matrix4 viewProjection,
    Uint8List buffer,
    int vertexCount,
  ) {
    if (_ready == null || !_ready!.isCompleted) {
      throw StateError('DepthSorter.initialize() must be awaited first');
    }

    // Check if sorting is needed based on camera movement
    if (_lastProjection != null &&
        _lastVertexCount == vertexCount &&
        _matricesEqual(viewProjection, _lastProjection!)) {
      return _lastResult ?? _empty(viewProjection);
    }

    _sendPort.send(
      _SortRequest(
        viewProjection: _matToListReuse(viewProjection),
        buffer: buffer,
        vertexCount: vertexCount,
      ),
    );

    // Update tracking state
    _lastProjection ??= Matrix4.identity();
    _lastProjection!.setFrom(viewProjection);
    _lastVertexCount = vertexCount;
    _sortRunning = true;

    return _lastResult ?? _empty(viewProjection);
  }

  @override
  void throttledSort(
    Matrix4 viewProjection,
    Uint8List buffer,
    int vertexCount,
  ) {
    // Frame-based throttling
    _frameCounter++;
    if (_frameCounter % _sortEveryNFrames != 0) {
      return;
    }

    if (_sortRunning) {
      return;
    }

    // Camera movement detection
    if (_lastProjection != null &&
        _lastVertexCount == vertexCount &&
        (_dot(_lastProjection!, viewProjection) - 1.0).abs() < 0.1) {
      return;
    }

    runSort(viewProjection, buffer, vertexCount);
  }

  static SortResult _empty(Matrix4 viewProjection) => SortResult(
        depthIndex: Uint32List(0),
        viewProjection: viewProjection,
        vertexCount: 0,
      );

  static double _dot(Matrix4 a, Matrix4 b) =>
      a.entry(0, 2) * b.entry(0, 2) +
      a.entry(1, 2) * b.entry(1, 2) +
      a.entry(2, 2) * b.entry(2, 2);

  static bool _matricesEqual(Matrix4 a, Matrix4 b) {
    return _matricesEqualThreshold(a, b, 0.001);
  }

  static bool _matricesEqualThreshold(Matrix4 a, Matrix4 b, double threshold) {
    final storage1 = a.storage;
    final storage2 = b.storage;
    for (var i = 0; i < 16; i++) {
      if ((storage1[i] - storage2[i]).abs() > threshold) {
        return false;
      }
    }
    return true;
  }

  List<double> _matToListReuse(Matrix4 matrix) {
    final storage = matrix.storage;
    for (var i = 0; i < 16; i++) {
      _viewProjectionList[i] = storage[i];
    }
    return _viewProjectionList;
  }
}

/// Configuration for the sorting isolate.
class _SorterIsolateConfig {
  const _SorterIsolateConfig(this.mainPort);
  final SendPort mainPort;
}

/// Request message for depth sorting operation.
class _SortRequest {

  const _SortRequest({
    required this.viewProjection,
    required this.buffer,
    required this.vertexCount,
  });
  final List<double> viewProjection;
  final Uint8List buffer;
  final int vertexCount;
}

/// Entry point for the sorting isolate.
void _sortIsolateEntry(_SorterIsolateConfig config) {
  final toMain = config.mainPort;
  final port = ReceivePort();
  toMain.send(port.sendPort);

  port.listen((msg) {
    if (msg is _SortRequest) {
      toMain.send(_performSort(msg));
    }
  });
}

// Reusable arrays in isolate to prevent allocations
Int32List? _isolateTmpArray;
Uint32List? _isolateCountsArray;
Uint32List? _isolateStartsArray;
Uint32List? _isolateOutputArray;
const int _isolateBuckets = 256 * 256;

/// Perform the actual depth sorting using radix sort algorithm.
SortResult _performSort(_SortRequest request) {
  final n = request.vertexCount;
  if (n == 0 || request.buffer.isEmpty) {
    return SortResult(
      depthIndex: Uint32List(0),
      viewProjection: Matrix4.fromList(request.viewProjection),
      vertexCount: 0,
    );
  }

  // Initialize or reuse arrays
  if (_isolateTmpArray == null || _isolateTmpArray!.length < n) {
    _isolateTmpArray = Int32List(n);
  }
  if (_isolateCountsArray == null) {
    _isolateCountsArray = Uint32List(_isolateBuckets);
  } else {
    _isolateCountsArray!.fillRange(0, _isolateBuckets, 0);
  }
  if (_isolateStartsArray == null) {
    _isolateStartsArray = Uint32List(_isolateBuckets);
  } else {
    _isolateStartsArray!.fillRange(0, _isolateBuckets, 0);
  }
  if (_isolateOutputArray == null || _isolateOutputArray!.length < n) {
    _isolateOutputArray = Uint32List(n);
  }

  final fBuf = Float32List.view(request.buffer.buffer);
  final tmp = _isolateTmpArray!;

  var minD = 0x7fffffff;
  var maxD = -0x7fffffff;

  final vp = request.viewProjection;
  final vp2 = vp[2];
  final vp6 = vp[6];
  final vp10 = vp[10];

  // Calculate depth values
  for (var i = 0; i < n; ++i) {
    final d = ((vp2 * fBuf[8 * i + 0] +
                vp6 * fBuf[8 * i + 1] +
                vp10 * fBuf[8 * i + 2]) *
            4096)
        .toInt();
    tmp[i] = d;
    if (d < minD) minD = d;
    if (d > maxD) maxD = d;
  }

  final range = maxD - minD;
  if (range == 0) {
    // All depths are equal, return identity order
    for (var i = 0; i < n; ++i) {
      _isolateOutputArray![i] = i;
    }
    return SortResult(
      depthIndex: Uint32List.fromList(_isolateOutputArray!.take(n).toList()),
      viewProjection: Matrix4.fromList(request.viewProjection),
      vertexCount: n,
    );
  }

  // Radix sort implementation
  const buckets = _isolateBuckets;
  final depthInv = (buckets - 1) / range;
  final counts = _isolateCountsArray!;

  for (var i = 0; i < n; ++i) {
    final key = (buckets - 1) - ((tmp[i] - minD) * depthInv).toInt();
    tmp[i] = key;
    counts[key]++;
  }

  final starts = _isolateStartsArray!;
  for (var i = 1; i < buckets; ++i) {
    starts[i] = starts[i - 1] + counts[i - 1];
  }

  final out = _isolateOutputArray!;
  for (var i = 0; i < n; ++i) {
    final k = tmp[i];
    out[starts[k]++] = i;
  }

  return SortResult(
    depthIndex: Uint32List.fromList(out.take(n).toList()),
    viewProjection: Matrix4.fromList(request.viewProjection),
    vertexCount: n,
  );
}
