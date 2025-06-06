import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

/// Represents a camera for Gaussian Splatting rendering.
///
/// Contains both intrinsic parameters (focal lengths, image dimensions)
/// and extrinsic parameters (position, rotation) needed for proper
/// 3D scene rendering.
@immutable
class GaussianCamera {
  /// Creates a new [GaussianCamera] with the specified parameters.
  ///
  /// All parameters are required to ensure proper camera configuration.
  const GaussianCamera({
    required this.id,
    required this.width,
    required this.height,
    required this.position,
    required this.rotation,
    required this.fx,
    required this.fy,
  });

  /// Creates a default camera with reasonable FOV-based parameters.
  ///
  /// This factory constructor provides sensible defaults for most use cases:
  /// - Square pixels (fx = fy)
  /// - Camera positioned at (0, 0, -3.5) looking down -Z axis
  /// - Identity rotation matrix
  ///
  /// Parameters:
  /// - [width]: Image width in pixels
  /// - [height]: Image height in pixels
  /// - [horizontalFovDegrees]: Horizontal field of view in deg (default: 45°)
  /// - [position]: Camera position in world space (default: (0, 0, -3.5))
  /// - [rotation]: Camera rotation matrix (default: identity)
  /// - [id]: Camera identifier (default: 0)
  factory GaussianCamera.createDefault({
    required double width,
    required double height,
    double horizontalFovDegrees = 45.0,
    Vector3? position,
    Matrix3? rotation,
    int id = 0,
  }) {
    final fx = _focalPixels(width, horizontalFovDegrees);
    final fy = fx; // Square pixels - keep them equal

    return GaussianCamera(
      id: id,
      width: width.toInt(),
      height: height.toInt(),
      position: position ?? Vector3(0, 0, -2),
      rotation: rotation ?? Matrix3.identity(),
      fx: fx,
      fy: fy,
    );
  }

  /// Unique identifier for this camera.
  final int id;

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// 3D position of the camera in world coordinates.
  final Vector3 position;

  /// 3x3 rotation matrix representing camera orientation.
  final Matrix3 rotation;

  /// Focal length in pixels along the x-axis.
  final double fx;

  /// Focal length in pixels along the y-axis.
  final double fy;

  /// Calculates focal length in pixels for given width and horizontal FOV.
  ///
  /// Parameters:
  /// - [width]: Image width in pixels
  /// - [fovDeg]: Horizontal field of view in degrees
  ///
  /// Returns the focal length that produces the specified FOV.
  static double _focalPixels(double width, double fovDeg) =>
      (width / 2) / math.tan(math.pi * fovDeg / 360.0);

  /// Creates a new camera with updated dimensions while preserving FOV.
  ///
  /// This method maintains the current horizontal field of view when
  /// changing the viewport dimensions, recalculating focal lengths accordingly.
  ///
  /// Parameters:
  /// - [newWidth]: New image width in pixels
  /// - [newHeight]: New image height in pixels
  ///
  /// Returns a new [GaussianCamera] with updated dimensions.
  GaussianCamera withUpdatedViewport({
    required double newWidth,
    required double newHeight,
  }) {
    // Calculate current horizontal FOV
    final currentHorizontalFov =
        2 * math.atan((width / 2) / fx) * (180 / math.pi);

    // Calculate new focal lengths based on preserved FOV
    final newFx = _focalPixels(newWidth, currentHorizontalFov);
    final newFy = newFx; // Keep square pixels

    return GaussianCamera(
      id: id,
      width: newWidth.toInt(),
      height: newHeight.toInt(),
      position: position,
      rotation: rotation,
      fx: newFx,
      fy: newFy,
    );
  }

  /// Creates a new camera with updated pos and rot.
  ///
  /// Parameters:
  /// - [position]: New image width in pixels
  /// - [rotation]: New image height in pixels
  GaussianCamera withUpdatedPosAndRot({
    required Vector3 position,
    required Matrix3 rotation,
  }) {
    return GaussianCamera(
      id: id,
      width: width,
      height: height,
      position: position,
      rotation: rotation,
      fx: fx,
      fy: fy,
    );
  }

  /// Gets the current horizontal field of view in degrees.
  double get horizontalFovDegrees =>
      2 * math.atan((width / 2) / fx) * (180 / math.pi);

  /// Gets the current vertical field of view in degrees.
  double get verticalFovDegrees =>
      2 * math.atan((height / 2) / fy) * (180 / math.pi);

  @override
  String toString() {
    return 'GaussianCamera(id: $id, position: $position)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! GaussianCamera) return false;
    
    return id == other.id &&
        width == other.width &&
        height == other.height &&
        position == other.position &&
        rotation == other.rotation &&
        fx == other.fx &&
        fy == other.fy;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      width,
      height,
      position,
      rotation,
      fx,
      fy,
    );
  }
}
