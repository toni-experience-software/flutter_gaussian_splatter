import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_angle/flutter_angle.dart';
import 'package:flutter_gaussian_splatter/core/background/sky_pass.dart';
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


/// Renders Gaussian splats into an in‑memory [FlutterAngleTexture].
class TextureGaussianRenderer {
  // Dependencies & context
  late final FlutterAngle _angle;
  late FlutterAngleTexture _targetTexture;
  late RenderingContext _gl;

  // New service-based architecture
  late final SplatSource _splatSource = SplatSource();
  late final OrderTexture _orderTexSvc = OrderTexture();
  late final depth.DepthSorterImpl _depthSorter = depth.DepthSorterImpl(
    onSortComplete: (result) {
      _orderTexSvc.uploadFull(_gl, result.depthIndex.toList());
      // Update instancing count in the pass when order changes:
      _splatPass.onSourceChanged();
    },
  );
  late final SplatDrawPass _splatPass = SplatDrawPass(
    source: _splatSource,
    order: _orderTexSvc,
    disableAlphaWrite: _disableAlphaWrite,
  );

  //Background
  SkyPass? _bg;
  String? _bgAssetPath; // for reload after context loss

  // Performance profiling
  PerfProfiler? _perf;

  // Render state & matrices
  var _viewMatrix = Matrix4.identity();
  var _projectionMatrix = Matrix4.identity();
  GaussianCamera? _camera;

  // Splat data & vertices
  Uint8List? _splatBuffer;
  int _splatCount = 0;

  // Render state
  bool _inFrame = false;
  String? _profilerType;
  bool _isResizing = false;
  PerfStats? _lastPerfStats;

  // Optimization settings
  bool _disableAlphaWrite = true;

  // Public API

  /// Latest frame statistics with detailed performance profiling.
  RenderStats get renderStats => RenderStats(
        fps: _lastPerfStats?.fps ?? 0.0,
        vertexCount: _splatSource.splatCount,
        lastFrameTime: DateTime.timestamp(),
        cpuFrameTimeMs: _lastPerfStats?.cpuMsAvg,
        gpuFrameTimeMs: _lastPerfStats?.gpuMsAvg,
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
    _bg ??= SkyPass(assetPath: assetPath);
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
    _splatPass.setDisableAlphaWrite(disable);

  }

  // Life‑cycle

  /// Initializes ANGLE and the depth‑sorter. Must be called before any other
  /// method.
  Future<void> initialize({bool debug = true}) async {
    _angle = FlutterAngle();
    await _angle.init(debug);

    await _depthSorter.initialize();
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

  /// Drives a single frame.  Call from a `Ticker` / `SchedulerBinding`.
  Future<void> frame() async {
    // Bail during resize/context swap
    // Reentrancy guard
    if (_isResizing || _inFrame) return;

    // Guard readiness up front
    if (_camera == null) return;

    _inFrame = true;
    try {
      _perf?.beginFrame();

      // Always sort immediately when rendering
      if (_splatBuffer != null && _splatCount > 0) {
        final vp = _projectionMatrix.multiplied(_viewMatrix);
        _depthSorter.runSort(vp, _splatBuffer!, _splatCount);
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
        _splatPass.execute(
          _gl,
          _camera!,
          projectionMatrix: _projectionMatrix,
          viewMatrix: _viewMatrix,
        );
      }
      _gl.flush();

      _perf?.markGpuEnd(_gl);

      _lastPerfStats = _perf?.endFrame(_gl);
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

    // Update the draw pass instance count
    _splatPass.onSourceChanged();

    // Initial unsorted order (sequential), then request an immediate sort.
    _orderTexSvc.uploadFull(
      _gl,
      List<int>.generate(_splatCount, (i) => i),
    );
    if (_camera != null) {
      final vp = _projectionMatrix.multiplied(_viewMatrix);
      _depthSorter.runSort(vp, data, _splatCount);
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
    _bg?.dispose(_gl);
    _splatPass.dispose(_gl);
    _splatSource.dispose(_gl);
    _orderTexSvc.dispose(_gl);
    _depthSorter.dispose();

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
    _projectionMatrix = _camera!.projectionMatrix();
  }

  void _updateViewMatrix() {
    if (_camera == null) return;
    _viewMatrix = _camera!.viewMatrix();
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
      _depthSorter.runSort(vp, _splatBuffer!, _splatCount);
    }

    // Recreate background with new context if previously enabled
    if (_bg != null) {
      try {
        _bg!.dispose(_gl);
      } catch (_) {}
      _bg = SkyPass(assetPath: _bgAssetPath!);
      _bg?.setYawPitchDegrees(0, 0); // pitch only → flips sky/ground
      if (_bgAssetPath != null) {
        try {
          await _bg!.init(_gl);
        } catch (_) {}
      }
    }
  }
}
