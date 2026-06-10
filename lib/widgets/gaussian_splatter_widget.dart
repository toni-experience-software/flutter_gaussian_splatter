import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as flutter_services;
import 'package:flutter_gaussian_splatter/camera/camera.dart';
import 'package:flutter_gaussian_splatter/files/file_processor.dart';
import 'package:flutter_gaussian_splatter/renderer/backend_selector.dart';
import 'package:flutter_gaussian_splatter/renderer/splat_renderer.dart';
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
  /// Set [disableAlphaWrite] to true to optimize bandwidth by disabling alpha
  /// writes
  const GaussianSplatterWidget({
    required this.assetPath,
    this.backgroundAssetPath,
    super.key,
    this.showStats = false,
    this.enableProfiling = false,
    this.disableAlphaWrite = true,
    this.backend = SplatBackend.auto,
  });

  /// Path to the asset containing the Gaussian splat data.
  final String assetPath;

  /// Whether to show the performance statistics overlay.
  final bool showStats;

  /// Whether to enable detailed performance profiling.
  /// When false (default), uses CPU-only profiling for optimal performance.
  /// When true, enables GPU timing if supported by the platform.
  final bool enableProfiling;

  /// Whether to disable alpha channel writes for bandwidth optimization.
  /// Only disable if nothing downstream samples the framebuffer's alpha
  /// channel.
  final bool disableAlphaWrite;

  /// Path to the asset containing the background image.
  final String? backgroundAssetPath;

  /// Rendering backend to use.
  final SplatBackend backend;

  @override
  State<GaussianSplatterWidget> createState() => GaussianSplatterWidgetState();
}

/// State for [GaussianSplatterWidget] managing rendering and user interaction.
class GaussianSplatterWidgetState extends State<GaussianSplatterWidget> {
  // Constants
  static const double _kZoomSensitivity = 0.1;
  static const double _kPanSensitivity = 5;
  static const double _kMinOrbitDistance = 0.1;
  static const double _kMaxOrbitDistance = 100;

  // Core components
  late SplatRenderer _renderer;
  final FileProcessor _fileProcessor = FileProcessor();
  bool _isReady = false;
  bool _initStarted = false;
  Object? _initError;
  Size? _logicalSize;
  double _lastDpr = 1;

  // Camera controls
  bool _isInteracting = false;
  double _orbitDistance = 1;
  double _theta = 0;
  double _phi = math.pi / 2;
  final vm.Vector3 _orbitOrigin = vm.Vector3(0, -0.1, 0); // center of the orbit

  // Stats
  String _statsText = '';

  bool get _didInit => _renderer.camera != null;

  bool _frameScheduled = false;
  bool _frameInFlight = false;

  @override
  void initState() {
    super.initState();
    _renderer = _createRenderer();
  }

  SplatRenderer _createRenderer() {
    return createRenderer(
      widget.backend,
      disableAlphaWrite: widget.disableAlphaWrite,
    );
  }

  void _resetRendererForRetry() {
    if (_didInit) {
      try {
        _renderer.dispose();
      } catch (_) {}
    }
    _renderer = _createRenderer();
    _isReady = false;
    _initStarted = false;
    _initError = null;
    _logicalSize = null;
  }

  void _requestRender() {
    if (_frameScheduled) return;
    _frameScheduled = true;

    WidgetsBinding.instance.scheduleFrameCallback((_) async {
      _frameScheduled = false;
      if (!mounted || _frameInFlight || !_isReady) return;

      _frameInFlight = true;
      try {
        await _renderer.frame();

        if (mounted && widget.showStats) {
          _updateStats();
        }
      } finally {
        _frameInFlight = false;
      }
    });
  }

  @override
  void dispose() {
    if (_didInit) {
      _renderer.dispose();
    }
    super.dispose();
  }

  /// Initializes the renderer with the given viewport size and device pixel
  /// ratio.
  Future<void> initPlatformState(Size validSize, double dpr) async {
    if (_initStarted || _didInit) return;
    _initStarted = true;
    _initError = null;

    if (validSize.width <= 0 || validSize.height <= 0) {
      debugPrint('Invalid size for initialization: $validSize');
      _initStarted = false;
      return;
    }

    debugPrint(
      'Initializing with size: ${validSize.width}x${validSize.height} @ $dpr',
    );

    _logicalSize = _snap(validSize);
    _lastDpr = dpr;
    final renderSize = _physicalSize(validSize, dpr);
    final camera = Camera.createDefault(
      width: renderSize.width,
      height: renderSize.height,
      ndcYSign: Platform.isAndroid ? 1 : -1,
    );

    // Initialize spherical coordinates from initial camera position
    final pos = camera.position;
    _orbitDistance = pos.length;
    _theta = math.atan2(pos.x, pos.z);
    _phi = math.acos(pos.y / _orbitDistance);

    try {
      await _renderer.initialize();

      await _renderer.setup(
        width: renderSize.width.toInt(),
        height: renderSize.height.toInt(),
        enableProfiling: widget.enableProfiling,
      );

      _renderer.camera = camera;
      if (widget.backgroundAssetPath != null) {
        await _renderer.enableBackgroundFromAsset(widget.backgroundAssetPath!);
      }

      await _loadSplatDataFromAsset(widget.assetPath);

      if (!mounted) return;
      setState(() {
        _isReady = true;
      });

      // Initial render after setup
      _requestRender();
    } catch (e) {
      debugPrint('Failed to initialize renderer: $e');
      if (!mounted) return;
      setState(() {
        _isReady = false;
        _initError = e;
      });
    }
  }

  Future<void> _loadSplatDataFromAsset(String assetPath) async {
    final byteData = await flutter_services.rootBundle.load(assetPath);
    final bytes = Uint8List.fromList(byteData.buffer.asUint8List());

    final processedData = _fileProcessor.isPly(bytes)
        ? _fileProcessor.processPlyBuffer(bytes)
        : bytes;

    await _renderer.setSplatData(processedData);
    _requestRender();
  }

  void _updateStats() {
    if (!mounted || !widget.showStats) return;

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
            '  CPU: ${stats.fps.toStringAsFixed(1)} FPS'
            ' (${stats.cpuFrameTimeMs?.toStringAsFixed(1) ?? '?'}ms)',
          );

        if (stats.hasGpuTiming && stats.gpuFps != null) {
          perfInfo.writeln(
            '  GPU: ${stats.gpuFps!.toStringAsFixed(1)} '
            ' FPS (${stats.gpuFrameTimeMs!.toStringAsFixed(1)}ms)',
          );
        } else {
          perfInfo.writeln('  GPU: Timing unavailable');
        }

        _statsText = '''
$perfInfo
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
    if (!_isReady) return;

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

    _requestRender();
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

  Future<void> _handleResize(Size newSize, double dpr) async {
    final logicalSize = _snap(newSize);
    final renderSize = _physicalSize(logicalSize, dpr);
    final current = _renderer.camera;
    if (current != null &&
        current.width == renderSize.width.toInt() &&
        current.height == renderSize.height.toInt()) {
      _logicalSize = logicalSize;
      _lastDpr = dpr;
      return;
    }

    final camera = current?.copyWithViewport(
      newWidth: renderSize.width,
      newHeight: renderSize.height,
    );
    if (camera == null) return;

    final changed = await _renderer.resize(camera);
    if (!changed) return;

    _logicalSize = logicalSize;
    _lastDpr = dpr;
    _requestRender();
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
    final error = _initError;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Failed to initialize Gaussian Splatter.'),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                setState(_resetRendererForRetry);
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Initializing Gaussian Splatter...'),
        ],
      ),
    );
  }

  Size _snap(Size s) => Size(s.width.roundToDouble(), s.height.roundToDouble());

  Size _physicalSize(Size logicalSize, double dpr) {
    return Size(
      (logicalSize.width * dpr).roundToDouble(),
      (logicalSize.height * dpr).roundToDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.of(context).devicePixelRatio;

        // Snap once and use everywhere below
        final size = _snap(Size(constraints.maxWidth, constraints.maxHeight));

        if (!_initStarted &&
            _initError == null &&
            size.width > 0 &&
            size.height > 0 &&
            mounted) {
          initPlatformState(size, dpr); // pass snapped size
        }

        if (!_isReady) return _buildLoadingState();

        // Only resize when snapped size actually changed
        if (_logicalSize != size || _lastDpr != dpr) {
          unawaited(_handleResize(size, dpr));
        }

        return GestureDetector(
          onScaleStart: _handleScaleStart,
          onScaleUpdate: _handleScaleUpdate,
          onScaleEnd: _handleScaleEnd,
          child: Stack(
            children: [
              _renderer.buildOutput(context, logicalSize: size),
              if (widget.showStats) _buildStatsOverlay(),
            ],
          ),
        );
      },
    );
  }
}
