import 'package:flutter/material.dart';
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
      theme: ThemeData(
        brightness: Brightness.dark,
      ),
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

class _GaussianSplatterHomePageState extends State<GaussianSplatterHomePage> {
  bool _showStats = true;
  double _yaw = 0.0;
  double _pitch = 0.0;
  final GlobalKey<GaussianSplatterWidgetState> _splatterKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
              child: Container(
            color: Colors.green,
          )),
          GaussianSplatterWidget(
            highQualitySH:false,
            key: _splatterKey,
            assetPath: 'assets/toycar.ply',
            backgroundAssetPath: 'assets/sky.jpg',
            // showStats: _showStats,
            enableProfiling: false,
          ),
          // Background rotation controls
          Positioned(
            top: 50,
            right: 20,
            child: Container(
              width: 250,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Background Rotation',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Yaw: ${_yaw.toStringAsFixed(0)}°',
                    style: const TextStyle(color: Colors.white),
                  ),
                  Slider(
                    value: _yaw,
                    min: -180,
                    max: 180,
                    onChanged: (value) {
                      setState(() {
                        _yaw = value;
                      });
                      _splatterKey.currentState
                          ?.setBackgroundRotation(_yaw, _pitch);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pitch: ${_pitch.toStringAsFixed(0)}°',
                    style: const TextStyle(color: Colors.white),
                  ),
                  Slider(
                    value: _pitch,
                    min: -180,
                    max: 180,
                    onChanged: (value) {
                      setState(() {
                        _pitch = value;
                      });
                      _splatterKey.currentState
                          ?.setBackgroundRotation(_yaw, _pitch);
                    },
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _yaw = 0.0;
                        _pitch = 0.0;
                      });
                      _splatterKey.currentState
                          ?.setBackgroundRotation(_yaw, _pitch);
                    },
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _showStats = !_showStats;
          });
        },
        tooltip: 'Toggle Stats',
        child: Icon(_showStats ? Icons.visibility_off : Icons.visibility),
      ),
    );
  }
}
