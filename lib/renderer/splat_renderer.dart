import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_gaussian_splatter/camera/camera.dart';
import 'package:flutter_gaussian_splatter/perf/render_stats.dart';

/// Backend-independent renderer contract for Gaussian splat output.
abstract interface class SplatRenderer {
  /// Initializes backend resources that are independent of viewport size.
  Future<void> initialize({bool debug});

  /// Creates render targets and shaders for a physical-pixel viewport.
  Future<void> setup({
    required int width,
    required int height,
    bool enableProfiling,
  });

  /// Resizes the render target and applies [nextCamera].
  Future<bool> resize(Camera nextCamera);

  /// Uploads raw processed splat data.
  Future<void> setSplatData(Uint8List data);

  /// Whether a morph transition is currently active.
  bool get isMorphing;

  /// Begins a morph from the currently displayed splats toward [targetData]
  /// (standard 128-byte layout).
  ///
  /// When [buildCorrespondence] is true the two sets are matched spatially and
  /// by color, and unmatched splats fade/scale in or out. When false the target
  /// must have the same splat count as the current data and is treated as a
  /// row-aligned 1:1 mapping (each splat flies to the same-index target).
  ///
  /// When [indexMatch] is true the two sets are paired purely by index
  /// (`A[i]` ↔ `B[i]`) with no spatial matching, and the larger set's surplus
  /// fades/scales in or out. It overrides [buildCorrespondence].
  ///
  /// When [mortonMatch] is true both clouds are sorted along a Morton (Z-order)
  /// curve and paired by spatial rank, so the source coherently flows into the
  /// target shape. It overrides [indexMatch] and [buildCorrespondence].
  ///
  /// Drive the transition with [setMorphProgress] and end it with [clearMorph].
  Future<void> startMorph(
    Uint8List targetData, {
    bool buildCorrespondence,
    bool indexMatch,
    bool mortonMatch,
  });

  /// Sets the morph interpolation factor in `[0, 1]`. No-op unless a morph is
  /// active.
  void setMorphProgress(double t);

  /// Ends any active morph and restores the original splats.
  void clearMorph();

  /// When true, evaluate spherical harmonics per-splat every frame (highest
  /// quality). When false, use the cheaper resolve-pass approximation that
  /// evaluates SH once per splat with a single global view direction.
  bool get highQualitySH;
  set highQualitySH(bool value);

  /// NDC Y-axis sign this backend's render target expects.
  ///
  /// ANGLE's GL framebuffer and Impeller's render-to-texture have opposite
  /// vertical conventions, so each backend declares its own sign rather than
  /// the widget guessing from the platform.
  double get ndcYSign;

  /// Currently active camera.
  Camera? get camera;

  /// Updates the currently active camera.
  set camera(Camera? value);

  /// Renders one frame.
  Future<void> frame();

  /// Latest frame statistics.
  RenderStats get renderStats;

  /// Callback invoked when another frame should be scheduled.
  VoidCallback? get onNeedsRender;

  /// Called when asynchronous renderer work means another frame should render.
  set onNeedsRender(VoidCallback? callback);

  /// Enables a renderer-managed background from an asset.
  Future<void> enableBackgroundFromAsset(String assetPath);

  /// Removes the renderer-managed background, if any.
  void disableBackground();

  /// Updates renderer-managed background orientation.
  void setBackgroundRotation(double yawDegrees, double pitchDegrees);

  /// Builds the widget that displays the last rendered frame.
  Widget buildOutput(BuildContext context, {required Size logicalSize});

  /// Releases backend resources.
  void dispose();
}
