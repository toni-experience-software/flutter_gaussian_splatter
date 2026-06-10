import 'dart:typed_data';

import 'package:flutter_gaussian_splatter/constants.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;

/// flutter_gpu texture storage for packed splat and draw-order data.
class GpuSplatSource {
  /// Packed RGBA32F splat atlas.
  gpu.Texture? atlas;

  /// Packed RGBA8 order texture, little-endian uint32 per texel.
  gpu.Texture? orderTexture;

  /// Quaternion bytes as RGBA8.
  gpu.Texture? quatTexture;

  /// Base RGBA color texture.
  gpu.Texture? colorTexture;

  /// SH residual bytes as RGBA8, 12 texels per splat.
  gpu.Texture? shTexture;

  /// Number of uploaded splats.
  int splatCount = 0;

  /// Current atlas texture height.
  int get atlasHeight => _atlasHeight;

  /// Current quaternion/color texture height.
  int get sidecarHeight => _sidecarHeight;

  /// Current SH texture height.
  int get shHeight => _shHeight;

  /// Current allocated order texture height.
  int get orderHeight => _orderAllocHeight;

  int _atlasHeight = 0;
  int _sidecarHeight = 0;
  int _shHeight = 0;
  int _orderAllocHeight = 0;
  Uint8List? _atlasScratch;
  Uint8List? _quatScratch;
  Uint8List? _colorScratch;
  Uint8List? _shScratch;
  Uint8List? _orderScratch;

  static const int _floatTexelsPerSplat = 2;
  static const int _floatAtlasWidth =
      GsConst.splatsPerRow * _floatTexelsPerSplat;
  static const int _shTexelsPerSplat = 12;

  /// Uploads raw 128-byte-per-splat data into the flutter_gpu atlas.
  void uploadSplats(Uint8List buffer) {
    assert(
      buffer.length % GsConst.bytesPerSplat == 0,
      'Splat buffer must be multiple of ${GsConst.bytesPerSplat} bytes',
    );

    final count = buffer.length ~/ GsConst.bytesPerSplat;
    final height = ((_floatTexelsPerSplat * count) / _floatAtlasWidth).ceil();
    final sidecarHeight =
        (count + GsConst.splatsPerRow - 1) ~/ GsConst.splatsPerRow;
    final shHeight =
        ((count * _shTexelsPerSplat) / GsConst.splatsPerRow).ceil();
    final neededBytes = _floatAtlasWidth * height * GsConst.bytesPerTexel;
    final scratch = _ensureAtlasScratch(neededBytes);
    final sidecarNeededBytes = sidecarHeight * GsConst.splatsPerRow * 4;
    final quatBytes = _ensureQuatScratch(sidecarNeededBytes);
    final colorBytes = _ensureColorScratch(sidecarNeededBytes);
    final shNeededBytes = shHeight * GsConst.splatsPerRow * 4;
    final shBytes = _ensureShScratch(shNeededBytes);

    final srcF32 = Float32List.view(buffer.buffer);
    final srcU8 = Uint8List.view(buffer.buffer);
    final dstF32 = Float32List.view(scratch.buffer);
    final dstU32 = Uint32List.view(scratch.buffer);
    dstU32.fillRange(0, dstU32.length, 0);
    quatBytes.fillRange(0, sidecarNeededBytes, 0);
    colorBytes.fillRange(0, sidecarNeededBytes, 0);
    shBytes.fillRange(0, shNeededBytes, 0);

    const floatsPerSplat = GsConst.bytesPerSplat ~/ 4;
    for (var idx = 0; idx < count; idx++) {
      final x = (idx & GsConst.splatIdxColMask) * _floatTexelsPerSplat;
      final y = idx >> 9;

      final p0 = (y * _floatAtlasWidth + x) * 4;
      final p1 = p0 + 4;

      final fBase = floatsPerSplat * idx;
      final bBase = GsConst.bytesPerSplat * idx;

      dstF32[p0] = srcF32[fBase];
      dstF32[p0 + 1] = srcF32[fBase + 1];
      dstF32[p0 + 2] = srcF32[fBase + 2];
      dstF32[p0 + 3] = 0;

      dstF32[p1] = srcF32[fBase + 3];
      dstF32[p1 + 1] = srcF32[fBase + 4];
      dstF32[p1 + 2] = srcF32[fBase + 5];
      dstF32[p1 + 3] = 0;

      final sidecarBase = ((idx >> 9) * GsConst.splatsPerRow +
              (idx & GsConst.splatIdxColMask)) *
          4;
      quatBytes[sidecarBase] = srcU8[bBase + GsConst.quatOffset];
      quatBytes[sidecarBase + 1] = srcU8[bBase + GsConst.quatOffset + 1];
      quatBytes[sidecarBase + 2] = srcU8[bBase + GsConst.quatOffset + 2];
      quatBytes[sidecarBase + 3] = srcU8[bBase + GsConst.quatOffset + 3];

      final colorBase = sidecarBase;
      colorBytes[colorBase] = srcU8[bBase + GsConst.colorOffset];
      colorBytes[colorBase + 1] = srcU8[bBase + GsConst.colorOffset + 1];
      colorBytes[colorBase + 2] = srcU8[bBase + GsConst.colorOffset + 2];
      colorBytes[colorBase + 3] = srcU8[bBase + GsConst.colorOffset + 3];

      final shSource = bBase + GsConst.shOffset;
      final shTarget = idx * _shTexelsPerSplat * 4;
      shBytes.setRange(
        shTarget,
        shTarget + GsConst.shPackedWords * 4,
        srcU8,
        shSource,
      );
    }

    if (atlas == null || _atlasHeight != height) {
      atlas = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        _floatAtlasWidth,
        height,
        format: gpu.PixelFormat.r32g32b32a32Float,
        enableRenderTargetUsage: false,
      );
      _atlasHeight = height;
    }

    atlas!.overwrite(scratch.buffer.asByteData(0, neededBytes));

    if (quatTexture == null || _sidecarHeight != sidecarHeight) {
      quatTexture = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        GsConst.splatsPerRow,
        sidecarHeight,
        enableRenderTargetUsage: false,
      );
    }
    quatTexture!.overwrite(quatBytes.buffer.asByteData(0, sidecarNeededBytes));

    if (colorTexture == null || _sidecarHeight != sidecarHeight) {
      colorTexture = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        GsConst.splatsPerRow,
        sidecarHeight,
        enableRenderTargetUsage: false,
      );
    }
    colorTexture!
        .overwrite(colorBytes.buffer.asByteData(0, sidecarNeededBytes));

    _sidecarHeight = sidecarHeight;

    if (shTexture == null || _shHeight != shHeight) {
      shTexture = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        GsConst.splatsPerRow,
        shHeight,
        enableRenderTargetUsage: false,
      );
      _shHeight = shHeight;
    }
    shTexture!.overwrite(shBytes.buffer.asByteData(0, shNeededBytes));

    splatCount = count;
  }

  /// Uploads the sorted splat order as little-endian RGBA8 texels.
  void uploadOrder(Uint32List indices) {
    if (indices.isEmpty) return;

    final neededRows =
        (indices.length + GsConst.splatsPerRow - 1) ~/ GsConst.splatsPerRow;
    if (orderTexture == null || _orderAllocHeight < neededRows) {
      _orderAllocHeight = (neededRows * 5) ~/ 4 + 1;
      orderTexture = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        GsConst.splatsPerRow,
        _orderAllocHeight,
        enableRenderTargetUsage: false,
      );
    }

    final totalTexels = _orderAllocHeight * GsConst.splatsPerRow;
    final neededBytes = totalTexels * 4;
    final scratch = _ensureOrderScratch(neededBytes);
    Uint32List.view(scratch.buffer)
      ..fillRange(0, totalTexels, 0)
      ..setRange(0, indices.length, indices);
    orderTexture!.overwrite(scratch.buffer.asByteData(0, neededBytes));
  }

  /// Releases Dart-side staging buffers. Native texture lifetime is owned by
  /// the underlying flutter_gpu handles.
  void dispose() {
    atlas = null;
    orderTexture = null;
    quatTexture = null;
    colorTexture = null;
    shTexture = null;
    splatCount = 0;
    _atlasHeight = 0;
    _sidecarHeight = 0;
    _shHeight = 0;
    _orderAllocHeight = 0;
    _atlasScratch = null;
    _quatScratch = null;
    _colorScratch = null;
    _shScratch = null;
    _orderScratch = null;
  }

  Uint8List _ensureAtlasScratch(int neededBytes) {
    final scratch = _atlasScratch;
    if (scratch != null && scratch.lengthInBytes >= neededBytes) {
      return scratch;
    }
    return _atlasScratch = Uint8List(neededBytes);
  }

  Uint8List _ensureOrderScratch(int neededBytes) {
    final scratch = _orderScratch;
    if (scratch != null && scratch.lengthInBytes >= neededBytes) {
      return scratch;
    }
    return _orderScratch = Uint8List(neededBytes);
  }

  Uint8List _ensureQuatScratch(int neededBytes) {
    final scratch = _quatScratch;
    if (scratch != null && scratch.lengthInBytes >= neededBytes) {
      return scratch;
    }
    return _quatScratch = Uint8List(neededBytes);
  }

  Uint8List _ensureColorScratch(int neededBytes) {
    final scratch = _colorScratch;
    if (scratch != null && scratch.lengthInBytes >= neededBytes) {
      return scratch;
    }
    return _colorScratch = Uint8List(neededBytes);
  }

  Uint8List _ensureShScratch(int neededBytes) {
    final scratch = _shScratch;
    if (scratch != null && scratch.lengthInBytes >= neededBytes) {
      return scratch;
    }
    return _shScratch = Uint8List(neededBytes);
  }
}
