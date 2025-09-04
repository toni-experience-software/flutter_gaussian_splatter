import 'dart:async';
import 'dart:developer';
import 'dart:io';
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
  /// Set [enableProfiling] to true to enable detailed performance profiling
  const GaussianSplatterWidget({
    required this.assetPath,
    this.backgroundAssetPath,
    super.key,
    this.showStats = false,
    this.enableProfiling = false,
  });

  /// Path to the asset containing the Gaussian splat data.
  final String assetPath;

  /// Whether to show the performance statistics overlay.
  final bool showStats;

  /// Whether to enable detailed performance profiling.
  /// When false (default), uses CPU-only profiling for optimal performance.
  /// When true, enables GPU timing if supported by the platform.
  final bool enableProfiling;

  /// Path to the asset containing the background image.
  final String? backgroundAssetPath;

  @override
  State<GaussianSplatterWidget> createState() => GaussianSplatterWidgetState();
}

class GaussianSplatterWidgetState extends State<GaussianSplatterWidget>
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
  bool isUpdating = false;
  late Ticker ticker;

  // Camera controls
  bool _isInteracting = false;
  double _orbitDistance = 1;
  double _theta = 0;
  double _phi = math.pi / 2;
  final vm.Vector3 _orbitOrigin = vm.Vector3(0, -0.1, 0); // center of the orbit

  // Stats
  String _statsText = '';

  bool get _didInit => texture != null;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    if (_didInit) {
      ticker.dispose();
      _renderer.dispose();
    }
    super.dispose();
  }

  Future<void> initPlatformState(Size validSize, double dpr) async {
    if (_didInit) return;

    if (validSize.width <= 0 || validSize.height <= 0) {
      debugPrint('Invalid size for initialization: $validSize');
      return;
    }

    debugPrint(
      'Initializing with size: ${validSize.width}x${validSize.height}',
    );

    final camera = GaussianCamera.createDefault(
      width: validSize.width,
      height: validSize.height,
    );

    // Initialize spherical coordinates from initial camera position
    final pos = camera.position;
    _orbitDistance = pos.length;
    _theta = math.atan2(pos.x, pos.z);
    _phi = math.acos(pos.y / _orbitDistance);

    try {
      await _renderer.initialize();
      _renderer.camera = camera;

      await _renderer.setupTexture(
        width: validSize.width,
        height: validSize.height,
        enableProfiling: widget.enableProfiling,
      );
      if (widget.backgroundAssetPath != null) {
        await _renderer.enableBackgroundFromAsset(widget.backgroundAssetPath!);
      }

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
        // Build performance info with proper context
        final perfInfo = StringBuffer()
          ..writeln('Performance [${stats.profilerType ?? 'Unknown'}]:')
          ..writeln(
            '  CPU: ${stats.fps.toStringAsFixed(1)} FPS (${stats.cpuFrameTimeMs?.toStringAsFixed(1) ?? '?'}ms)',
          );

        if (stats.hasGpuTiming && stats.gpuFps != null) {
          perfInfo.writeln(
            '  GPU: ${stats.gpuFps!.toStringAsFixed(1)} FPS (${stats.gpuFrameTimeMs!.toStringAsFixed(1)}ms)',
          );
        } else {
          perfInfo.writeln('  GPU: Timing unavailable');
        }

        _statsText = '''$perfInfo
Rendering:
  Gaussian Splats: ${stats.vertexCount}
  Viewport: ${camera.width} × ${camera.height}px
  
Camera:
  Position: (${pos.x.toStringAsFixed(2)}, ${pos.y.toStringAsFixed(2)}, ${pos.z.toStringAsFixed(2)})
  FOV: ${fovH.toStringAsFixed(1)}° × ${fovV.toStringAsFixed(1)}°
  Focal: fx=${camera.fx.toStringAsFixed(1)}, fy=${camera.fy.toStringAsFixed(1)}
  
Interaction: ${_isInteracting ? 'Active' : 'Idle'}''';
      });
    }
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _isInteracting = true;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (textureId < 0) return;

    if (details.scale != 1.0) {
      final zoomDelta = (details.scale - 1.0) * -_kZoomSensitivity;
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

  void _applyCameraFromSpherical() {
    final r = _orbitDistance;

    final rel = vm.Vector3(
      r * math.sin(_phi) * math.sin(_theta),
      r * math.cos(_phi),
      r * math.sin(_phi) * math.cos(_theta),
    );

    // Position is orbit-origin + relative spherical offset
    final pos = _orbitOrigin + rel;

    // Look at the orbit origin
    final forward = (_orbitOrigin - pos).normalized();
    final up = vm.Vector3(0, -1, 0); // your coordinate system
    final right = up.cross(forward).normalized();
    final trueUp = forward.cross(right).normalized();
    final rot = vm.Matrix3.columns(right, trueUp, forward);

    _renderer.camera = _renderer.camera?.copyWithPose(
      position: pos,
      rotation: rot,
    );
  }

  void _orbitCamera(double deltaX, double deltaY) {
    _theta -= deltaX;
    _phi = (_phi - deltaY).clamp(0.01, math.pi - 0.01);
    _applyCameraFromSpherical();
  }

  void _zoomCamera(double delta) {
    _orbitDistance =
        (_orbitDistance + delta).clamp(_kMinOrbitDistance, _kMaxOrbitDistance);
    _applyCameraFromSpherical();
  }

  Future<void> _handleResize(Size newSize) async {
    try {
      final camera = _renderer.camera?.copyWithViewport(
        newWidth: newSize.width,
        newHeight: newSize.height,
      );

      if (camera == null) {
        return;
      }

      await _renderer.resize(camera);

      // Update texture reference after successful resize
      texture = _renderer.targetTexture;
      textureId = texture!.textureId;
    } catch (e) {
      log('Resize failed: $e');
    }
  }

  /// Sets the background rotation for real-time testing
  void setBackgroundRotation(double yawDegrees, double pitchDegrees) {
    _renderer.setBackgroundRotation(yawDegrees, pitchDegrees);
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
          if (_didInit) ...[
            const SizedBox(height: 16),
            const Text('Texture creation failed. Try again?'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                setState(() {
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
        final currentSize = Size(constraints.maxWidth, constraints.maxHeight);
        final dpr = MediaQuery.of(context).devicePixelRatio;

        if (!_didInit &&
            currentSize.width > 0 &&
            currentSize.height > 0 &&
            mounted) {
          initPlatformState(currentSize, dpr);
        }

        if (textureId < 0) {
          return _buildLoadingState();
        }

        if (_renderer.currentSize != currentSize) {
          unawaited(_handleResize(currentSize));
        }

        return GestureDetector(
          onScaleStart: _handleScaleStart,
          onScaleUpdate: _handleScaleUpdate,
          onScaleEnd: _handleScaleEnd,
          child: Stack(
            children: [
              Transform.scale(
                scale: Platform.isAndroid ? 1 : -1,
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
