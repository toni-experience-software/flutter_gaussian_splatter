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
  /// This factory constructor provides defaults,
  ///
  /// Parameters:
  /// - [width]: Image width in pixels
  /// - [height]: Image height in pixels
  /// - [horizontalFovDegrees]: Horizontal field of view in deg (default: 45°)
  /// - [position]: Camera position in world space (default: calculated from orbit)
  /// - [rotation]: Camera rotation matrix (default: calculated from orbit)
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

    // If position/rotation not provided, calculate using orbit camera logic
    Vector3 finalPosition;
    Matrix3 finalRotation;
    
    if (position != null && rotation != null) {
      finalPosition = position;
      finalRotation = rotation;
    } else {
      // Use same initial values as widget: distance=5, theta=0, phi=π/2
      const orbitDistance = 2.0;
      const double theta = 0;
      const phi = math.pi / 2.0;
      
      // Calculate position using spherical coordinates (matching widget)
      final x = orbitDistance * math.sin(phi) * math.sin(theta);
      final y = orbitDistance * math.cos(phi);
      final z = orbitDistance * math.sin(phi) * math.cos(theta);
      finalPosition = Vector3(x, y, z);
      
      // Calculate rotation using same logic as widget's _orbitCamera
      final forward = (-finalPosition).normalized();
      final up = Vector3(0, -1, 0);  // Match widget's up vector
      final right = up.cross(forward).normalized();
      final trueUp = forward.cross(right).normalized();
      finalRotation = Matrix3.columns(right, trueUp, forward);
    }

    return GaussianCamera(
      id: id,
      width: width.toInt(),
      height: height.toInt(),
      position: finalPosition,
      rotation: finalRotation,
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
