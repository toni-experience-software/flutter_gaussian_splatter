import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' as services;
import 'package:flutter/widgets.dart';
import 'package:flutter_gaussian_splatter/camera/camera.dart';
import 'package:flutter_gaussian_splatter/constants.dart';
import 'package:flutter_gaussian_splatter/perf/ewma.dart';
import 'package:flutter_gaussian_splatter/perf/render_stats.dart';
import 'package:flutter_gaussian_splatter/renderer/background_rotation.dart';
import 'package:flutter_gaussian_splatter/renderer/gpu/gpu_splat_source.dart';
import 'package:flutter_gaussian_splatter/renderer/splat_renderer.dart';
import 'package:flutter_gaussian_splatter/sorting/depth_sorter.dart' as depth;
import 'package:flutter_gaussian_splatter/sorting/sort_result.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

/// Experimental flutter_gpu/Impeller backend for Gaussian splats.
class FlutterGpuSplatRenderer implements SplatRenderer {
  late gpu.Shader _vertexShader;
  late gpu.Shader _fragmentShader;
  late gpu.RenderPipeline _pipeline;
  late gpu.Shader _skyVertexShader;
  late gpu.Shader _skyFragmentShader;
  late gpu.RenderPipeline _skyPipeline;
  late gpu.Texture _target;
  late gpu.HostBuffer _frameUniforms;
  late gpu.DeviceBuffer _quadVertexBuffer;
  late gpu.DeviceBuffer _skyVertexBuffer;
  late gpu.UniformSlot _frameInfoSlot;
  late gpu.UniformSlot _batchInfoSlot;
  late gpu.UniformSlot _atlasSlot;
  late gpu.UniformSlot _orderSlot;
  late gpu.UniformSlot _quatSlot;
  late gpu.UniformSlot _colorSlot;
  late gpu.UniformSlot _shSlot;
  late gpu.UniformSlot _skyInfoSlot;
  late gpu.UniformSlot _skyBgSlot;
  late gpu.Shader _shResolveFragmentShader;
  late gpu.RenderPipeline _shResolvePipeline;
  late gpu.UniformSlot _shResolveInfoSlot;
  late gpu.UniformSlot _shResolveShSlot;
  late gpu.UniformSlot _shResolveColorSlot;
  late gpu.UniformSlot _resolvedSlot;

  // Uniform member offsets are fixed once the pipelines are created, so they
  // are cached in setup() along with reusable staging buffers. HostBuffer
  // emplace() copies the bytes immediately, which makes reuse across calls
  // within a frame safe.
  late ByteData _skyInfoData;
  late int _skyViewportOffset;
  late int _skyFocalOffset;
  late int _skyInvViewRotOffset;
  late int _skyBgRotOffset;
  late ByteData _frameInfoData;
  late int _frameProjectionOffset;
  late int _frameViewOffset;
  late int _frameFocalOffset;
  late int _frameViewportOffset;
  late int _frameSplatCountOffset;
  late int _frameMaxSplatSizeOffset;
  late int _frameAtlasHeightOffset;
  late int _frameOrderHeightOffset;
  late int _frameSidecarHeightOffset;
  late int _frameShHeightOffset;
  late int _frameUseResolvedOffset;
  late ByteData _shResolveInfoData;
  late int _resolveViewDirOffset;
  late int _resolveSplatCountOffset;
  late int _resolveShHeightOffset;
  late int _resolveSidecarHeightOffset;
  late ByteData _batchInfoData;
  late int _batchBaseSplatOffset;

  static final gpu.SamplerOptions _nearestSampler = gpu.SamplerOptions();
  static final gpu.SamplerOptions _linearSampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
  );

  final GpuSplatSource _source = GpuSplatSource();
  late final depth.DepthSorterImpl _depthSorter = depth.DepthSorterImpl(
    onSortComplete: _handleSortComplete,
  );
  final Ewma _cpuMs = Ewma();

  Camera? _camera;
  var _viewMatrix = vm.Matrix4.identity();
  var _projectionMatrix = vm.Matrix4.identity();
  Uint8List? _splatBuffer;
  ui.Image? _lastFrame;
  DateTime? _lastFrameTime;
  gpu.Texture? _backgroundTexture;
  bool _inFrame = false;
  bool _isResizing = false;
  bool _sortInFlight = false;
  bool _sortPending = false;
  vm.Vector3? _lastSortedDirection;
  vm.Vector3? _lastSortedPosition;
  vm.Vector3? _inFlightSortDirection;
  vm.Vector3? _inFlightSortPosition;
  int _sortGeneration = 0;
  int _sortDataGeneration = 0;
  int _visibleCount = -1;

  gpu.Texture? _resolvedColorTexture;
  int _resolvedHeight = 0;
  bool _highQualitySH = false;
  bool _resolveDataDirty = true;
  bool _resolvedActive = false;
  vm.Vector3? _lastResolvedDirection;
  VoidCallback? _onNeedsRender;
  vm.Matrix4 _backgroundRotation = vm.Matrix4.identity();

  static const int _splatsPerBatch = 4096;
  static const int _verticesPerSplat = 6;
  static const int _floatsPerVertex = 3;
  static const int _bytesPerFloat = 4;
  static const int _skyVertexCount = 3;
  static const int _skyVertexFloatsPerVertex = 2;
  static const int _quadVertexBufferBytes =
      _splatsPerBatch * _verticesPerSplat * _floatsPerVertex * _bytesPerFloat;
  static const int _skyVertexBufferBytes =
      _skyVertexCount * _skyVertexFloatsPerVertex * _bytesPerFloat;

  /// Dot-product bound on view-direction change before a re-sort is requested.
  static const double _sortDirectionDotThreshold = 0.999;

  /// Squared camera-position delta that forces a re-sort.
  static const double _sortPositionDeltaSq = 0.0001;

  /// Dot-product bound on view-direction change before the approximated SH
  /// colors are re-resolved. SH varies slowly with direction, so this can be
  /// tuned coarser than [_sortDirectionDotThreshold] independently.
  static const double _shResolveDirectionDotThreshold = 0.999;

  /// Impeller normalizes vertical conventions across its backends, so the
  /// render-to-texture path needs a single sign on every platform.
  @override
  double get ndcYSign => 1;

  @override
  bool get highQualitySH => _highQualitySH;

  @override
  set highQualitySH(bool value) {
    if (value == _highQualitySH) return;
    _highQualitySH = value;
    // Re-enabling the approximation must recompute resolved colors.
    _resolveDataDirty = true;
    _lastResolvedDirection = null;
    _onNeedsRender?.call();
  }

  @override
  Camera? get camera => _camera;

  @override
  set camera(Camera? value) {
    if (value == _camera) return;
    _camera = value;
    _updateViewMatrix();
    _updateProjectionMatrix();
  }

  @override
  RenderStats get renderStats {
    final cpuMs = _cpuMs.value;
    return RenderStats(
      fps: cpuMs > 0 ? 1000 / cpuMs : 0,
      vertexCount: _source.splatCount,
      lastFrameTime: _lastFrameTime ?? DateTime.timestamp(),
      cpuFrameTimeMs: cpuMs > 0 ? cpuMs : null,
      profilerType: 'CPU',
    );
  }

  @override
  VoidCallback? get onNeedsRender => _onNeedsRender;

  @override
  set onNeedsRender(VoidCallback? callback) {
    _onNeedsRender = callback;
  }

  @override
  Future<void> initialize({bool debug = true}) async {
    gpu.gpuContext.defaultColorFormat;
    await _depthSorter.initialize();
  }

  @override
  Future<void> setup({
    required int width,
    required int height,
    bool enableProfiling = false,
  }) async {
    final library = gpu.ShaderLibrary.fromAsset(
      'packages/flutter_gaussian_splatter/build/shaderbundles/'
      'flutter_gaussian_splatter.shaderbundle',
    );
    if (library == null) {
      throw StateError('Failed to load flutter_gpu shader bundle.');
    }

    _vertexShader = library['SplatVertex']!;
    _fragmentShader = library['SplatFragment']!;
    _pipeline = gpu.gpuContext.createRenderPipeline(
      _vertexShader,
      _fragmentShader,
    );
    _frameInfoSlot = _vertexShader.getUniformSlot('FrameInfo');
    _batchInfoSlot = _vertexShader.getUniformSlot('BatchInfo');
    _atlasSlot = _vertexShader.getUniformSlot('u_texture');
    _orderSlot = _vertexShader.getUniformSlot('u_order_texture');
    _quatSlot = _vertexShader.getUniformSlot('u_quat_texture');
    _colorSlot = _vertexShader.getUniformSlot('u_color_texture');
    _shSlot = _vertexShader.getUniformSlot('u_sh_texture');
    _resolvedSlot = _vertexShader.getUniformSlot('u_resolved_texture');
    _frameUniforms = gpu.gpuContext.createHostBuffer();
    _quadVertexBuffer =
        gpu.gpuContext.createDeviceBufferWithCopy(_buildQuadVertexData());
    _skyVertexShader = library['SkyVertex']!;
    _skyFragmentShader = library['SkyFragment']!;
    _skyPipeline = gpu.gpuContext.createRenderPipeline(
      _skyVertexShader,
      _skyFragmentShader,
    );
    _skyInfoSlot = _skyFragmentShader.getUniformSlot('SkyInfo');
    _skyBgSlot = _skyFragmentShader.getUniformSlot('u_bg');
    _skyVertexBuffer =
        gpu.gpuContext.createDeviceBufferWithCopy(_buildSkyVertexData());

    // SH resolve pass reuses the fullscreen-triangle SkyVertex shader.
    _shResolveFragmentShader = library['ShResolveFragment']!;
    _shResolvePipeline = gpu.gpuContext.createRenderPipeline(
      _skyVertexShader,
      _shResolveFragmentShader,
    );
    _shResolveInfoSlot =
        _shResolveFragmentShader.getUniformSlot('ShResolveInfo');
    _shResolveShSlot = _shResolveFragmentShader.getUniformSlot('u_sh_texture');
    _shResolveColorSlot =
        _shResolveFragmentShader.getUniformSlot('u_color_texture');

    _cacheUniformLayouts();
    _target = _createTarget(width, height);
  }

  void _cacheUniformLayouts() {
    _skyInfoData = ByteData(_skyInfoSlot.sizeInBytes ?? 144);
    _skyViewportOffset = _skyInfoSlot.getMemberOffsetInBytes('viewport') ?? 0;
    _skyFocalOffset = _skyInfoSlot.getMemberOffsetInBytes('focal') ?? 8;
    _skyInvViewRotOffset =
        _skyInfoSlot.getMemberOffsetInBytes('invViewRot') ?? 16;
    _skyBgRotOffset = _skyInfoSlot.getMemberOffsetInBytes('bgRot') ?? 80;

    _frameInfoData = ByteData(_frameInfoSlot.sizeInBytes ?? 176);
    _frameProjectionOffset =
        _frameInfoSlot.getMemberOffsetInBytes('projection') ?? 0;
    _frameViewOffset = _frameInfoSlot.getMemberOffsetInBytes('view') ?? 64;
    _frameFocalOffset = _frameInfoSlot.getMemberOffsetInBytes('focal') ?? 128;
    _frameViewportOffset =
        _frameInfoSlot.getMemberOffsetInBytes('viewport') ?? 136;
    _frameSplatCountOffset =
        _frameInfoSlot.getMemberOffsetInBytes('splat_count') ?? 144;
    _frameMaxSplatSizeOffset =
        _frameInfoSlot.getMemberOffsetInBytes('max_splat_size') ?? 148;
    _frameAtlasHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('atlas_height') ?? 152;
    _frameOrderHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('order_height') ?? 156;
    _frameSidecarHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('sidecar_height') ?? 160;
    _frameShHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('sh_height') ?? 164;
    _frameUseResolvedOffset =
        _frameInfoSlot.getMemberOffsetInBytes('use_resolved') ?? 168;

    _shResolveInfoData = ByteData(_shResolveInfoSlot.sizeInBytes ?? 32);
    _resolveViewDirOffset =
        _shResolveInfoSlot.getMemberOffsetInBytes('view_dir') ?? 0;
    _resolveSplatCountOffset =
        _shResolveInfoSlot.getMemberOffsetInBytes('splat_count') ?? 12;
    _resolveShHeightOffset =
        _shResolveInfoSlot.getMemberOffsetInBytes('sh_height') ?? 16;
    _resolveSidecarHeightOffset =
        _shResolveInfoSlot.getMemberOffsetInBytes('sidecar_height') ?? 20;

    _batchInfoData = ByteData(_batchInfoSlot.sizeInBytes ?? 16);
    _batchBaseSplatOffset =
        _batchInfoSlot.getMemberOffsetInBytes('base_splat') ?? 0;
  }

  @override
  Future<bool> resize(Camera nextCamera) async {
    if (_isResizing) return false;

    final current = _camera;
    if (current != null &&
        nextCamera.width == current.width &&
        nextCamera.height == current.height) {
      return false;
    }

    _isResizing = true;
    try {
      camera = nextCamera;
      _target = _createTarget(nextCamera.width, nextCamera.height);
      _requestSort(force: true);
      return true;
    } finally {
      _isResizing = false;
    }
  }

  @override
  Future<void> setSplatData(Uint8List data) async {
    if (data.length % GsConst.bytesPerSplat != 0) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'Must be a multiple of ${GsConst.bytesPerSplat}',
      );
    }

    _splatBuffer = data;
    _visibleCount = -1; // draw all until the first sort for this data lands
    _resolveDataDirty = true; // resolved SH colors must be recomputed
    _lastResolvedDirection = null;
    _source.uploadSplats(data);
    _sortDataGeneration++;
    _depthSorter.setSplatData(data, _source.splatCount);
    _source.uploadOrder(_sequentialOrder(_source.splatCount));

    if (_camera != null) {
      _requestSort(force: true);
      await _depthSorter.firstSortComplete;
    }
  }

  @override
  Future<void> frame() async {
    if (_isResizing || _inFrame || _camera == null) return;

    final hasBackground = _backgroundTexture != null;
    final atlas = _source.atlas;
    final orderTexture = _source.orderTexture;
    final quatTexture = _source.quatTexture;
    final colorTexture = _source.colorTexture;
    final shTexture = _source.shTexture;
    final hasSplats = atlas != null &&
        orderTexture != null &&
        quatTexture != null &&
        colorTexture != null &&
        shTexture != null &&
        _source.splatCount > 0;

    if (!hasBackground && !hasSplats) {
      return;
    }
    _inFrame = true;
    final watch = Stopwatch()..start();
    try {
      _requestSort();
      _frameUniforms.reset();

      // SH resolve pass: evaluate per-splat SH colors into a texture the splat
      // pass samples once, instead of 12 SH fetches + eval per vertex. It runs
      // on its own command buffer (submitted first) because flutter_gpu allows
      // only one render pass to encode per command buffer at a time.
      _resolvedActive = false;
      if (hasSplats && !_highQualitySH) {
        _ensureResolvedTexture();
        if (_shouldResolveNow()) {
          final resolveBuffer = gpu.gpuContext.createCommandBuffer();
          resolveBuffer.createRenderPass(
            gpu.RenderTarget.singleColor(
              gpu.ColorAttachment(
                texture: _resolvedColorTexture!,
                clearValue: vm.Vector4(0, 0, 0, 0),
              ),
            ),
          )
            ..setViewport(
              gpu.Viewport(
                width: GsConst.splatsPerRow,
                height: _resolvedHeight,
              ),
            )
            ..setDepthWriteEnable(false)
            ..setColorBlendEnable(false)
            ..setCullMode(gpu.CullMode.none)
            ..bindPipeline(_shResolvePipeline)
            ..bindUniform(
              _shResolveInfoSlot,
              _frameUniforms.emplace(_packShResolveInfo()),
            )
            ..bindTexture(_shResolveShSlot, shTexture, sampler: _nearestSampler)
            ..bindTexture(
              _shResolveColorSlot,
              colorTexture,
              sampler: _nearestSampler,
            )
            ..bindVertexBuffer(
              gpu.BufferView(
                _skyVertexBuffer,
                offsetInBytes: 0,
                lengthInBytes: _skyVertexBufferBytes,
              ),
              _skyVertexCount,
            )
            ..draw();
          resolveBuffer.submit();
          _lastResolvedDirection = _viewDirectionFor(_camera!);
          _resolveDataDirty = false;
        }
        _resolvedActive = _resolvedColorTexture != null;
      }

      final commandBuffer = gpu.gpuContext.createCommandBuffer();
      final renderPass = commandBuffer.createRenderPass(
        gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(
            texture: _target,
            clearValue: vm.Vector4(0, 0, 0, 0),
          ),
        ),
      )
        ..setViewport(
          gpu.Viewport(width: _target.width, height: _target.height),
        )
        ..setDepthWriteEnable(false)
        ..setColorBlendEquation(gpu.ColorBlendEquation())
        ..setCullMode(gpu.CullMode.none);

      if (hasBackground) {
        renderPass
          ..bindPipeline(_skyPipeline)
          ..setColorBlendEnable(false)
          ..bindUniform(_skyInfoSlot, _frameUniforms.emplace(_packSkyInfo()))
          ..bindTexture(
            _skyBgSlot,
            _backgroundTexture!,
            sampler: _linearSampler,
          )
          ..bindVertexBuffer(
            gpu.BufferView(
              _skyVertexBuffer,
              offsetInBytes: 0,
              lengthInBytes: _skyVertexBufferBytes,
            ),
            _skyVertexCount,
          )
          ..draw();
      }

      if (hasSplats) {
        final frameInfo = _frameUniforms.emplace(_packFrameInfo());
        renderPass
          ..bindPipeline(_pipeline)
          ..setColorBlendEnable(true)
          ..bindUniform(_frameInfoSlot, frameInfo)
          ..bindTexture(_atlasSlot, atlas, sampler: _nearestSampler)
          ..bindTexture(_orderSlot, orderTexture, sampler: _nearestSampler)
          ..bindTexture(_quatSlot, quatTexture, sampler: _nearestSampler)
          ..bindTexture(_colorSlot, colorTexture, sampler: _nearestSampler)
          ..bindTexture(_shSlot, shTexture, sampler: _nearestSampler)
          // u_resolved_texture must always be bound; when high-quality SH is
          // active it goes unsampled, so the color texture stands in for it.
          ..bindTexture(
            _resolvedSlot,
            _resolvedActive ? _resolvedColorTexture! : colorTexture,
            sampler: _nearestSampler,
          );
        // Skip behind-camera splats, which the sorter parks in the order tail.
        final fullCount = _source.splatCount;
        final drawCount = _visibleCount < 0
            ? fullCount
            : (_visibleCount < fullCount ? _visibleCount : fullCount);
        for (var baseSplat = 0;
            baseSplat < drawCount;
            baseSplat += _splatsPerBatch) {
          final remaining = drawCount - baseSplat;
          final splatsInBatch =
              remaining < _splatsPerBatch ? remaining : _splatsPerBatch;
          renderPass
            ..bindUniform(
              _batchInfoSlot,
              _frameUniforms.emplace(_packBatchInfo(baseSplat)),
            )
            ..bindVertexBuffer(
              gpu.BufferView(
                _quadVertexBuffer,
                offsetInBytes: 0,
                lengthInBytes: _quadVertexBufferBytes,
              ),
              splatsInBatch * _verticesPerSplat,
            )
            ..draw();
        }
      }

      commandBuffer.submit();
      final previousFrame = _lastFrame;
      _lastFrame = _target.asImage();
      previousFrame?.dispose();
      _lastFrameTime = DateTime.timestamp();
    } finally {
      watch.stop();
      _cpuMs.add(watch.elapsedMicroseconds / 1000);
      _inFrame = false;
    }
  }

  @override
  Future<void> enableBackgroundFromAsset(String assetPath) async {
    final byteData = await services.rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final rgba = await image.toByteData();
        if (rgba == null) {
          throw StateError(
            'Failed to convert background image to raw RGBA bytes.',
          );
        }

        final width = image.width;
        final height = image.height;
        if (_backgroundTexture == null ||
            _backgroundTexture!.width != width ||
            _backgroundTexture!.height != height) {
          _backgroundTexture = gpu.gpuContext.createTexture(
            gpu.StorageMode.hostVisible,
            width,
            height,
            enableRenderTargetUsage: false,
          );
        }
        _backgroundTexture!.overwrite(rgba);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }

    _onNeedsRender?.call();
  }

  @override
  void disableBackground() {
    _backgroundTexture = null;
    _onNeedsRender?.call();
  }

  @override
  void setBackgroundRotation(double yawDegrees, double pitchDegrees) {
    _backgroundRotation =
        _matrix4From3x3(backgroundRotation3x3(yawDegrees, pitchDegrees));
    _onNeedsRender?.call();
  }

  @override
  Widget buildOutput(BuildContext context, {required Size logicalSize}) {
    final image = _lastFrame;
    if (image == null) {
      return SizedBox(width: logicalSize.width, height: logicalSize.height);
    }
    return RawImage(
      image: image,
      width: logicalSize.width,
      height: logicalSize.height,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.none,
    );
  }

  @override
  void dispose() {
    try {
      _lastFrame?.dispose();
      _lastFrame = null;
      _source.dispose();
    } finally {
      // The sorter owns an isolate; release it even if texture cleanup throws.
      _depthSorter.dispose();
      _backgroundTexture = null;
      _resolvedColorTexture = null;
    }
  }

  gpu.Texture _createTarget(int width, int height) {
    return gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
    );
  }

  ByteData _packSkyInfo() {
    final data = _skyInfoData
      ..setFloat32(_skyViewportOffset, _camera!.width.toDouble(), Endian.host)
      ..setFloat32(
        _skyViewportOffset + 4,
        _camera!.height.toDouble(),
        Endian.host,
      )
      ..setFloat32(_skyFocalOffset, _camera!.focalXForShader(), Endian.host)
      ..setFloat32(
        _skyFocalOffset + 4,
        _camera!.focalYForShader(),
        Endian.host,
      );
    _writeMatrix(
      data,
      _skyInvViewRotOffset,
      _matrix4From3x3(_camera!.invViewRotation3x3()),
    );
    _writeMatrix(data, _skyBgRotOffset, _backgroundRotation);
    return data;
  }

  ByteData _packFrameInfo() {
    final data = _frameInfoData;
    _writeMatrix(data, _frameProjectionOffset, _projectionMatrix);
    _writeMatrix(data, _frameViewOffset, _viewMatrix);
    return data
      ..setFloat32(_frameFocalOffset, _camera!.focalXForShader(), Endian.host)
      ..setFloat32(
        _frameFocalOffset + 4,
        _camera!.focalYForShader(),
        Endian.host,
      )
      ..setFloat32(_frameViewportOffset, _camera!.width.toDouble(), Endian.host)
      ..setFloat32(
        _frameViewportOffset + 4,
        _camera!.height.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _frameSplatCountOffset,
        _source.splatCount.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _frameMaxSplatSizeOffset,
        GsConst.maxSplatPixelSize,
        Endian.host,
      )
      ..setFloat32(
        _frameAtlasHeightOffset,
        _source.atlasHeight.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _frameOrderHeightOffset,
        _source.orderHeight.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _frameSidecarHeightOffset,
        _source.sidecarHeight.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _frameShHeightOffset,
        _source.shHeight.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _frameUseResolvedOffset,
        _resolvedActive ? 1.0 : 0.0,
        Endian.host,
      );
  }

  ByteData _packShResolveInfo() {
    final dir = _viewDirectionFor(_camera!);
    return _shResolveInfoData
      ..setFloat32(_resolveViewDirOffset, dir.x, Endian.host)
      ..setFloat32(_resolveViewDirOffset + 4, dir.y, Endian.host)
      ..setFloat32(_resolveViewDirOffset + 8, dir.z, Endian.host)
      ..setFloat32(
        _resolveSplatCountOffset,
        _source.splatCount.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _resolveShHeightOffset,
        _source.shHeight.toDouble(),
        Endian.host,
      )
      ..setFloat32(
        _resolveSidecarHeightOffset,
        _source.sidecarHeight.toDouble(),
        Endian.host,
      );
  }

  void _ensureResolvedTexture() {
    final height = _source.sidecarHeight;
    if (height <= 0) return;
    if (_resolvedColorTexture == null || _resolvedHeight != height) {
      _resolvedColorTexture = gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        GsConst.splatsPerRow,
        height,
      );
      _resolvedHeight = height;
      _resolveDataDirty = true; // freshly allocated → must be filled
    }
  }

  bool _shouldResolveNow() {
    if (_resolvedColorTexture == null) return false;
    if (_resolveDataDirty) return true;
    final last = _lastResolvedDirection;
    if (last == null) return true;
    return _viewDirectionFor(_camera!).dot(last) <
        _shResolveDirectionDotThreshold;
  }

  ByteData _packBatchInfo(int baseSplat) {
    return _batchInfoData
      ..setFloat32(_batchBaseSplatOffset, baseSplat.toDouble(), Endian.host);
  }

  ByteData _buildQuadVertexData() {
    final vertices = Float32List(
      _splatsPerBatch * _verticesPerSplat * _floatsPerVertex,
    );
    const corners = <double>[
      -1,
      -1,
      1,
      -1,
      1,
      1,
      -1,
      -1,
      1,
      1,
      -1,
      1,
    ];
    var offset = 0;
    for (var splat = 0; splat < _splatsPerBatch; splat++) {
      for (var vertex = 0; vertex < _verticesPerSplat; vertex++) {
        vertices[offset++] = corners[vertex * 2];
        vertices[offset++] = corners[vertex * 2 + 1];
        vertices[offset++] = splat.toDouble();
      }
    }
    return vertices.buffer.asByteData();
  }

  ByteData _buildSkyVertexData() {
    return Float32List.fromList(<double>[
      -1,
      -1,
      3,
      -1,
      -1,
      3,
    ]).buffer.asByteData();
  }

  void _writeMatrix(ByteData data, int offset, vm.Matrix4 matrix) {
    for (var i = 0; i < 16; i++) {
      data.setFloat32(offset + i * 4, matrix.storage[i], Endian.host);
    }
  }

  vm.Matrix4 _matrix4From3x3(List<double> matrix3) {
    return vm.Matrix4(
      matrix3[0],
      matrix3[1],
      matrix3[2],
      0,
      matrix3[3],
      matrix3[4],
      matrix3[5],
      0,
      matrix3[6],
      matrix3[7],
      matrix3[8],
      0,
      0,
      0,
      0,
      1,
    );
  }

  void _updateProjectionMatrix() {
    if (_camera == null) return;
    _projectionMatrix = _camera!.projectionMatrix();
  }

  void _updateViewMatrix() {
    if (_camera == null) return;
    _viewMatrix = _camera!.viewMatrix();
  }

  void _requestSort({bool force = false}) {
    final camera = _camera;
    if (_splatBuffer == null || _source.splatCount <= 0 || camera == null) {
      return;
    }
    if (!force && !_shouldSortForCamera()) return;
    if (_sortInFlight) {
      _sortPending = true;
      return;
    }

    final direction = _viewDirectionFor(camera);
    final position = camera.position.clone();
    final generation = ++_sortGeneration;
    _sortInFlight = true;
    _inFlightSortDirection = direction;
    _inFlightSortPosition = position;
    final vp = _projectionMatrix.multiplied(_viewMatrix);
    try {
      _depthSorter.runSort(
        vp,
        generation: generation,
        dataGeneration: _sortDataGeneration,
      );
    } catch (_) {
      _clearSortInFlight();
      rethrow;
    }
  }

  void _handleSortComplete(SortResult result) {
    final sortedDirection = _inFlightSortDirection;
    final sortedPosition = _inFlightSortPosition;
    _clearSortInFlight();

    final camera = _camera;
    final canApply = camera != null &&
        sortedDirection != null &&
        sortedPosition != null &&
        result.generation == _sortGeneration &&
        result.dataGeneration == _sortDataGeneration;

    if (canApply) {
      _lastSortedDirection = sortedDirection;
      _lastSortedPosition = sortedPosition;
      _visibleCount = result.visibleCount;
      _source.uploadOrder(result.depthIndex);
      _onNeedsRender?.call();

      if (_shouldSortForCamera()) {
        _sortPending = true;
      }
    }

    if (_sortPending) {
      _sortPending = false;
      _requestSort(force: true);
    }
  }

  bool _shouldSortForCamera() {
    final camera = _camera;
    if (camera == null) return false;

    final currentDirection = _viewDirectionFor(camera);
    final lastDirection = _lastSortedDirection;
    if (lastDirection == null) return true;
    if (currentDirection.dot(lastDirection) < _sortDirectionDotThreshold) {
      return true;
    }

    final lastPosition = _lastSortedPosition;
    if (lastPosition == null) return true;

    return (camera.position - lastPosition).length2 > _sortPositionDeltaSq;
  }

  vm.Vector3 _viewDirectionFor(Camera camera) {
    final rotation = camera.rotation;
    return vm.Vector3(
      rotation.entry(0, 2),
      rotation.entry(1, 2),
      rotation.entry(2, 2),
    ).normalized();
  }

  void _clearSortInFlight() {
    _sortInFlight = false;
    _inFlightSortDirection = null;
    _inFlightSortPosition = null;
  }

  Uint32List _sequentialOrder(int count) {
    final order = Uint32List(count);
    for (var i = 0; i < count; i++) {
      order[i] = i;
    }
    return order;
  }
}
