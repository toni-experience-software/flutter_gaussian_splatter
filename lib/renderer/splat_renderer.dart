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

  /// Updates renderer-managed background orientation.
  void setBackgroundRotation(double yawDegrees, double pitchDegrees);

  /// Builds the widget that displays the last rendered frame.
  Widget buildOutput(BuildContext context, {required Size logicalSize});

  /// Releases backend resources.
  void dispose();
}
