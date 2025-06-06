import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' as flutter_services;
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/camera.dart';
import 'package:flutter_gaussian_splatter/core/file_processor.dart';
import 'package:flutter_gaussian_splatter/core/texture_renderer.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// A widget that renders Gaussian splat data using WebGL/ANGLE.
///
/// This widget provides interactive camera controls for orbiting and zooming
/// around the 3D scene. The splat data is loaded from the provided asset path.
class GaussianSplatterWidget extends StatefulWidget {
  /// Creates a Gaussian splatter widget.
  ///
  /// The [assetPath] must point to a valid .ply file or processed splat data.
  /// Set [showStats] to true to display rendering statistics overlay.
  const GaussianSplatterWidget({
    required this.assetPath,
    super.key,
    this.showStats = false,
  });

  /// Path to the asset containing the Gaussian splat data.
  final String assetPath;

  /// Whether to show the performance statistics overlay.
  final bool showStats;

  @override
  State<GaussianSplatterWidget> createState() => _GaussianSplatterWidgetState();
}

class _GaussianSplatterWidgetState extends State<GaussianSplatterWidget>
    with SingleTickerProviderStateMixin {
  // Constants
  static const double _kZoomSensitivity = 0.1;
  static const double _kPanSensitivity = 5;
  static const double _kMinOrbitDistance = 0.1;
  static const double _kMaxOrbitDistance = 100;
  static const int _kInvalidTextureId = -1;

  // Core components
  final TextureGaussianRenderer _renderer = TextureGaussianRenderer();
  final FileProcessorImpl _fileProcessor = FileProcessorImpl();

  // State management
  FlutterAngleTexture? texture;
  int textureId = _kInvalidTextureId;
  bool didInit = false;
  bool isUpdating = false;
  late Ticker ticker;
  late GaussianCamera _camera;

  // Camera controls
  bool _isInteracting = false;
  double _orbitDistance = 1;
  double _theta = 0;
  double _phi = math.pi / 2;

  // Stats
  String _statsText = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    if (didInit) {
      ticker.dispose();
      _renderer.dispose();
    }
    super.dispose();
  }

  Future<void> initPlatformState(Size validSize) async {
    if (didInit) return;
    didInit = true;

    if (validSize.width <= 0 || validSize.height <= 0) {
      debugPrint('Invalid size for initialization: $validSize');
      didInit = false;
      return;
    }

    debugPrint(
      'Initializing with size: ${validSize.width}x${validSize.height}',
    );

    _camera = GaussianCamera.createDefault(
      width: validSize.width,
      height: validSize.height,
      position: vm.Vector3(0, 0, -1),
      rotation: vm.Matrix3.identity(),
    );

    // Initialize spherical coordinates from initial camera position
    final pos = _camera.position;
    _orbitDistance = pos.length;
    _theta = math.atan2(pos.x, pos.z);
    _phi = math.acos(pos.y / _orbitDistance);

    try {
      await _renderer.initialize();
      _renderer.setCamera(_camera);

      final vertexShaderCode = await flutter_services.rootBundle.loadString(
        'packages/flutter_gaussian_splatter/shaders/vertex.glsl',
      );
      final fragmentShaderCode = await flutter_services.rootBundle.loadString(
        'packages/flutter_gaussian_splatter/shaders/frag.glsl',
      );

      await _renderer.setupTexture(
        width: validSize.width,
        height: validSize.height,
        vertexShaderCode: vertexShaderCode,
        fragmentShaderCode: fragmentShaderCode,
      );

      texture = _renderer.targetTexture;

      if (texture == null) {
        throw Exception('Failed to create texture: texture is null');
      }

      textureId = texture!.textureId;

      if (textureId < 0) {
        throw Exception(
          'Failed to create texture: invalid texture ID ($textureId)',
        );
      }

      debugPrint('Successfully created texture with ID: $textureId');

      await _loadSplatDataFromAsset(widget.assetPath);
      _renderer.startRenderLoop();

      if (!mounted) return;
      setState(() {});

      ticker = createTicker(_updateTexture);
      unawaited(ticker.start());
    } catch (e) {
      debugPrint('Failed to initialize renderer: $e');
      didInit = false;
      rethrow;
    }
  }

  Future<void> _loadSplatDataFromAsset(String assetPath) async {
    final byteData = await flutter_services.rootBundle.load(assetPath);
    final bytes = Uint8List.fromList(byteData.buffer.asUint8List());

    final processedData = _fileProcessor.isPly(bytes)
        ? _fileProcessor.processPlyBuffer(bytes)
        : bytes;

    _renderer.setSplatData(processedData);
  }

  Future<void> _updateTexture(Duration elapsed) async {
    if (textureId < 0 || isUpdating) return;

    isUpdating = true;
    try {
      texture!.activate();
      await _renderer.frame();

      if (widget.showStats) {
        _updateStats();
      }

      await texture!.signalNewFrameAvailable();
    } catch (e) {
      debugPrint("Error updating texture: $e");
    } finally {
      isUpdating = false;
    }
  }

  void _updateStats() {
    if (!widget.showStats) return;

    final stats = _renderer.renderStats;
    final camera = _renderer.camera;

    if (camera != null) {
      final pos = camera.position;
      final fovH = camera.horizontalFovDegrees;
      final fovV = camera.verticalFovDegrees;

      setState(() {
        _statsText = '''
FPS: ${stats.fps.toStringAsFixed(1)}
Vertices: ${stats.vertexCount}
Camera Position: (${pos.x.toStringAsFixed(2)}, ${pos.y.toStringAsFixed(2)}, ${pos.z.toStringAsFixed(2)})
FOV: ${fovH.toStringAsFixed(1)}° × ${fovV.toStringAsFixed(1)}°
Viewport: ${camera.width} × ${camera.height}
Focal Length: fx=${camera.fx.toStringAsFixed(1)}, fy=${camera.fy.toStringAsFixed(1)}
Interacting: ${_isInteracting ? 'Yes' : 'No'}''';
      });
    }
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _isInteracting = true;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (textureId < 0) return;

    if (details.scale != 1.0) {
      final zoomDelta = (details.scale - 1.0) * _kZoomSensitivity;
      _zoomCamera(zoomDelta);
    }

    if (details.focalPointDelta != Offset.zero) {
      final size = context.size ?? Size.zero;
      final normalizedDx =
          (_kPanSensitivity * details.focalPointDelta.dx) / size.width;
      final normalizedDy =
          (_kPanSensitivity * details.focalPointDelta.dy) / size.height;
      _orbitCamera(normalizedDx, normalizedDy);
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _isInteracting = false;
  }

  void _orbitCamera(double deltaX, double deltaY) {
    _theta -= deltaX;
    _phi = (_phi - deltaY).clamp(0.01, math.pi - 0.01);

    final r = _orbitDistance;
    final newX = r * math.sin(_phi) * math.sin(_theta);
    final newY = r * math.cos(_phi);
    final newZ = r * math.sin(_phi) * math.cos(_theta);
    final newPosition = vm.Vector3(newX, newY, newZ);

    final forward = (-newPosition).normalized();
    final up = vm.Vector3(0, 1, 0);
    final right = up.cross(forward).normalized();
    final trueUp = forward.cross(right).normalized();
    final newRotation = vm.Matrix3.columns(right, trueUp, forward);

    _camera = _camera.copyWith(position: newPosition, rotation: newRotation);
    _renderer.setCamera(_camera);
  }

  void _zoomCamera(double delta) {
    _orbitDistance =
        (_orbitDistance + delta).clamp(_kMinOrbitDistance, _kMaxOrbitDistance);

    final r = _orbitDistance;
    final newX = r * math.sin(_phi) * math.sin(_theta);
    final newY = r * math.cos(_phi);
    final newZ = r * math.sin(_phi) * math.cos(_theta);
    final newPosition = vm.Vector3(newX, newY, newZ);

    final forward = (-newPosition).normalized();
    final up = vm.Vector3(0, 1, 0);
    final right = up.cross(forward).normalized();
    final trueUp = forward.cross(right).normalized();
    final newRotation = vm.Matrix3.columns(right, trueUp, forward);

    _camera = _camera.copyWith(position: newPosition, rotation: newRotation);
    _renderer.setCamera(_camera);
  }

  Widget _buildStatsOverlay() {
    return Positioned(
      top: 16,
      left: 16,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _statsText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Initializing Gaussian Splatter...'),
          if (didInit) ...[
            const SizedBox(height: 16),
            const Text('Texture creation failed. Try again?'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  didInit = false;
                  textureId = _kInvalidTextureId;
                });
              },
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        if (!didInit && size.width > 0 && size.height > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !didInit) {
              initPlatformState(size);
            }
          });
        }

        if (textureId < 0) {
          return _buildLoadingState();
        }

        return GestureDetector(
          onScaleStart: _handleScaleStart,
          onScaleUpdate: _handleScaleUpdate,
          onScaleEnd: _handleScaleEnd,
          child: Stack(
            children: [
              Transform.scale(
                scale: -1,
                child: Texture(textureId: textureId),
              ),
              if (widget.showStats) _buildStatsOverlay(),
            ],
          ),
        );
      },
    );
  }
}
