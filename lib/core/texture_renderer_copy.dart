import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/background/background_skydome.dart';
import 'package:flutter_gaussian_splatter/core/camera.dart';
import 'package:flutter_gaussian_splatter/core/constants.dart';
import 'package:flutter_gaussian_splatter/core/perf/disjoint_query_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/glfinish_sampler_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/perf_profiler.dart';
import 'package:flutter_gaussian_splatter/core/perf/render_stats.dart';
import 'package:flutter_gaussian_splatter/data/order_texture.dart';
import 'package:flutter_gaussian_splatter/data/splat_source.dart';
import 'package:flutter_gaussian_splatter/passes/splat_draw_pass.dart';
import 'package:flutter_gaussian_splatter/sorting/depth_sorter.dart' as depth;
import 'package:vector_math/vector_math.dart';

/// Signature for callbacks delivered by [TextureGaussianRenderer].
typedef RendererCallback = void Function();

/// Sort completion callback signature.
typedef SortCompleteCallback = void Function(List<int> order, int total);

/// Wrapper around DepthSorterImpl that provides the expected callback interface.
///
/// This class adapts the DepthSorterImpl callback interface to match 
/// what the
/// TextureGaussianRenderer expects, converting SortResult to separate order
/// list and count parameters.
class SortScheduler {
  /// Creates a SortScheduler with the given completion callback.
  SortScheduler({required this.onSorted});

  /// Callback invoked when depth sorting completes.
  final SortCompleteCallback onSorted;
  
  late final depth.DepthSorterImpl _sorter = depth.DepthSorterImpl(
    onSortComplete: (result) {
      onSorted(result.depthIndex.toList(), result.vertexCount);
    },
  );

  /// Initializes the underlying depth sorter.
  Future<void> initialize() => _sorter.initialize();
  
  /// Disposes the underlying depth sorter.
  void dispose() => _sorter.dispose();

  /// Requests immediate depth sorting without throttling.
  void requestImmediate(
    Matrix4 viewProjection, 
    Uint8List buffer, 
    int splatCount,
  ) {
    _sorter.runSort(viewProjection, buffer, splatCount);
  }

  /// Requests depth sorting with frame-based throttling.
  void maybeRequestSort(
    Matrix4 viewProjection, 
    Uint8List buffer, 
    int splatCount,
  ) {
    _sorter.throttledSort(viewProjection, buffer, splatCount);
  }
}

/// Renders Gaussian splats into an in‑memory [FlutterAngleTexture].
///
/// This class encapsulates the full WebGL / ANGLE pipeline required by Gaussian
/// Splatting.  Life‑cycle:
/// ```dart
/// final renderer = TextureGaussianRenderer();
/// await renderer.initialize();
/// await renderer.setupTexture(width: 800, height: 600, vertexShaderCode: vs,
/// fragmentShaderCode: fs);
/// renderer.createAndSetDefaultCamera();
/// renderer.setSplatData(myBinarySplatBuffer);
/// renderer.startRenderLoop();
/// // drive [frame] from a SchedulerBinding / Ticker.
/// ```
///
/// All public APIs are `@mustCallSuper` lifecycle‑aware.
class TextureGaussianRenderer {
  // Dependencies & context
  late final FlutterAngle _angle;
  late FlutterAngleTexture _targetTexture;
  late RenderingContext _gl;

  // New service-based architecture
  late final SplatSource _splatSource = SplatSource();
  late final OrderTexture _orderTexSvc = OrderTexture();
  late final SortScheduler _sort = SortScheduler(
    onSorted: (order, total) {
      _orderTexSvc.uploadFull(_gl, order);
      // Update instancing count in the pass when order changes:
      _splatPass.onSourceChanged();
      _vertexCount = (total + GsConst.splatsPerInstance - 1) ~/ 
          GsConst.splatsPerInstance;
    },
  );
  late final SplatDrawPass _splatPass = SplatDrawPass(
    source: _splatSource,
    order: _orderTexSvc,
    disableAlphaWrite: _disableAlphaWrite,
  );



  //Background
  SkydomeBackground? _bg;
  String? _bgAssetPath; // for reload after context loss

  // Performance profiling
  PerfProfiler? _perf;

  // Render state & matrices
  var _viewMatrix = Matrix4.identity();
  var _projectionMatrix = Matrix4.identity();
  GaussianCamera? _camera;

  // Splat data & vertices
  int _vertexCount = 0;
  Uint8List? _splatBuffer;
  int _splatCount = 0;

  // Timing & FPS
  bool _isRendering = false;
  bool _inFrame = false;
  DateTime _lastFrameTime = DateTime.timestamp();
  double _fps = 0;
  double? _cpuFrameTimeMs;
  double? _gpuFrameTimeMs;
  String? _profilerType;
  bool _isResizing = false;

  // Optimization settings
  bool _disableAlphaWrite = true;

  // Public API

  /// Latest frame statistics with detailed performance profiling.
  RenderStats get renderStats => RenderStats(
        fps: _fps,
        vertexCount: _vertexCount,
        lastFrameTime: _lastFrameTime,
        cpuFrameTimeMs: _cpuFrameTimeMs,
        gpuFrameTimeMs: _gpuFrameTimeMs,
        profilerType: _profilerType,
      );

  /// The texture that can be composed into UI using [FlutterAngleTexture]
  /// widget helpers.
  FlutterAngleTexture get targetTexture => _targetTexture;

  /// Current viewport size that the renderer is configured for.
  Size? get currentSize => _camera == null
      ? null
      : Size(
          _camera!.width.toDouble(), 
          _camera!.height.toDouble(),
        );

  /// The currently active [GaussianCamera], or `null` if not set.
  GaussianCamera? get camera => _camera;

  /// Sets the active [GaussianCamera] and updates matrices.
  set camera(GaussianCamera? camera) {
    if (camera == _camera) return;
    _camera = camera;
    _updateViewMatrix();
    _updateProjectionMatrix();
  }

  /// Enables the background using an asset image.
  Future<void> enableBackgroundFromAsset(String assetPath) async {
    _bg ??= SkydomeBackground(assetPath: assetPath);
    await _bg!.init(_gl);
    _bg?.setYawPitchDegrees(90, 0); // pitch only → flips sky/ground
    _bgAssetPath = assetPath;
  }

  /// Disables the background.
  void disableBackground() {
    _bg?.dispose(_gl);
    _bg = null;
    _bgAssetPath = null;
  }

  /// Sets the background rotation in degrees.
  void setBackgroundRotation(double yawDegrees, double pitchDegrees) {
    _bg?.setYawPitchDegrees(yawDegrees, pitchDegrees);
  }

  /// Enables/disables alpha channel writes for bandwidth optimization.
  /// Only disable if nothing downstream samples the framebuffer's alpha channel.
  void setDisableAlphaWrite({required bool disable}) {
    _disableAlphaWrite = disable;
    // Note: This requires recreating the SplatDrawPass since 
    // disableAlphaWrite is immutable. For dynamic updates, we'd need 
    // to make this mutable in SplatDrawPass
  }

  // Life‑cycle

  /// Initializes ANGLE and the depth‑sorter. Must be called before any other
  /// method.
  Future<void> initialize({bool debug = true}) async {
    _angle = FlutterAngle();
    await _angle.init(debug);

    await _sort.initialize(); // replaces _depthSorter.initialize()
  }

  /// Creates a texture and compiles the shaders.  Safe to call multiple times –
  /// resources are recreated if needed.
  Future<void> setupTexture({
    required double width,
    required double height,
    bool enableProfiling = false,
  }) async {
    assert(width > 0 && height > 0, 'Viewport must be non‑zero');

    _targetTexture = await _angle.createTexture(
      AngleOptions(
        width: width.toInt(),
        height: height.toInt(),
        dpr: 1, // TODO(jesper): support dpr?
        alpha: true,
        useSurfaceProducer: true,
      ),
    );

    _gl = _targetTexture.getContext();
    await _splatPass.init(_gl);
    _updateProjectionMatrix();

    if (enableProfiling) {
      _perf = PerfProfiler.auto(_gl);

      // Determine profiler type for display
      if (_perf is DisjointQueryGpuProfiler) {
        _profilerType = 'GPU';
      } else if (_perf is GlFinishSamplerProfiler) {
        _profilerType = 'Sampled';
      } else {
        _profilerType = 'CPU';
      }
    } else {
      _perf = null;
      _profilerType = null;
    }
  }

  /// Starts the internal render loop. Idempotent.
  void startRenderLoop() => _isRendering = true;

  /// Stops the internal render loop. Idempotent.
  void stopRenderLoop() => _isRendering = false;

  /// Drives a single frame.  Call from a `Ticker` / `SchedulerBinding`.
  Future<void> frame() async {
    // Bail during resize/context swap
    // Reentrancy guard
    if (!_isRendering || _isResizing || _inFrame) return;

    // Guard readiness up front
    if (_camera == null) return;

    _inFrame = true;
    try {
      _perf?.beginFrame();

      // Sorting trigger + drawing
      if (_splatBuffer != null && _splatCount > 0) {
        final vp = _projectionMatrix.multiplied(_viewMatrix);
        _sort.maybeRequestSort(vp, _splatBuffer!, _splatCount);
      }

      _perf?.markGpuBegin(_gl);
      
      _gl
        ..viewport(0, 0, _camera!.width, _camera!.height)
        ..clearColor(0, 0, 0, 0)
        ..clear(WebGL.COLOR_BUFFER_BIT | WebGL.DEPTH_BUFFER_BIT)
        ..disable(WebGL.DEPTH_TEST)
        ..disable(WebGL.BLEND); // no blend for skydome

      if (_bg?.isReady ?? false) {
        _bg!.execute(_gl, _camera!); // your Skydome pass
      }

      // Only draw splats if we have data
      if (_splatBuffer != null && _splatCount > 0) {
        _splatPass.execute(_gl, _camera!, 
          projectionMatrix: _projectionMatrix, 
          viewMatrix: _viewMatrix);
      }
      
      _perf?.markGpuEnd(_gl);

      if (_perf != null) {
        final perfStats = _perf!.endFrame(_gl);
        _fps = perfStats.fps;
        _cpuFrameTimeMs = perfStats.cpuMsAvg;
        _gpuFrameTimeMs = perfStats.gpuMsAvg;
      }
      _lastFrameTime = DateTime.timestamp();
    } catch (_) {
      // Recovery path on GL/Program invalidation
      await _recoverFromContextLoss();
    } finally {
      _inFrame = false;
    }
  }

  /// Supplies raw splat data (32 bytes per splat) and rebuilds the GPU texture.
  /// Throws [ArgumentError] if the buffer length is not a multiple of 32.
  void setSplatData(Uint8List data) {
    if (data.length % GsConst.bytesPerSplat != 0) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'Must be a multiple of 32',
      );
    }
    _splatBuffer = data;
    _splatSource.upload(_gl, data);
    _splatCount = _splatSource.splatCount;
    _vertexCount = (_splatCount + GsConst.splatsPerInstance - 1) ~/ 
        GsConst.splatsPerInstance;

    // Update the draw pass instance count
    _splatPass.onSourceChanged();

    // Initial unsorted order (sequential), then request an immediate sort.
    _orderTexSvc.uploadFull(
      _gl, 
      List<int>.generate(_splatCount, (i) => i),
    );
    if (_camera != null) {
      final vp = _projectionMatrix.multiplied(_viewMatrix);
      _sort.requestImmediate(vp, data, _splatCount);
    }
  }

  /// Resizes the render target. If a camera is set, its intrinsics are updated
  /// to preserve the current field-of-view.
  ///
  /// Returns `true` if the texture actually resized (and we updated matrices).
  Future<bool> resize(GaussianCamera nextCamera) async {
    if (_isResizing) return false;

    final current = _camera;
    if (current != null &&
        nextCamera.width == current.width &&
        nextCamera.height == current.height) {
      return false; // no-op
    }

    _isResizing = true;
    try {
      // Camera is the source of truth; setter may trigger depth sort, etc.
      camera = nextCamera;

      final desired = AngleOptions(
        width: _camera!.width,
        height: _camera!.height,
        dpr: 1,
        alpha: true,
        useSurfaceProducer: true,
        customRenderer: false,
      );

      // If _targetTexture isn't statically typed, guard and early-return.
      final anyTexture = _targetTexture;
      final resized = await _tryResizeAngle(anyTexture, desired);
      if (!resized) return false;

      _updateProjectionMatrix();
      _updateViewMatrix();
      return true;
    } finally {
      _isResizing = false;
    }
  }

  /// Attempts to resize the ANGLE target and verifies the texture dimensions.
  /// Logs but does not throw on failure.
  Future<bool> _tryResizeAngle(
    FlutterAngleTexture texture,
    AngleOptions desired,
  ) async {
    try {
      await _angle.resize(texture, desired);
    } catch (e, st) {
      debugPrint('Angle.resize failed: $e\n$st');
      // fall through to verification
    }

    final opts = texture.options;
    return opts.width == desired.width && opts.height == desired.height;
  }

  /// Disposes *all* resources. The instance must not be used afterwards.
  void dispose() {
    stopRenderLoop();

    _splatPass.dispose(_gl);
    _splatSource.dispose(_gl);
    _orderTexSvc.dispose(_gl);
    _sort.dispose();

    try {
      _angle.dispose([_targetTexture]);
    } catch (e) {
      debugPrint('Warning: error disposing target texture: $e');
    }

    try {
      _perf?.dispose();
    } catch (e) {
      debugPrint('Warning: error disposing profiler: $e');
    }
  }



  // Matrix helpers

  void _updateProjectionMatrix() {
    if (_camera == null) return;
    _projectionMatrix = _makeProjectionMatrix(
      _camera!.fx,
      _camera!.fy,
      _camera!.width.toDouble(),
      _camera!.height.toDouble(),
    );
  }

  void _updateViewMatrix() {
    if (_camera == null) return;
    _viewMatrix = _makeViewMatrix(_camera!);
  }

  Matrix4 _makeProjectionMatrix(
    double fx,
    double fy,
    double width,
    double height,
  ) {
    const znear = 0.2;
    const zfar = 200.0;

    final fovX = (2 * fx) / width;
    final fovY = (2 * fy) / height;
    const farNearRatio = zfar / (zfar - znear);
    const farNearProduct = -(zfar * znear) / (zfar - znear);

    return Matrix4(
      fovX, 0, 0, 0, // column 0
      0, fovY, 0, 0, // column 1
      0, 0, farNearRatio, 1, // column 2
      0, 0, farNearProduct, 0, // column 3
    );
  }

  Matrix4 _makeViewMatrix(GaussianCamera cam) {
    final R = cam.rotation;
    final t = cam.position;

    return Matrix4(
      R.row0.x,
      R.row0.y,
      R.row0.z,
      0,
      R.row1.x,
      R.row1.y,
      R.row1.z,
      0,
      R.row2.x,
      R.row2.y,
      R.row2.z,
      0,
      -t.x * R.row0.x - t.y * R.row1.x - t.z * R.row2.x,
      -t.x * R.row0.y - t.y * R.row1.y - t.z * R.row2.y,
      -t.x * R.row0.z - t.y * R.row1.z - t.z * R.row2.z,
      1,
    );
  }

  // Context‑loss recovery
  Future<void> _recoverFromContextLoss() async {
    // Rebuild GPU state; if this fails once, leave things null and let next frame retry.
    try {
      _splatPass.dispose(_gl);
      await _splatPass.init(_gl);
    } catch (e) {
      debugPrint('Recover failed, will retry next frame: $e');
      return; // leave things null; next call to frame() can try again
    }

    _updateProjectionMatrix();

    //old profiler holds queries & GL pointers from the previous context.
    try {
      _perf?.dispose();
    } catch (_) {}

    // Recreate profiler with same settings as original setup
    final enableProfiling = _profilerType != null;
    if (enableProfiling) {
      _perf = PerfProfiler.auto(_gl);
      if (_perf is DisjointQueryGpuProfiler) {
        _profilerType = 'GPU';
      } else if (_perf is GlFinishSamplerProfiler) {
        _profilerType = 'Sampled';
      } else {
        _profilerType = 'CPU';
      }
    } else {
      _perf = null;
    }

    // Re-upload content if available
    if (_splatBuffer != null && _splatCount > 0) {
      _splatSource.upload(_gl, _splatBuffer!);
      _orderTexSvc.uploadFull(
        _gl, 
        List<int>.generate(_splatCount, (i) => i),
      );
      final vp = _projectionMatrix.multiplied(_viewMatrix);
      _sort.requestImmediate(vp, _splatBuffer!, _splatCount);
    }

    // Recreate background with new context if previously enabled
    if (_bg != null) {
      try {
        _bg!.dispose(_gl);
      } catch (_) {}
      _bg = SkydomeBackground(assetPath: _bgAssetPath!);
      _bg?.setYawPitchDegrees(0, 0); // pitch only → flips sky/ground
      if (_bgAssetPath != null) {
        try {
          await _bg!.init(_gl);
        } catch (_) {}
      }
    }
  }
}
