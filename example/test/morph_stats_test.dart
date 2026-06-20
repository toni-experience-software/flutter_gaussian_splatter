// Diagnostic: measures how much of the toycar->export morph is actual motion
// vs. pure fade-in/out, to explain why the transition reads as a dissolve.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gaussian_splatter/constants.dart';
import 'package:flutter_gaussian_splatter/files/file_processor.dart';
import 'package:flutter_gaussian_splatter/morph/correspondence.dart';
import 'package:flutter_test/flutter_test.dart';

const _stride = GsConst.bytesPerSplat;

List<double> _bbox(Uint8List buf) {
  final v = ByteData.view(buf.buffer);
  final n = buf.length ~/ _stride;
  final lo = List<double>.filled(3, double.infinity);
  final hi = List<double>.filled(3, -double.infinity);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < 3; c++) {
      final p = v.getFloat32(i * _stride + c * 4, Endian.little);
      if (p < lo[c]) lo[c] = p;
      if (p > hi[c]) hi[c] = p;
    }
  }
  return [...lo, ...hi];
}

// Robust 2-98 percentile fit, matching example/lib/main.dart's _fitToSource.
List<double> _robust(Uint8List buf) {
  final v = ByteData.view(buf.buffer);
  final n = buf.length ~/ _stride;
  final center = List<double>.filled(3, 0);
  final extent = List<double>.filled(3, 0);
  for (var c = 0; c < 3; c++) {
    final vals = List<double>.generate(
        n, (i) => v.getFloat32(i * _stride + c * 4, Endian.little))
      ..sort();
    final lo = vals[(n * 0.02).floor()];
    final hi = vals[(n * 0.98).floor()];
    center[c] = (lo + hi) * 0.5;
    extent[c] = hi - lo;
  }
  return [...center, ...extent];
}

Uint8List _fitToSource(Uint8List a, Uint8List b) {
  final ra = _robust(a);
  final rb = _robust(b);
  final srcExtent = math.max(ra[3], math.max(ra[4], ra[5]));
  final tgtExtent = math.max(rb[3], math.max(rb[4], rb[5]));
  final scale = tgtExtent <= 0 ? 1.0 : srcExtent / tgtExtent;
  final out = Uint8List.fromList(b);
  final vo = ByteData.view(out.buffer);
  final n = out.length ~/ _stride;
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < 3; c++) {
      final off = i * _stride + c * 4;
      vo.setFloat32(off, (vo.getFloat32(off, Endian.little) - rb[c]) * scale +
          ra[c], Endian.little);
    }
  }
  return out;
}

void main() {
  test('morph motion vs fade breakdown', () {
    final processor = FileProcessor();
    final a = processor.processPlyBuffer(
        File('assets/offroad512.ply').readAsBytesSync());
    final bRaw = processor.processPlyBuffer(
        File('assets/wash512k.ply').readAsBytesSync());
    final b = _fitToSource(a, bRaw);

    final na = a.length ~/ _stride;
    final nb = b.length ~/ _stride;

    // Detect floaters: full extent vs robust (2nd..98th percentile) extent.
    List<double> robustExtent(Uint8List buf) {
      final v = ByteData.view(buf.buffer);
      final n = buf.length ~/ _stride;
      final res = <double>[];
      for (var c = 0; c < 3; c++) {
        final vals = List<double>.generate(
            n, (i) => v.getFloat32(i * _stride + c * 4, Endian.little))
          ..sort();
        res.add(vals[(n * 0.98).floor()] - vals[(n * 0.02).floor()]);
      }
      return res;
    }

    final rawBox = _bbox(bRaw);
    final rawFull = [
      rawBox[3] - rawBox[0],
      rawBox[4] - rawBox[1],
      rawBox[5] - rawBox[2],
    ];
    final rawRobust = robustExtent(bRaw);
    // ignore: avoid_print
    print('target full extent  : ${rawFull.map((e) => e.toStringAsFixed(2))}');
    // ignore: avoid_print
    print('target 2-98% extent : '
        '${rawRobust.map((e) => e.toStringAsFixed(2))}  <- floaters if << full');

    final m = buildMortonAlignment(a, b);

    final va = ByteData.view(m.bufferA.buffer);
    final vb = ByteData.view(m.bufferB.buffer);
    final srcBox = _bbox(a);
    final diag = math.sqrt(math.pow(srcBox[3] - srcBox[0], 2) +
        math.pow(srcBox[4] - srcBox[1], 2) +
        math.pow(srcBox[5] - srcBox[2], 2));

    var fade = 0;
    var moved = 0;
    var sumDist = 0.0;
    var maxDist = 0.0;
    for (var i = 0; i < m.count; i++) {
      var d2 = 0.0;
      for (var c = 0; c < 3; c++) {
        final pa = va.getFloat32(i * _stride + c * 4, Endian.little);
        final pb = vb.getFloat32(i * _stride + c * 4, Endian.little);
        d2 += (pb - pa) * (pb - pa);
      }
      final d = math.sqrt(d2);
      if (d < 1e-6) {
        fade++;
      } else {
        moved++;
        sumDist += d;
        if (d > maxDist) maxDist = d;
      }
    }

    final pct = (num x) => (100 * x / m.count).toStringAsFixed(1);
    // ignore: avoid_print
    print('''
=== morph stats (toycar -> export_100000, fitted) ===
source splats (A) : $na
target splats (B) : $nb
aligned entries   : ${m.count}
pure fade (no motion): $fade  (${pct(fade)}%)   <- vanish + appear
actually moving      : $moved  (${pct(moved)}%)
avg flight distance  : ${moved == 0 ? 0 : (sumDist / moved).toStringAsFixed(4)}
max flight distance  : ${maxDist.toStringAsFixed(4)}
scene diagonal       : ${diag.toStringAsFixed(4)}
avg flight / diagonal: ${moved == 0 ? 0 : (sumDist / moved / diag).toStringAsFixed(3)}
''');
    expect(m.count, greaterThan(0));
  });
}
