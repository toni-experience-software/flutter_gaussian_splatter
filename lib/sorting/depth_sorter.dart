import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
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

  /// Order buffer returned from the last sort, handed back to the isolate on
  /// the next request so it can be reused instead of reallocated.
  TransferableTypedData? _recycledOrder;

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
      if (msg is _SortResponse) {
        // Zero-copy: the order buffer's bytes are transferred (not copied)
        // across the isolate boundary. An empty sort carries a sentinel
        // payload, mapped back to an empty order here.
        final order = msg.vertexCount == 0
            ? Uint32List(0)
            : msg.order.materialize().asUint32List();
        onSortComplete?.call(
          SortResult(
            depthIndex: order,
            viewProjection: Matrix4.fromList(msg.viewProjection),
            vertexCount: msg.vertexCount,
            visibleCount: msg.visibleCount,
            generation: msg.generation,
            dataGeneration: msg.dataGeneration,
          ),
        );
        // The callback (uploadOrder) has copied the indices into the GPU
        // texture, so hand the buffer back to the isolate to reuse next sort —
        // zero steady-state allocation.
        if (msg.vertexCount > 0) {
          _recycledOrder = TransferableTypedData.fromList([order]);
        }
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
  void setSplatData(Uint8List buffer, int vertexCount) {
    if (_ready == null || !_ready!.isCompleted) {
      throw StateError('DepthSorter.initialize() must be awaited first');
    }

    _sendPort.send(
      _SetDataRequest(
        buffer: buffer,
        vertexCount: vertexCount,
      ),
    );
  }

  /// Run sort
  SortResult runSort(
    Matrix4 viewProjection, {
    required int generation,
    required int dataGeneration,
  }) {
    if (_ready == null || !_ready!.isCompleted) {
      throw StateError('DepthSorter.initialize() must be awaited first');
    }

    _sendPort.send(
      _SortRequest(
        viewProjection: _matToListReuse(viewProjection),
        generation: generation,
        dataGeneration: dataGeneration,
        recycled: _recycledOrder,
      ),
    );
    _recycledOrder = null; // handed off to the isolate

    return _empty(
      viewProjection,
      generation: generation,
      dataGeneration: dataGeneration,
    );
  }

  static SortResult _empty(
    Matrix4 viewProjection, {
    required int generation,
    required int dataGeneration,
  }) =>
      SortResult(
        depthIndex: Uint32List(0),
        viewProjection: viewProjection,
        vertexCount: 0,
        generation: generation,
        dataGeneration: dataGeneration,
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
class _SetDataRequest {
  const _SetDataRequest({
    required this.buffer,
    required this.vertexCount,
  });
  final Uint8List buffer;
  final int vertexCount;
}

/// Request message for depth sorting operation.
class _SortRequest {
  const _SortRequest({
    required this.viewProjection,
    required this.generation,
    required this.dataGeneration,
    this.recycled,
  });
  final List<double> viewProjection;
  final int generation;
  final int dataGeneration;

  /// A previously-emitted order buffer handed back for reuse (zero-copy).
  final TransferableTypedData? recycled;
}

/// Response message carrying the sorted order via a zero-copy transfer.
class _SortResponse {
  const _SortResponse({
    required this.order,
    required this.viewProjection,
    required this.vertexCount,
    required this.visibleCount,
    required this.generation,
    required this.dataGeneration,
  });
  final TransferableTypedData order;
  final List<double> viewProjection;
  final int vertexCount;
  final int visibleCount;
  final int generation;
  final int dataGeneration;
}

/// Entry point for the sorting isolate.
void _sortIsolateEntry(_SorterIsolateConfig config) {
  final toMain = config.mainPort;
  final port = ReceivePort();
  toMain.send(port.sendPort);

  port.listen((msg) {
    if (msg is _SetDataRequest) {
      _setIsolateData(msg);
    } else if (msg is _SortRequest) {
      toMain.send(_performSort(msg));
    }
  });
}

// Reusable arrays in isolate to prevent allocations
Int32List? _isolateTmpArray;
Uint32List? _isolateCountsArray;
Uint32List? _isolateStartsArray;
Float32List? _isolatePositions;
int _isolateVertexCount = 0;

// Per-chunk bounding spheres for frustum culling (256-splat chunks).
const int _chunkSize = 256;
const int _chunkShift = 8; // log2(_chunkSize)
Float32List? _isolateChunkCenters; // xyz per chunk
Float32List? _isolateChunkRadii;
Uint8List? _isolateChunkVisible;
int _isolateChunkCount = 0;

/// Builds one bounding sphere per 256-splat chunk (center = centroid, radius =
/// max distance to centroid). Computed once when data is uploaded.
void _buildChunkSpheres(Float32List positions, int n) {
  final chunkCount = (n + _chunkSize - 1) >> _chunkShift;
  final centers = Float32List(chunkCount * 3);
  final radii = Float32List(chunkCount);

  for (var c = 0; c < chunkCount; c++) {
    final start = c << _chunkShift;
    final end = math.min(start + _chunkSize, n);
    final count = end - start;

    var sx = 0.0;
    var sy = 0.0;
    var sz = 0.0;
    for (var i = start; i < end; i++) {
      final b = i * 3;
      sx += positions[b];
      sy += positions[b + 1];
      sz += positions[b + 2];
    }
    final cx = sx / count;
    final cy = sy / count;
    final cz = sz / count;

    var maxR2 = 0.0;
    for (var i = start; i < end; i++) {
      final b = i * 3;
      final dx = positions[b] - cx;
      final dy = positions[b + 1] - cy;
      final dz = positions[b + 2] - cz;
      final r2 = dx * dx + dy * dy + dz * dz;
      if (r2 > maxR2) maxR2 = r2;
    }

    final cb = c * 3;
    centers[cb] = cx;
    centers[cb + 1] = cy;
    centers[cb + 2] = cz;
    radii[c] = math.sqrt(maxR2);
  }

  _isolateChunkCenters = centers;
  _isolateChunkRadii = radii;
  _isolateChunkCount = chunkCount;
  _isolateChunkVisible = Uint8List(chunkCount);
}

/// Marks each chunk visible unless its sphere is fully outside one of the four
/// lateral frustum planes (left/right/top/bottom) derived from [vp]. Near/far
/// are intentionally skipped — they're convention-sensitive and behind-camera
/// splats are already truncated separately.
void _computeChunkVisibility(List<double> vp) {
  final centers = _isolateChunkCenters;
  final radii = _isolateChunkRadii;
  final visible = _isolateChunkVisible;
  if (centers == null || radii == null || visible == null) return;

  // Column-major storage: element [row, col] = vp[col * 4 + row].
  // row_r = (vp[r], vp[4+r], vp[8+r], vp[12+r]).
  // left = row3 + row0, right = row3 - row0,
  // bottom = row3 + row1, top = row3 - row1.
  final planes = <double>[
    vp[3] + vp[0], vp[7] + vp[4], vp[11] + vp[8], vp[15] + vp[12], // left
    vp[3] - vp[0], vp[7] - vp[4], vp[11] - vp[8], vp[15] - vp[12], // right
    vp[3] + vp[1], vp[7] + vp[5], vp[11] + vp[9], vp[15] + vp[13], // bottom
    vp[3] - vp[1], vp[7] - vp[5], vp[11] - vp[9], vp[15] - vp[13], // top
  ];
  // Normalize each plane by its normal length so distances are metric.
  for (var p = 0; p < 4; p++) {
    final o = p * 4;
    final a = planes[o];
    final b = planes[o + 1];
    final c = planes[o + 2];
    final len = math.sqrt(a * a + b * b + c * c);
    if (len > 0) {
      final inv = 1.0 / len;
      planes[o] = a * inv;
      planes[o + 1] = b * inv;
      planes[o + 2] = c * inv;
      planes[o + 3] *= inv;
    }
  }

  for (var c = 0; c < _isolateChunkCount; c++) {
    final cb = c * 3;
    final cx = centers[cb];
    final cy = centers[cb + 1];
    final cz = centers[cb + 2];
    final r = radii[c];
    var inside = true;
    for (var p = 0; p < 4; p++) {
      final o = p * 4;
      final dist = planes[o] * cx + planes[o + 1] * cy + planes[o + 2] * cz +
          planes[o + 3];
      if (dist < -r) {
        inside = false;
        break;
      }
    }
    visible[c] = inside ? 1 : 0;
  }
}

/// Radix bucket count scaled to scene size: `2^clamp(log2(N/4), 10, 20)`.
/// Small scenes use fewer buckets (less memory/cache pressure); large scenes
/// cap at 2^20 buckets.
int _adaptiveBucketCount(int n) {
  if (n <= 0) return 1 << 10;
  final exponent = (math.log(n / 4) / math.ln2).floor().clamp(10, 20);
  return 1 << exponent;
}

void _setIsolateData(_SetDataRequest request) {
  _isolateVertexCount = request.vertexCount;
  if (request.vertexCount <= 0 || request.buffer.isEmpty) {
    _isolatePositions = Float32List(0);
    _isolateChunkCount = 0;
    _isolateChunkCenters = null;
    _isolateChunkRadii = null;
    _isolateChunkVisible = null;
    return;
  }

  final fBuf = Float32List.view(request.buffer.buffer);
  final floatsPerSplat =
      request.buffer.lengthInBytes ~/ request.vertexCount ~/ 4;
  final positions = Float32List(request.vertexCount * 3);
  for (var i = 0; i < request.vertexCount; i++) {
    final sourceBase = floatsPerSplat * i;
    final targetBase = i * 3;
    positions[targetBase] = fBuf[sourceBase];
    positions[targetBase + 1] = fBuf[sourceBase + 1];
    positions[targetBase + 2] = fBuf[sourceBase + 2];
  }
  _isolatePositions = positions;
  _buildChunkSpheres(positions, request.vertexCount);
}

/// Builds a zero-copy response by transferring ownership of [out] to main.
/// After this call [out] must not be touched again on the isolate.
_SortResponse _response(
  _SortRequest request,
  Uint32List out, {
  required int vertexCount,
  required int visibleCount,
}) {
  return _SortResponse(
    order: TransferableTypedData.fromList([out]),
    viewProjection: request.viewProjection,
    vertexCount: vertexCount,
    visibleCount: visibleCount,
    generation: request.generation,
    dataGeneration: request.dataGeneration,
  );
}

/// Perform the actual depth sorting using radix sort algorithm.
_SortResponse _performSort(_SortRequest request) {
  final n = _isolateVertexCount;
  final positions = _isolatePositions;
  if (n == 0 || positions == null || positions.isEmpty) {
    // TransferableTypedData requires a non-empty payload; main maps a
    // vertexCount of 0 back to an empty order.
    return _response(
      request,
      Uint32List(1),
      vertexCount: 0,
      visibleCount: 0,
    );
  }

  // Reuse the order buffer handed back from the previous sort, else allocate.
  final recycled = request.recycled;
  final Uint32List out;
  if (recycled != null) {
    final materialized = recycled.materialize().asUint32List();
    out = materialized.length == n ? materialized : Uint32List(n);
  } else {
    out = Uint32List(n);
  }

  // Adaptive bucket count: scale sort-key precision to scene size instead of a
  // fixed 65536, cutting memory/cache pressure for small scenes.
  final buckets = _adaptiveBucketCount(n);
  // One extra bucket (index == buckets) collects behind-camera splats so they
  // land in the tail of the order and can be skipped at draw time.
  final bucketSlots = buckets + 1;

  // Initialize or reuse arrays
  if (_isolateTmpArray == null || _isolateTmpArray!.length < n) {
    _isolateTmpArray = Int32List(n);
  }
  final counts0 = _isolateCountsArray;
  if (counts0 == null || counts0.length < bucketSlots) {
    _isolateCountsArray = Uint32List(bucketSlots);
  } else {
    counts0.fillRange(0, bucketSlots, 0);
  }
  final starts0 = _isolateStartsArray;
  if (starts0 == null || starts0.length < bucketSlots) {
    _isolateStartsArray = Uint32List(bucketSlots);
  } else {
    starts0.fillRange(0, bucketSlots, 0);
  }
  final tmp = _isolateTmpArray!;

  var minD = 0x7fffffff;
  var maxD = -0x7fffffff;

  final vp = request.viewProjection;
  final vp2 = vp[2];
  final vp6 = vp[6];
  final vp10 = vp[10];
  // Clip-space w row (column-major storage): a splat is in front of the camera
  // when w > 0, which mirrors the vertex shader's behind-camera cull.
  final vp3 = vp[3];
  final vp7 = vp[7];
  final vp11 = vp[11];
  final vp15 = vp[15];

  // Sentinel marking a behind-camera splat; recomputing w in the bucketing
  // pass would be redundant, so we stash the flag in the depth scratch array.
  const behindMarker = 0x7fffffff;

  // Frustum-cull whole chunks against the lateral planes; off-screen chunks
  // are parked in the tail alongside behind-camera splats.
  _computeChunkVisibility(vp);
  final chunkVisible = _isolateChunkVisible;

  // Calculate depth values (min/max over in-front splats only).
  for (var i = 0; i < n; ++i) {
    if (chunkVisible != null && chunkVisible[i >> _chunkShift] == 0) {
      tmp[i] = behindMarker;
      continue;
    }
    final base = i * 3;
    final x = positions[base];
    final y = positions[base + 1];
    final z = positions[base + 2];
    final w = vp3 * x + vp7 * y + vp11 * z + vp15;
    if (w <= 0) {
      tmp[i] = behindMarker;
      continue;
    }
    final d = ((vp2 * x + vp6 * y + vp10 * z) * 4096).toInt();
    tmp[i] = d;
    if (d < minD) minD = d;
    if (d > maxD) maxD = d;
  }

  final range = maxD - minD;
  if (maxD < minD || range == 0) {
    // No in-front splats, or all in-front depths equal: keep input order for
    // the in-front prefix and push behind-camera splats to the tail.
    var head = 0;
    var tail = n;
    for (var i = 0; i < n; ++i) {
      if (tmp[i] == behindMarker) {
        out[--tail] = i;
      } else {
        out[head++] = i;
      }
    }
    return _response(request, out, vertexCount: n, visibleCount: head);
  }

  // Radix sort implementation.
  final depthInv = (buckets - 1) / range;
  final counts = _isolateCountsArray!;

  for (var i = 0; i < n; ++i) {
    final d = tmp[i];
    final key = d == behindMarker
        ? buckets // reserved behind-camera bucket → ordered into the tail
        : (buckets - 1) - ((d - minD) * depthInv).toInt();
    tmp[i] = key;
    counts[key]++;
  }

  final behindCount = counts[buckets];

  final starts = _isolateStartsArray!;
  for (var i = 1; i <= buckets; ++i) {
    starts[i] = starts[i - 1] + counts[i - 1];
  }

  for (var i = 0; i < n; ++i) {
    final k = tmp[i];
    out[starts[k]++] = i;
  }

  return _response(request, out, vertexCount: n, visibleCount: n - behindCount);
}
