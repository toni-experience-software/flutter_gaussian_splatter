import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_gaussian_splatter/files/file_processor.dart';
import 'package:flutter_gaussian_splatter/widgets/gaussian_splatter_widget.dart';

void main() {
  runApp(const GaussianSplatterApp());
}

class GaussianSplatterApp extends StatelessWidget {
  const GaussianSplatterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gaussian Splatter Viewer',
      theme: ThemeData(brightness: Brightness.dark),
      home: const GaussianSplatterHomePage(),
    );
  }
}

class GaussianSplatterHomePage extends StatefulWidget {
  const GaussianSplatterHomePage({super.key});

  @override
  State<GaussianSplatterHomePage> createState() =>
      _GaussianSplatterHomePageState();
}

class _GaussianSplatterHomePageState extends State<GaussianSplatterHomePage>
    with SingleTickerProviderStateMixin {
  // The index-based morph cycles through these models in order and loops. Each
  // hop pairs splats A[i] <-> B[i] (no spatial matching), so a segment starts
  // the instant its buffers upload — no isolate, no long load. The largest
  // model leads: the rendered count stays max(countA, countB), never the sum,
  // so we never render two splat sets at once. The `assets/` glob in
  // pubspec.yaml bundles anything dropped in that folder.
  static const List<String> _models = [
    'assets/offroad512.ply', // 512000 splats
    'assets/wash512k.ply', // 511800
    'assets/export_100000.ply', // 164000
    'assets/toycar.ply', // 58946
  ];
  static String get _assetPath => _models.first;

  final GlobalKey<GaussianSplatterWidgetState> _splatterKey = GlobalKey();
  final FileProcessor _processor = FileProcessor();
  late final AnimationController _morph;

  List<Uint8List>? _processed; // processed + fitted buffer per model
  int _index = 0; // model currently fully displayed (segment destination)
  bool _building = false;
  bool _looping = false;
  bool _active = false; // a morph segment is set up (scrub/clear enabled)
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _morph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )
      ..addListener(() {
        _t = _morph.value;
        _splatterKey.currentState?.setMorphProgress(_t);
        setState(() {});
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && _looping) {
          _advance();
        }
      });
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  /// Loads + processes every model once, fitting each into the first model's
  /// bounding box so the whole cycle stays framed by the initial camera.
  Future<void> _ensureProcessed() async {
    if (_processed != null || _building) return;
    setState(() => _building = true);

    final raw = <Uint8List>[];
    for (final path in _models) {
      final bytes = (await services.rootBundle.load(path)).buffer.asUint8List();
      raw.add(
        _processor.isPly(bytes) ? _processor.processPlyBuffer(bytes) : bytes,
      );
    }
    final base = raw.first;
    final fitted = <Uint8List>[
      base,
      for (var i = 1; i < raw.length; i++) _fitToSource(base, raw[i]),
    ];

    if (!mounted) return;
    setState(() {
      _processed = fitted;
      _building = false;
    });
  }

  /// Morphs from the current model to the next one in the cycle (wrapping).
  /// Chaining is handled by the renderer: each `startMorph` begins from the
  /// previous segment's end-state.
  Future<void> _advance() async {
    final processed = _processed;
    if (processed == null) return;
    _index = (_index + 1) % processed.length;
    await _splatterKey.currentState?.startMorph(
      processed[_index],
      indexMatch: true,
    );
    if (!mounted) return;
    _active = true;
    await _morph.forward(from: 0);
  }

  /// Returns a copy of [b] translated + uniformly scaled so its body matches
  /// [a]'s, using robust 2–98 percentile bounds per axis so floaters (common in
  /// splat exports) don't blow up the fit. Floaters end up flung off-frame.
  Uint8List _fitToSource(Uint8List a, Uint8List b) {
    const stride = 128; // GsConst.bytesPerSplat

    // Returns [centerX,Y,Z, extentX,Y,Z] from the 2nd..98th percentile.
    List<double> robust(Uint8List buf) {
      final v = ByteData.view(buf.buffer);
      final n = buf.length ~/ stride;
      final center = List<double>.filled(3, 0);
      final extent = List<double>.filled(3, 0);
      for (var c = 0; c < 3; c++) {
        final vals = List<double>.generate(
          n,
          (i) => v.getFloat32(i * stride + c * 4, Endian.little),
        )..sort();
        final lo = vals[(n * 0.02).floor()];
        final hi = vals[(n * 0.98).floor()];
        center[c] = (lo + hi) * 0.5;
        extent[c] = hi - lo;
      }
      return [...center, ...extent];
    }

    final ra = robust(a);
    final rb = robust(b);
    final srcExtent = math.max(ra[3], math.max(ra[4], ra[5]));
    final tgtExtent = math.max(rb[3], math.max(rb[4], rb[5]));
    final scale = tgtExtent <= 0 ? 1.0 : srcExtent / tgtExtent;

    final out = Uint8List.fromList(b);
    final vo = ByteData.view(out.buffer);
    final n = out.length ~/ stride;
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < 3; c++) {
        final off = i * stride + c * 4;
        final p = vo.getFloat32(off, Endian.little);
        vo.setFloat32(off, (p - rb[c]) * scale + ra[c], Endian.little);
      }
      // Scale the splat's own size to match the new world scale.
      for (var c = 0; c < 3; c++) {
        final off = i * stride + 12 + c * 4;
        vo.setFloat32(
          off,
          vo.getFloat32(off, Endian.little) * scale,
          Endian.little,
        );
      }
    }
    return out;
  }

  Future<void> _play() async {
    await _ensureProcessed();
    if (!mounted) return;
    setState(() => _looping = true);
    await _advance();
  }

  void _pause() {
    _morph.stop();
    setState(() => _looping = false);
  }

  void _clear() {
    _morph.stop();
    _splatterKey.currentState?.clearMorph();
    setState(() {
      _looping = false;
      _active = false;
      _index = 0;
      _t = 0;
    });
  }

  String get _segmentLabel {
    final processed = _processed;
    if (processed == null) return 'Press Play to cycle ${_models.length} models';
    final from = _name(_models[(_index - 1 + processed.length) % processed.length]);
    final to = _name(_models[_index]);
    return '$from → $to   t=${_t.toStringAsFixed(2)}';
  }

  static String _name(String path) =>
      path.split('/').last.replaceAll('.ply', '');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          GaussianSplatterWidget(
            highQualitySH: false,
            key: _splatterKey,
            assetPath: _assetPath,
            backgroundAssetPath: 'assets/sky.jpg',
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _segmentLabel,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: _t,
                          onChanged: (_active && !_looping)
                              ? (v) {
                                  setState(() => _t = v);
                                  _splatterKey.currentState
                                      ?.setMorphProgress(v);
                                }
                              : null,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      FilledButton.icon(
                        onPressed: _building || _looping ? null : _play,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                      ),
                      FilledButton.icon(
                        onPressed: _looping ? _pause : null,
                        icon: const Icon(Icons.pause),
                        label: const Text('Pause'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _active ? _clear : null,
                        icon: const Icon(Icons.close),
                        label: const Text('Clear'),
                      ),
                    ],
                  ),
                  if (_building)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Loading models…',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
