# Migration Plan: flutter_gpu Backend

**Branch:** `performance-opti` (reused — platform-view MVP gets dropped in Phase 0)
**Goal:** Replace the per-platform rendering strategy with a platform-agnostic
`flutter_gpu` (Impeller HAL) backend, while keeping the existing flutter_angle
renderer as a fallback for platforms where Impeller isn't available yet
(web, unflagged Windows/Linux desktop).

**Verified against:** Flutter 3.44.1 stable (flutter_gpu ships in
`bin/cache/pkg/flutter_gpu`), flutter_gpu_shaders 0.5.0, flutter_scene 0.16.0
as the reference implementation for flutter_gpu best practices.

---

## Why (recap of the reevaluation)

1. The platform-view/CAMetalLayer MVP is a dead end as the *main* architecture:
   Flutter Windows has no platform views, web neither, hybrid composition adds
   raster↔platform thread sync, and it needs per-platform native code forever.
2. The "94.7% compositor blit" profiler finding was partly an artifact:
   the render target is created at **logical** resolution (dpr bug, see Phase 0),
   so the splat pass was measured at ¼ of the screen pixels on retina while the
   compositor ran at full resolution.
3. The blit *is* genuinely overpriced today: IOSurface external textures lose
   lossless framebuffer compression on Apple GPUs, the fullscreen draw is
   blended (`alpha: true`), and flutter_angle awaits a `textureFrameAvailable`
   method-channel round trip **every frame**.
4. flutter_gpu renders into an Impeller-private texture composited via
   `texture.asImage()` inside the normal scene pass — no IOSurface, no GL↔Metal
   sync, no per-frame channel hop, no platform folders. One Dart codebase, one
   GLSL source compiled by `impellerc` to Metal/Vulkan/GLES at build time.

Target architecture:

```
                 ┌────────────────────────────────────────────┐
                 │            GaussianSplatterWidget           │
                 │  (camera, gestures, ticker, stats overlay)  │
                 └──────────────┬─────────────────────────────┘
                                │ SplatRenderer (interface)
              ┌─────────────────┴──────────────────┐
              │                                    │
   FlutterGpuSplatRenderer              AngleSplatRenderer (existing code)
   iOS / Android / flagged desktop      web, unflagged Windows/Linux
   gpu.Texture → asImage() → Canvas     FlutterAngleTexture → Texture(id)
              │                                    │
              └────────── shared: FileProcessor, DepthSorter (isolate),
                          Camera, GsConst, splat data layout
```

---

## Phase 0 — Clean branch + backend-agnostic fixes

These fixes improve *both* backends and produce an honest profiling baseline.
Do them first and commit each separately.

### 0.1 Archive and drop the platform-view MVP

The MVP was never committed — archive it to a side branch so the
darwin benchmark reference isn't lost, then clean `performance-opti`:

- [ ] `git checkout -b platform-view-mvp-archive && git add -A && git commit -m "archive: CAMetalLayer platform view MVP (darwin benchmark reference)"`
- [ ] `git checkout performance-opti`
- [ ] `git restore example/lib/main.dart pubspec.yaml`
- [ ] `rm -rf darwin/ lib/renderer/platform_view_renderer.dart lib/widgets/gaussian_splatter_platform_view_widget.dart`
- [ ] Verify `flutter analyze` and the example still build/run (texture path).

### 0.2 Fix the dpr bug (correctness + truthful profiles)

`lib/widgets/gaussian_splatter_widget.dart` captures `dpr` in the
`LayoutBuilder` but `initPlatformState` ignores it: the render target and
camera are created at **logical** size (`AngleOptions(dpr: 1)` is also
hardcoded in `lib/renderer/renderer.dart`). Output is blurry on every
retina/mobile display.

- [ ] In `initPlatformState` / `resize`, compute physical size:
      `final renderSize = Size(validSize.width * dpr, validSize.height * dpr);`
      and build the `Camera` + `setupTexture` with the physical size.
- [ ] Snap to integers (`.roundToDouble()`) to avoid texture/layout drift.
- [ ] Verify gestures still feel correct (they operate on deltas, but confirm
      orbit speed isn't scaled by dpr; divide deltas by dpr if needed).
- [ ] Re-run on a retina display: image should be visibly sharper.

### 0.3 Stop copying the splat buffer to the sort isolate every frame

`lib/sorting/depth_sorter.dart` — `runSort` currently `SendPort.send`s the
entire `Uint8List` per frame; isolate sends copy, so this memcpys the whole
model (16 MB at 500K splats) on the UI thread at up to 60 Hz.

- [ ] Add a `_SetDataRequest(buffer, vertexCount)` message; send it **once**
      from `setSplatData`. The isolate caches the buffer (and can pre-extract
      a `Float32List` of positions: 12 B/splat instead of 128 B/splat).
- [ ] `_SortRequest` then carries only the 16 matrix doubles.
- [ ] Remove boxed-list churn:
      - isolate result: replace `Uint32List.fromList(out.take(n).toList())`
        with `out.sublist(0, n)` (typed copy, no boxing);
      - `renderer.dart` `onSortComplete`: stop calling `result.depthIndex.toList()`;
        change `OrderTexture.uploadFull` to accept `Uint32List` directly and
        blit it with `setRange`/typed views instead of an element loop.

### 0.4 Sort on demand instead of every frame

`Renderer.frame()` calls `runSort` unconditionally. Standard 3DGS practice:

- [ ] Keep the last-sorted view direction (3rd row of the view matrix).
      Re-sort only when `dot(currentDir, lastSortedDir) < ~0.999` or the
      camera position moved past a threshold, or data/viewport changed.
- [ ] Add an `_sortInFlight` flag so requests don't pile up in the isolate
      queue; coalesce to "latest wins".

### 0.5 Record a new baseline

- [ ] Xcode GPU capture of the example (macOS + iPhone) at native resolution.
      Record: total GPU ms, splat-pass ms, compositor-pass ms, CPU frame ms.
      Put the numbers in a `BENCHMARKS.md` table — Phase 3 compares against this.

---

## Phase 1 — Extract a renderer interface

Abstract at the **whole-renderer** level, not at the GL-call level — the
existing flutter_angle code stays untouched as the fallback backend.

### 1.1 Interface

- [ ] New file `lib/renderer/splat_renderer.dart`:

```dart
abstract interface class SplatRenderer {
  Future<void> initialize({bool debug});
  Future<void> setup({required int width, required int height,
                      bool enableProfiling});
  Future<bool> resize(Camera nextCamera);
  Future<void> setSplatData(Uint8List data);
  Camera? get camera;
  set camera(Camera? value);
  Future<void> frame();
  RenderStats get renderStats;
  /// Widget that displays the renderer output (Texture vs RawImage).
  Widget buildOutput(BuildContext context, {required Size logicalSize});
  void dispose();
}
```

- [ ] Rename the existing `Renderer` → `AngleSplatRenderer` (keep a
      `@Deprecated` typedef `Renderer` for API compat) and make it implement
      the interface. Its `buildOutput` returns the existing
      `Texture(textureId: ...)` widget.
- [ ] Move ticker/render-loop driving fully into the widget (it mostly is
      already) so both backends are driven identically.
- [ ] Background/sky: add `Future<void> enableBackgroundFromAsset(String)` to
      the interface but allow `UnimplementedError` in the gpu backend for the
      MVP (see Phase 2.6).

### 1.2 Backend selection

- [ ] `lib/renderer/backend_selector.dart`:

```dart
enum SplatBackend { auto, flutterGpu, angle }

SplatRenderer createRenderer(SplatBackend choice) {
  switch (choice) {
    case SplatBackend.flutterGpu: return FlutterGpuSplatRenderer();
    case SplatBackend.angle:      return AngleSplatRenderer();
    case SplatBackend.auto:
      if (kIsWeb) return AngleSplatRenderer();
      try {
        // Throws if Impeller is unavailable (e.g. desktop without the flag).
        gpu.gpuContext;
        return FlutterGpuSplatRenderer();
      } catch (_) {
        return AngleSplatRenderer();
      }
  }
}
```

- [ ] Expose `backend:` parameter on `GaussianSplatterWidget`
      (default `SplatBackend.auto`).
- [ ] Commit: widget + example run unchanged via the angle backend.

---

## Phase 2 — flutter_gpu backend

### 2.1 Dependencies & scaffolding

- [ ] `pubspec.yaml`:

```yaml
environment:
  flutter: ">=3.44.0"   # flutter_gpu in stable + build hooks

dependencies:
  flutter_gpu:
    sdk: flutter
  flutter_gpu_shaders: ^0.5.0

flutter:
  assets:
    - shaders/                                              # GLSL for angle path
    - build/shaderbundles/flutter_gaussian_splatter.shaderbundle
```

- [ ] `hook/build.dart`:

```dart
import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'flutter_gaussian_splatter.shaderbundle.json',
    );
  });
}
```

  (Match the exact hook API of flutter_gpu_shaders 0.5.0 — copy from its
  README/example; the package was updated days ago, so prefer its docs over
  older blog posts.)

- [ ] `flutter_gaussian_splatter.shaderbundle.json` at package root:

```json
{
  "SplatVertex":   { "type": "vertex",   "file": "shaders/gpu/splat.vert" },
  "SplatFragment": { "type": "fragment", "file": "shaders/gpu/splat.frag" }
}
```

- [ ] Example app: enable Impeller on macOS (still opt-in on stable 3.44):
      `example/macos/Runner/Info.plist` → `FLTEnableImpeller` = `true`.
      iOS and Android (API 29+) are Impeller by default — nothing to do.

### 2.2 Shader port — `shaders/gpu/splat.vert`

impellerc dialect notes (this is GLSL 4.60-flavored, compiled to
SPIR-V → MSL / GLSL ES):

- **No `#version` directive, no `precision` statements** — impellerc handles it.
- Loose uniforms are not allowed: scalars/matrices go in a **uniform block**;
  samplers stay as standalone `uniform sampler2D`.
- `texelFetch` is core GLSL and is the numerically safest way to read the
  RGBA32F atlas (raw bits, no filtering — required because texels carry
  `floatBitsToUint`-packed words). Use it first; if a backend rejects it,
  fall back to `texture()` with a nearest sampler + half-texel-centered UVs,
  the pattern flutter_scene's `flutter_scene_skinned.vert` uses for its
  joints texture (proves vertex-stage texture reads work on all backends).
- `gl_VertexID` replaces both `gl_InstanceID` and the `position` attribute
  (stable flutter_gpu has **no instancing** — master does; see Phase 4).

Structure:

```glsl
// splat.vert (impellerc dialect)
uniform FrameInfo {
  mat4 projection;
  mat4 view;
  vec2 focal;
  vec2 viewport;
  float splat_count;     // float to keep std140 layout trivial
  float max_splat_size;
} frame_info;

uniform sampler2D u_texture;        // RGBA32F splat atlas, 5 texels/splat
uniform sampler2D u_order_texture;  // RGBA8, 4 bytes = uint32 LE index

out vec4 v_color;
out vec2 v_position;

void main() {
  // Vertex pulling: 6 vertices per splat, no vertex attributes at all.
  int order_idx = gl_VertexID / 6;
  int corner_id = gl_VertexID - order_idx * 6;       // 0..5
  // Triangle list {0,1,2, 0,2,3} over corners (-1,-1)(1,-1)(1,1)(-1,1):
  const vec2 corners[6] = vec2[6](
    vec2(-1.,-1.), vec2(1.,-1.), vec2(1.,1.),
    vec2(-1.,-1.), vec2(1.,1.),  vec2(-1.,1.));
  vec2 corner_uv = corners[corner_id];

  // Order lookup: RGBA8 texel -> uint32 (little endian), exact integer math.
  ivec2 order_texel = ivec2(order_idx & 0x1ff, order_idx >> 9);
  uvec4 ob = uvec4(texelFetch(u_order_texture, order_texel, 0) * 255.0 + 0.5);
  int idx = int(ob.r | (ob.g << 8u) | (ob.b << 16u) | (ob.a << 24u));

  // ... from here on: port the existing vertex.glsl body verbatim
  // (texelFetch P0/P1/SH from u_texture, covariance, culling, SH eval).
  // Culled splats keep using gl_Position = vec4(0., 0., 2., 1.);
  // (z > w clips in both GL [-1,1] and Metal/Vulkan [0,1] conventions).
}
```

Port checklist:

- [ ] Copy the helper functions (`unpackHalf2x16_from_uint`, `unpack8888s`,
      `decodeQuaternion`, `readSHData_reference`, `evalSH_reference`,
      `quatToMat3`, `clipCorner`) unchanged — all core GLSL.
- [ ] Replace the `USE_INTEGER_TEXTURE` ifdef + `usampler2D` order path with
      the RGBA8 decode above (flutter_gpu exposes **no integer pixel
      formats**, so R32UI is gone; RGBA8 keeps the upload at 4 B/splat).
- [ ] Replace `uniform mat4 projection, view; uniform vec2 focal; ...` with
      the `FrameInfo` block (`int splatCount` → `float` + `int(...)` cast,
      avoids std140 surprises).
- [ ] Drop the `position` attribute and `splatsPerInstance` batching logic
      (`GsConst.splatsPerInstance` becomes unused in this backend).
- [ ] `shaders/gpu/splat.frag`: port `frag.glsl` — remove `#version`/
      `precision`, keep the Schraudolph `intBitsToFloat` fastExp (compiles to
      `as_type` on MSL; keep the `exp2` variant commented as fallback),
      premultiplied output unchanged.

**Calibration step (expect one iteration):** Impeller normalizes clip-space
across backends, but render-to-texture Y orientation differs from the GL
path (the angle path already flips per platform via `ndcYSign`). Bring up
with an asymmetric test scene and fix orientation **once** in the projection
(`Camera.createDefault(ndcYSign: ...)`) for the gpu backend — it should then
be identical on iOS/Android/macOS since Impeller abstracts the difference.

### 2.3 Data upload — `lib/renderer/gpu/gpu_splat_source.dart`

- [ ] Splat atlas: `gpu.gpuContext.createTexture(StorageMode.hostVisible,
      GsConst.texWidth, rows, format: PixelFormat.r32g32b32a32Float)`
      — **hostVisible is required**: `Texture.overwrite` only works on
      host-visible textures. Reuse the existing 5-texel packing code from
      `lib/data/splat_source.dart` (the `ByteData` it produces uploads as-is).
- [ ] Order texture: `PixelFormat.r8g8b8a8UNormInt`, width 512,
      `rows = ceil(splatCount / 512)`. Upload = wrap the sorter's
      `Uint32List` as bytes: `sortedIndices.buffer.asByteData(...)` —
      zero conversion, little-endian matches the shader decode.
      Reallocate-with-headroom logic carries over from `OrderTexture`.
- [ ] Both textures use a **nearest** `SamplerOptions` when bound (defaults
      are already nearest — pass explicitly anyway for clarity).

### 2.4 Renderer — `lib/renderer/gpu/flutter_gpu_splat_renderer.dart`

Per-frame skeleton (stable 3.44 API — verified signatures):

```dart
import 'package:flutter_gpu/gpu.dart' as gpu;

class FlutterGpuSplatRenderer implements SplatRenderer {
  late final gpu.RenderPipeline _pipeline;
  late gpu.Texture _target;          // devicePrivate, r8g8b8a8UNormInt
  late final gpu.HostBuffer _frameUniforms;
  late final gpu.DeviceBuffer _dummyVertex; // 16 bytes, see note below
  ui.Image? _lastFrame;

  Future<void> setup(...) async {
    final library = gpu.ShaderLibrary.fromAsset(
      'packages/flutter_gaussian_splatter/build/shaderbundles/'
      'flutter_gaussian_splatter.shaderbundle')!;
    _pipeline = gpu.gpuContext.createRenderPipeline(
      library['SplatVertex']!, library['SplatFragment']!);
    _target = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate, widthPx, heightPx);
    _frameUniforms = gpu.gpuContext.createHostBuffer();
  }

  Future<void> frame() async {
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final pass = commandBuffer.createRenderPass(gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: _target,
        clearValue: vm.Vector4(0, 0, 0, 0))));  // premult transparent

    pass
      ..bindPipeline(_pipeline)
      ..setColorBlendEnable(true)
      ..setColorBlendEquation(gpu.ColorBlendEquation())  // defaults ==
        // src ONE / dst ONE_MINUS_SRC_ALPHA for color and alpha: exactly
        // the premultiplied blend the angle path configures manually.
      ..setCullMode(gpu.CullMode.none);

    final frameInfo = _frameUniforms.emplace(_packFrameInfo()); // 168 B UBO
    pass.bindUniform(_pipeline.vertexShader.getUniformSlot('FrameInfo'),
        frameInfo);
    pass.bindTexture(_pipeline.vertexShader.getUniformSlot('u_texture'),
        _source.atlas);
    pass.bindTexture(_pipeline.vertexShader.getUniformSlot('u_order_texture'),
        _source.orderTexture);

    // Stable flutter_gpu takes the vertex count from bindVertexBuffer.
    // The shader reads no attributes (pure gl_VertexID pulling), so bind a
    // tiny dummy buffer purely to convey the count:
    pass.bindVertexBuffer(
        gpu.BufferView(_dummyVertex, offsetInBytes: 0, lengthInBytes: 16),
        splatCount * 6);
    pass.draw();

    commandBuffer.submit();
    _lastFrame = _target.asImage();
    _notifyRepaint();
  }
}
```

- [ ] **Risk checkpoint (do this first as a spike):** confirm a pipeline whose
      vertex shader declares **zero `in` attributes** is accepted, and that
      `gl_VertexID` works through impellerc. flutter_scene always binds a real
      `position` attribute, so this exact combination is unproven.
      **Fallback if rejected:** keep a real `in float a_vertex_id;` attribute
      fed by a static `Float32List(maxSplats * 6)` filled with `0..n`
      (12 MB @ 500K splats — works, ugly), or batch like today: a static
      4096-splat corner buffer + one `draw()` per batch with a per-batch
      `base_index` uniform emplaced into the `HostBuffer` (≈ 30–125 draws per
      frame, cheap to encode). Pick whichever profiles better; delete when
      instancing reaches stable (Phase 4).
- [ ] Resize: recreate `_target` (devicePrivate textures can't be resized).
- [ ] No `glFlush`/`glFinish`/method-channel equivalents — `submit()` +
      `asImage()` is the entire present path.
- [ ] `renderStats`: keep the CPU profiler; flutter_gpu has no GPU timestamp
      queries yet — note `profilerType: 'CPU'` for this backend. DevTools /
      Xcode captures are now meaningful end-to-end since everything is one
      Impeller frame.

### 2.5 Output widget

- [ ] `buildOutput` returns a `RawImage`/custom `LeafRenderObjectWidget`
      painting `_lastFrame` at the logical size (image is physical-px sized;
      paint with `FilterQuality.none` — it's a 1:1 mapping, no resampling).
- [ ] Call `_lastFrame.dispose()` when replacing (each `asImage()` returns a
      new wrapper; don't leak them).
- [ ] Hook `_notifyRepaint` into the existing ticker/`_requestRender` flow.

### 2.6 Sky/background pass — defer

- [ ] MVP: `enableBackgroundFromAsset` throws `UnimplementedError` on the gpu
      backend; document it. (The splat output is premultiplied-alpha, so any
      Flutter widget can sit behind it — static backgrounds work for free.)
- [ ] Follow-up: port `SkyPass` (equirect sample, fullscreen triangle —
      ~50-line vert/frag pair, same bundle).

---

## Phase 3 — Validation & benchmarking

- [ ] **Visual parity:** same scene + camera on both backends, screenshot,
      diff. Expect tiny LSB differences (fastExp, fp contraction), nothing
      structural. Check: orientation (no mirror/flip!), SH view-dependence,
      alpha edges against a colored background.
- [ ] **Lifecycle:** resize loop, dispose/recreate, backgrounding (Metal
      drawable loss), hot reload.
- [ ] **Performance** (fill into `BENCHMARKS.md`, compare Phase 0.5 baseline):
  - macOS Xcode capture: the IOSurface external-texture sampling draw must be
    gone; splat pass appears inside the Impeller frame.
  - iPhone: Metal capture + 120 Hz ProMotion check.
  - Android: one Vulkan device + one GLES-fallback device
    (`adb shell dumpsys SurfaceFlinger` / `flutter run --trace-skia`-era
    tooling is gone — use DevTools raster stats + Android GPU Inspector).
  - Optional: check out `platform-view-mvp-archive` and benchmark the darwin
    platform view as the "theoretical max" reference point.
- [ ] **Fallback matrix:** web (angle/WebGL must still work), macOS without
      `FLTEnableImpeller` (auto-select must pick angle), Windows if available.

---

## Phase 4 — Rollout & future upgrades

- [ ] README: platform/backend matrix, Impeller flag instructions for desktop,
      "experimental backend" caveat. CHANGELOG. Version `0.4.0`.
- [ ] Keep `SplatBackend.angle` override documented as the escape hatch.
- [ ] **Watch flutter_gpu on stable** (both already on master):
  - `draw(instanceCount:)` + `VertexStepMode.instance` → replace vertex
    pulling/dummy buffer with a per-instance order-index attribute
    (removes one indirection fetch per vertex and the spike fallback).
  - Compute shaders → move the radix sort to GPU, delete the isolate.
- [ ] When Impeller becomes default on desktop, demote flutter_angle to
      web-only; long term, a WebGPU flutter_gpu backend may retire it fully.

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Zero-attribute pipeline / `gl_VertexID` rejected by impellerc or a backend | medium | Spike first (Phase 2.4); two documented fallbacks |
| `texelFetch` unsupported in vertex stage on some backend | low | `texture()` + nearest + texel-center UVs (flutter_scene pattern) |
| NaN bit-patterns in RGBA32F atlas mangled by sampling | low (texelFetch returns raw bits; angle path already does this) | If artifacts: move packed words to an RGBA8 side texture |
| Y-flip / handedness differences vs angle path | high (expected, one-time) | Calibration step in 2.2 with asymmetric scene |
| flutter_gpu API breaks on Flutter upgrade | medium | It's SDK-pinned: breaks = compile errors, fix is mechanical; pin CI to a known Flutter version |
| `ShaderLibrary.fromAsset` asset path differs for package (vs app) context | medium | Verify `packages/flutter_gaussian_splatter/...` prefix early in 2.4 spike |
| macOS users forget the Impeller flag | certain | `auto` backend falls back to angle + debug-print explaining why |

## Verified API cheat sheet (stable 3.44.1)

```
gpu.gpuContext                                  // singleton, throws if no Impeller
ctx.createTexture(StorageMode, w, h, {format})  // hostVisible needed for overwrite()
ctx.createDeviceBuffer / createDeviceBufferWithCopy / createHostBuffer
ctx.createCommandBuffer / createRenderPipeline(vert, frag)
gpu.ShaderLibrary.fromAsset(path)['ShaderName']
Texture.overwrite(ByteData) / Texture.asImage() -> ui.Image
HostBuffer.emplace(ByteData) -> BufferView      // auto-aligned UBO suballocation
RenderPass: bindPipeline, bindVertexBuffer(view, vertexCount),
  bindIndexBuffer(view, IndexType, indexCount), bindUniform(slot, view),
  bindTexture(slot, texture, {sampler}), setColorBlendEnable,
  setColorBlendEquation(ColorBlendEquation()),  // defaults = premultiplied
  setCullMode, draw()                           // NO instanceCount on stable
PixelFormat: r8g8b8a8UNormInt, r32g32b32a32Float, r16g16b16a16Float, ...
             (NO integer formats — hence RGBA8-encoded order indices)
IndexType: int16, int32
```
