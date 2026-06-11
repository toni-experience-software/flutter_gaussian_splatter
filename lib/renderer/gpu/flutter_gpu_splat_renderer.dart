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

  /// Impeller normalizes vertical conventions across its backends, so the
  /// render-to-texture path needs a single sign on every platform.
  @override
  double get ndcYSign => 1;

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
    _target = _createTarget(width, height);
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
          ..bindTexture(_shSlot, shTexture, sampler: _nearestSampler);
        for (var baseSplat = 0;
            baseSplat < _source.splatCount;
            baseSplat += _splatsPerBatch) {
          final remaining = _source.splatCount - baseSplat;
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
    _lastFrame?.dispose();
    _lastFrame = null;
    _source.dispose();
    _depthSorter.dispose();
    _backgroundTexture = null;
  }

  gpu.Texture _createTarget(int width, int height) {
    return gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
    );
  }

  ByteData _packSkyInfo() {
    final size = _skyInfoSlot.sizeInBytes ?? 144;
    final data = ByteData(size);

    final viewportOffset = _skyInfoSlot.getMemberOffsetInBytes('viewport') ?? 0;
    data
      ..setFloat32(viewportOffset, _camera!.width.toDouble(), Endian.host)
      ..setFloat32(viewportOffset + 4, _camera!.height.toDouble(), Endian.host);

    final focalOffset = _skyInfoSlot.getMemberOffsetInBytes('focal') ?? 8;
    data
      ..setFloat32(focalOffset, _camera!.focalXForShader(), Endian.host)
      ..setFloat32(focalOffset + 4, _camera!.focalYForShader(), Endian.host);

    _writeMatrix(
      data,
      _skyInfoSlot.getMemberOffsetInBytes('invViewRot') ?? 16,
      _matrix4From3x3(_camera!.invViewRotation3x3()),
    );
    _writeMatrix(
      data,
      _skyInfoSlot.getMemberOffsetInBytes('bgRot') ?? 80,
      _backgroundRotation,
    );
    return data;
  }

  ByteData _packFrameInfo() {
    final size = _frameInfoSlot.sizeInBytes ?? 176;
    final data = ByteData(size);
    _writeMatrix(
      data,
      _frameInfoSlot.getMemberOffsetInBytes('projection') ?? 0,
      _projectionMatrix,
    );
    _writeMatrix(
      data,
      _frameInfoSlot.getMemberOffsetInBytes('view') ?? 64,
      _viewMatrix,
    );

    final focalOffset = _frameInfoSlot.getMemberOffsetInBytes('focal') ?? 128;
    data
      ..setFloat32(focalOffset, _camera!.focalXForShader(), Endian.host)
      ..setFloat32(focalOffset + 4, _camera!.focalYForShader(), Endian.host);

    final viewportOffset =
        _frameInfoSlot.getMemberOffsetInBytes('viewport') ?? 136;
    data
      ..setFloat32(viewportOffset, _camera!.width.toDouble(), Endian.host)
      ..setFloat32(viewportOffset + 4, _camera!.height.toDouble(), Endian.host);

    final splatCountOffset =
        _frameInfoSlot.getMemberOffsetInBytes('splat_count') ?? 144;
    data.setFloat32(
      splatCountOffset,
      _source.splatCount.toDouble(),
      Endian.host,
    );

    final maxSizeOffset =
        _frameInfoSlot.getMemberOffsetInBytes('max_splat_size') ?? 148;
    data.setFloat32(maxSizeOffset, GsConst.maxSplatPixelSize, Endian.host);

    final atlasHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('atlas_height') ?? 152;
    data.setFloat32(
      atlasHeightOffset,
      _source.atlasHeight.toDouble(),
      Endian.host,
    );

    final orderHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('order_height') ?? 156;
    data.setFloat32(
      orderHeightOffset,
      _source.orderHeight.toDouble(),
      Endian.host,
    );

    final sidecarHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('sidecar_height') ?? 160;
    data.setFloat32(
      sidecarHeightOffset,
      _source.sidecarHeight.toDouble(),
      Endian.host,
    );

    final shHeightOffset =
        _frameInfoSlot.getMemberOffsetInBytes('sh_height') ?? 164;
    data.setFloat32(
      shHeightOffset,
      _source.shHeight.toDouble(),
      Endian.host,
    );

    return data;
  }

  ByteData _packBatchInfo(int baseSplat) {
    final size = _batchInfoSlot.sizeInBytes ?? 16;
    return ByteData(size)
      ..setFloat32(
        _batchInfoSlot.getMemberOffsetInBytes('base_splat') ?? 0,
        baseSplat.toDouble(),
        Endian.host,
      );
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
    if (currentDirection.dot(lastDirection) < 0.999) return true;

    final lastPosition = _lastSortedPosition;
    if (lastPosition == null) return true;

    return (camera.position - lastPosition).length2 > 0.0001;
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
