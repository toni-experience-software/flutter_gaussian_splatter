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
  State<GaussianSplatterHomePage> createState() => _GaussianSplatterHomePageState();
}

class _GaussianSplatterHomePageState extends State<GaussianSplatterHomePage> {
  bool _showStats = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GaussianSplatterWidget(
        assetPath: 'assets/toycar.ply',
        showStats: _showStats,
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
