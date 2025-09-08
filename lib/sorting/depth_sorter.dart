import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_gaussian_splatter/sorting/sort_result.dart';
import 'package:vector_math/vector_math.dart';

/// Implementation of DepthSorter using isolate-based processing.
///
/// This implementation provides efficient depth sorting with the following
/// optimizations:
/// - Background isolate processing to avoid blocking the main thread
/// - Memory reuse to reduce garbage collection pressure
class DepthSorterImpl {
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
  Completer<void>? _firstSortComplete;

  // Reusable arrays for matrix operations
  final List<double> _viewProjectionList = List<double>.filled(16, 0);

  /// init
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
        onSortComplete?.call(msg);
        // Complete first sort future if this is the first sort
        if (_firstSortComplete != null && !_firstSortComplete!.isCompleted) {
          _firstSortComplete!.complete();
        }
      }
    });

    Isolate.spawn<_SorterIsolateConfig>(
      _sortIsolateEntry,
      _SorterIsolateConfig(_receivePort.sendPort),
      debugName: 'DepthSortIsolate',
    ).then((iso) => _isolate = iso);

    return sendPortCompleter.future.then((_) => _ready!.complete());
  }

  /// Dispose
  void dispose() {
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  /// Returns a future that completes when the first sort finishes
  Future<void> get firstSortComplete {
    _firstSortComplete ??= Completer<void>();
    return _firstSortComplete!.future;
  }

  /// Run sort
  SortResult runSort(
    Matrix4 viewProjection,
    Uint8List buffer,
    int vertexCount,
  ) {
    if (_ready == null || !_ready!.isCompleted) {
      throw StateError('DepthSorter.initialize() must be awaited first');
    }

    _sendPort.send(
      _SortRequest(
        viewProjection: _matToListReuse(viewProjection),
        buffer: buffer,
        vertexCount: vertexCount,
      ),
    );

    return _empty(viewProjection);
  }

  static SortResult _empty(Matrix4 viewProjection) => SortResult(
        depthIndex: Uint32List(0),
        viewProjection: viewProjection,
        vertexCount: 0,
      );

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

  final fBuf = Float32List.view(request.buffer.buffer);

  // ----- NEW: floats per splat -----
  final floatsPerSplat =
      request.buffer.lengthInBytes ~/ request.vertexCount ~/ 4;

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

  final tmp = _isolateTmpArray!;

  var minD = 0x7fffffff;
  var maxD = -0x7fffffff;

  final vp = request.viewProjection;
  final vp2 = vp[2];
  final vp6 = vp[6];
  final vp10 = vp[10];

  // Calculate depth values
  for (var i = 0; i < n; ++i) {
    final base = floatsPerSplat * i;
    final d =
        ((vp2 * fBuf[base + 0] + vp6 * fBuf[base + 1] + vp10 * fBuf[base + 2]) *
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
