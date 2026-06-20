import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gaussian_splatter/constants.dart';

/// Two row-aligned splat buffers describing a morph: entry `i` in [bufferA] and
/// entry `i` in [bufferB] are the same logical splat at the start and end of
/// the transition. Both use the standard 128-byte CPU layout, so each uploads
/// through the normal `GpuSplatSource.uploadSplats` path unchanged.
class AlignedMorph {
  /// Creates an aligned morph result.
  const AlignedMorph(this.bufferA, this.bufferB, this.count);

  /// Start-state splats (128 B each, [count] entries).
  final Uint8List bufferA;

  /// End-state splats (128 B each, [count] entries), aligned to [bufferA].
  final Uint8List bufferB;

  /// Number of aligned entries.
  final int count;
}

/// Parameters for [buildCorrespondence], packaged so the call can run through
/// Flutter's `compute` on a background isolate.
class CorrespondenceParams {
  /// Creates correspondence parameters from two processed splat buffers.
  const CorrespondenceParams({
    required this.a,
    required this.b,
    this.spatialWeight = 0.7,
    this.colorWeight = 0.3,
    this.distanceThreshold = double.infinity,
  });

  /// Start-state buffer (128 B per splat).
  final Uint8List a;

  /// End-state buffer (128 B per splat).
  final Uint8List b;

  /// Weight on squared spatial distance in the match cost.
  final double spatialWeight;

  /// Weight on squared base-color distance in the match cost.
  final double colorWeight;

  /// Maximum spatial distance a match may span; beyond it the splat is left
  /// unmatched (vanishes / appears) instead of teleporting.
  final double distanceThreshold;
}

/// Pairs splats purely by index: `A[i]` ↔ `B[i]`. No spatial matching — motion
/// follows whatever order the buffers already have. The surplus from the larger
/// buffer is left partnerless (zero scale + opacity) so it scales/fades in (when
/// B is larger) or out (when A is larger).
AlignedMorph buildIndexAlignment(Uint8List a, Uint8List b) {
  const stride = GsConst.bytesPerSplat;
  const fStride = stride ~/ 4;
  final na = a.length ~/ stride;
  final nb = b.length ~/ stride;
  final n = math.max(na, nb);
  final outA = Uint8List(n * stride);
  final outB = Uint8List(n * stride);

  void copyRow(Uint8List dst, int di, Uint8List src, int si) =>
      dst.setRange(di * stride, di * stride + stride, src, si * stride);
  void zeroPresence(Uint8List buf, int i) {
    final f = Float32List.view(buf.buffer, buf.offsetInBytes, buf.length ~/ 4);
    final o = i * fStride;
    f[o + 3] = 0;
    f[o + 4] = 0;
    f[o + 5] = 0;
    buf[i * stride + GsConst.colorOffset + 3] = 0;
  }

  for (var i = 0; i < n; i++) {
    final hasA = i < na;
    final hasB = i < nb;
    if (hasA && hasB) {
      copyRow(outA, i, a, i);
      copyRow(outB, i, b, i);
    } else if (hasB) {
      copyRow(outB, i, b, i); // appear: start collapsed at B's spot
      copyRow(outA, i, b, i);
      zeroPresence(outA, i);
    } else {
      copyRow(outA, i, a, i); // vanish: end collapsed at A's spot
      copyRow(outB, i, a, i);
      zeroPresence(outB, i);
    }
  }
  return AlignedMorph(outA, outB, n);
}

// Spreads the low 10 bits of [n] so they occupy every third bit (for 3D Morton
// interleave). 30-bit result fits a signed 32-bit int.
int _part1By2(int value) {
  var n = value & 0x3ff;
  n = (n | (n << 16)) & 0x30000ff;
  n = (n | (n << 8)) & 0x300f00f;
  n = (n | (n << 4)) & 0x30c30c3;
  n = (n | (n << 2)) & 0x9249249;
  return n;
}

int _morton10(int x, int y, int z) =>
    _part1By2(x) | (_part1By2(y) << 1) | (_part1By2(z) << 2);

/// Returns splat indices of [buf] ordered along a 10-bit-per-axis Morton
/// (Z-order) curve, normalized by robust 2–98 percentile bounds so floaters
/// don't crush the quantization. Nearby splats get nearby ranks.
List<int> _mortonOrder(Uint8List buf) {
  const stride = GsConst.bytesPerSplat;
  final v = ByteData.view(buf.buffer, buf.offsetInBytes, buf.length);
  final n = buf.length ~/ stride;
  final lo = List<double>.filled(3, 0);
  final span = List<double>.filled(3, 1);
  for (var c = 0; c < 3; c++) {
    final vals = List<double>.generate(
      n,
      (i) => v.getFloat32(i * stride + c * 4, Endian.little),
    )..sort();
    final l = vals[(n * 0.02).floor()];
    final h = vals[(n * 0.98).floor()];
    lo[c] = l;
    span[c] = h > l ? h - l : 1;
  }
  final codes = Int32List(n);
  final q = List<int>.filled(3, 0);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < 3; c++) {
      final t =
          (v.getFloat32(i * stride + c * 4, Endian.little) - lo[c]) / span[c];
      q[c] = (t * 1023).round().clamp(0, 1023);
    }
    codes[i] = _morton10(q[0], q[1], q[2]);
  }
  return List<int>.generate(n, (i) => i)
    ..sort((x, y) => codes[x] - codes[y]);
}

/// Pairs splats by spatial rank: both clouds are sorted along a Morton
/// (Z-order) curve, then rank `k` of A is matched to rank `k` of B. The curve
/// preserves locality, neighbouring splats travel together and the source cloud
/// coherently flows into the target shape (the "fly to new position" look),
/// rather than scattering. Surplus from the larger cloud fades/scales in or out.
AlignedMorph buildMortonAlignment(Uint8List a, Uint8List b) {
  const stride = GsConst.bytesPerSplat;
  const fStride = stride ~/ 4;
  final na = a.length ~/ stride;
  final nb = b.length ~/ stride;
  final orderA = _mortonOrder(a);
  final orderB = _mortonOrder(b);
  final n = math.max(na, nb);
  final outA = Uint8List(n * stride);
  final outB = Uint8List(n * stride);

  void copyRow(Uint8List dst, int di, Uint8List src, int si) =>
      dst.setRange(di * stride, di * stride + stride, src, si * stride);
  void zeroPresence(Uint8List buf, int i) {
    final f = Float32List.view(buf.buffer, buf.offsetInBytes, buf.length ~/ 4);
    final o = i * fStride;
    f[o + 3] = 0;
    f[o + 4] = 0;
    f[o + 5] = 0;
    buf[i * stride + GsConst.colorOffset + 3] = 0;
  }

  for (var k = 0; k < n; k++) {
    final hasA = k < na;
    final hasB = k < nb;
    if (hasA && hasB) {
      copyRow(outA, k, a, orderA[k]);
      copyRow(outB, k, b, orderB[k]);
    } else if (hasB) {
      copyRow(outB, k, b, orderB[k]); // appear: start collapsed at B's spot
      copyRow(outA, k, b, orderB[k]);
      zeroPresence(outA, k);
    } else {
      copyRow(outA, k, a, orderA[k]); // vanish: end collapsed at A's spot
      copyRow(outB, k, a, orderA[k]);
      zeroPresence(outB, k);
    }
  }
  return AlignedMorph(outA, outB, n);
}

/// `compute`-friendly entry point for Morton-rank pairing.
AlignedMorph buildMortonIsolate(CorrespondenceParams p) =>
    buildMortonAlignment(p.a, p.b);

/// `compute`-friendly entry point.
AlignedMorph buildCorrespondenceIsolate(CorrespondenceParams p) =>
    buildCorrespondence(
      p.a,
      p.b,
      spatialWeight: p.spatialWeight,
      colorWeight: p.colorWeight,
      distanceThreshold: p.distanceThreshold,
    );

/// Builds a greedy one-to-one correspondence between the splats of [a] and [b]
/// using a spatial hash grid, weighting squared position distance against
/// squared base-color distance (mirrors the open-source Gaussian-Splat-Morpher
/// 0.7/0.3 defaults). Unmatched splats are emitted with a zero-scale,
/// zero-opacity partner so the shader's plain `mix` makes them shrink+fade.
///
/// Output rows: every A splat (matched or vanishing) first, then every
/// unclaimed B splat (appearing).
AlignedMorph buildCorrespondence(
  Uint8List a,
  Uint8List b, {
  double spatialWeight = 0.7,
  double colorWeight = 0.3,
  double distanceThreshold = double.infinity,
}) {
  const stride = GsConst.bytesPerSplat;
  const fStride = stride ~/ 4;
  final na = a.length ~/ stride;
  final nb = b.length ~/ stride;
  final af = Float32List.view(a.buffer, a.offsetInBytes, a.length ~/ 4);
  final bf = Float32List.view(b.buffer, b.offsetInBytes, b.length ~/ 4);

  double px(Float32List f, int i) => f[i * fStride];
  double py(Float32List f, int i) => f[i * fStride + 1];
  double pz(Float32List f, int i) => f[i * fStride + 2];
  double cr(Uint8List buf, int i) =>
      buf[i * stride + GsConst.colorOffset] / 255;
  double cg(Uint8List buf, int i) =>
      buf[i * stride + GsConst.colorOffset + 1] / 255;
  double cb(Uint8List buf, int i) =>
      buf[i * stride + GsConst.colorOffset + 2] / 255;

  // --- bounds of B → grid cell size (~1 splat per cell) ---
  var minX = double.infinity;
  var minY = double.infinity;
  var minZ = double.infinity;
  var maxX = -double.infinity;
  var maxY = -double.infinity;
  var maxZ = -double.infinity;
  for (var i = 0; i < nb; i++) {
    final x = px(bf, i);
    final y = py(bf, i);
    final z = pz(bf, i);
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }
  final extent = math.max(maxX - minX, math.max(maxY - minY, maxZ - minZ));
  final cell =
      extent <= 0 ? 1.0 : extent / math.max(1, math.pow(nb, 1 / 3)).toDouble();
  int gx(double v) => (v - minX) ~/ cell;
  int gy(double v) => (v - minY) ~/ cell;
  int gz(double v) => (v - minZ) ~/ cell;
  int cellKey(int x, int y, int z) =>
      (x * 73856093) ^ (y * 19349663) ^ (z * 83492791);

  final grid = <int, List<int>>{};
  for (var i = 0; i < nb; i++) {
    grid
        .putIfAbsent(
          cellKey(gx(px(bf, i)), gy(py(bf, i)), gz(pz(bf, i))),
          () => <int>[],
        )
        .add(i);
  }

  final claimed = Uint8List(nb);
  final aToB = Int32List(na)..fillRange(0, na, -1);
  final thr2 = distanceThreshold * distanceThreshold;

  // Gather up to K best candidate B's per A splat (no claiming yet), then
  // assign globally-shortest pairs first. Distance-sorted greedy matching: it
  // approximates the optimal one-to-one (assignment-problem) result without the
  // O(n^3) Hungarian cost, and unlike iteration-order greedy it isn't biased by
  // which splat we happen to visit first.
  const k = 4;
  final cap = na * k;
  final candA = Int32List(cap);
  final candB = Int32List(cap);
  final candCost = Float32List(cap);
  final bestJ = Int32List(k);
  final bestC = Float64List(k);
  var pairCount = 0;

  for (var i = 0; i < na; i++) {
    final x = px(af, i);
    final y = py(af, i);
    final z = pz(af, i);
    final r = cr(a, i);
    final g = cg(a, i);
    final bl = cb(a, i);
    final cx = gx(x);
    final cy = gy(y);
    final cz = gz(z);
    for (var s = 0; s < k; s++) {
      bestJ[s] = -1;
      bestC[s] = double.infinity;
    }
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dz = -1; dz <= 1; dz++) {
          final bucket = grid[cellKey(cx + dx, cy + dy, cz + dz)];
          if (bucket == null) continue;
          for (final j in bucket) {
            final ddx = x - px(bf, j);
            final ddy = y - py(bf, j);
            final ddz = z - pz(bf, j);
            final sd = ddx * ddx + ddy * ddy + ddz * ddz;
            if (sd > thr2) continue;
            final dcr = r - cr(b, j);
            final dcg = g - cg(b, j);
            final dcb = bl - cb(b, j);
            final cd = dcr * dcr + dcg * dcg + dcb * dcb;
            final cost = spatialWeight * sd + colorWeight * cd;
            // Insertion into the ascending K-best list for this A splat.
            if (cost < bestC[k - 1]) {
              var s = k - 1;
              while (s > 0 && bestC[s - 1] > cost) {
                bestC[s] = bestC[s - 1];
                bestJ[s] = bestJ[s - 1];
                s--;
              }
              bestC[s] = cost;
              bestJ[s] = j;
            }
          }
        }
      }
    }
    for (var s = 0; s < k; s++) {
      if (bestJ[s] < 0) break;
      candA[pairCount] = i;
      candB[pairCount] = bestJ[s];
      candCost[pairCount] = bestC[s];
      pairCount++;
    }
  }

  // Assign the globally cheapest pairs first; skip any whose A or B is taken.
  final order = List<int>.generate(pairCount, (i) => i)
    ..sort((x, y) => candCost[x].compareTo(candCost[y]));
  final aMatched = Uint8List(na);
  for (final p in order) {
    final i = candA[p];
    final j = candB[p];
    if (aMatched[i] != 0 || claimed[j] != 0) continue;
    aMatched[i] = 1;
    claimed[j] = 1;
    aToB[i] = j;
  }

  var bOnly = 0;
  for (var j = 0; j < nb; j++) {
    if (claimed[j] == 0) bOnly++;
  }

  final n = na + bOnly;
  final outA = Uint8List(n * stride);
  final outB = Uint8List(n * stride);

  void copyRow(Uint8List dst, int di, Uint8List src, int si) =>
      dst.setRange(di * stride, di * stride + stride, src, si * stride);

  // Zero scale (12..23) and opacity (colorOffset+3) so the missing side
  // shrinks to nothing and is alpha-discarded at its endpoint.
  void zeroPresence(Uint8List buf, int i) {
    final f = Float32List.view(buf.buffer, buf.offsetInBytes, buf.length ~/ 4);
    final o = i * fStride;
    f[o + 3] = 0;
    f[o + 4] = 0;
    f[o + 5] = 0;
    buf[i * stride + GsConst.colorOffset + 3] = 0;
  }

  var row = 0;
  for (var i = 0; i < na; i++) {
    copyRow(outA, row, a, i);
    if (aToB[i] >= 0) {
      copyRow(outB, row, b, aToB[i]); // matched: real B
    } else {
      copyRow(outB, row, a, i); // vanish in place
      zeroPresence(outB, row);
    }
    row++;
  }
  for (var j = 0; j < nb; j++) {
    if (claimed[j] != 0) continue;
    copyRow(outB, row, b, j); // appear: real B
    copyRow(outA, row, b, j); // start collapsed at the B location
    zeroPresence(outA, row);
    row++;
  }

  return AlignedMorph(outA, outB, n);
}
