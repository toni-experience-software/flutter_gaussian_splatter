import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

/// Immutable pinhole camera used for Gaussian splatting.
///
/// Holds **intrinsics** ([fx], [fy], [width], [height]) and **extrinsics**
/// ([position], [rotation]) and can produce view/projection matrices
/// in OpenGL conventions (column-major).
@immutable
class GaussianCamera {
  /// Creates a camera with explicit intrinsics and extrinsics.
  ///
  /// - [width]/[height] are in pixels and must be > 0.
  /// - [fx]/[fy] are focal lengths in pixels and must be > 0.
  /// - [rotation] is **camera → world** (columns are right, up, forward).
  /// - [znear]/[zfar] define clip planes (OpenGL-style), `znear > 0`, `zfar > znear`.
  const GaussianCamera({
    required this.id,
    required this.width,
    required this.height,
    required this.position,
    required this.rotation,
    required this.fx,
    required this.fy,
    this.znear = 0.2,
    this.zfar = 200.0,
    this.ndcYSign = -1.0, // default for Flutter texture targets
  })  : assert(
          width > 0,
        ),
        assert(height > 0),
        assert(fx > 0),
        assert(fy > 0),
        assert(znear > 0),
        assert(zfar > znear);

  /// Creates a reasonable default camera from a horizontal FOV and image size.
  ///
  /// If [position] and [rotation] are omitted, an orbit-style pose is used.
  factory GaussianCamera.createDefault({
    required double width,
    required double height,
    required double ndcYSign,
    double horizontalFovDegrees = 45.0,
    Vector3? position,
    Matrix3? rotation,
    int id = 0,
    double znear = 0.2,
    double zfar = 200.0,
  }) {
    final fx = _focalPixels(width, horizontalFovDegrees);
    final fy = fx; // square pixels

    // Pose: either provided or derived from simple orbit parameters.
    late final Vector3 pos;
    late final Matrix3 rot;

    if (position != null && rotation != null) {
      pos = position;
      rot = rotation;
    } else {
      const orbitDistance = 2.0;
      const double theta = 0;
      const phi = math.pi / 2.0;

      final x = orbitDistance * math.sin(phi) * math.sin(theta);
      final y = orbitDistance * math.cos(phi);
      final z = orbitDistance * math.sin(phi) * math.cos(theta);
      pos = Vector3(x, y, z);

      // Camera basis: right/up/forward in world space.
      final forward = (-pos).normalized();
      final up = Vector3(0, -1, 0);
      final right = up.cross(forward).normalized();
      final trueUp = forward.cross(right).normalized();
      rot = Matrix3.columns(right, trueUp, forward);
    }

    return GaussianCamera(
      id: id,
      width: width.toInt(),
      height: height.toInt(),
      position: pos,
      rotation: rot,
      fx: fx,
      fy: fy,
      znear: znear,
      zfar: zfar,
      ndcYSign: ndcYSign,
    );
  }

  /// Unique identifier for this camera.
  final int id;

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Camera position in world space.
  final Vector3 position;

  /// Camera → world rotation (columns: right, up, forward).
  final Matrix3 rotation;

  /// Focal length in pixels along the x-axis.
  final double fx;

  /// Focal length in pixels along the y-axis.
  final double fy;

  /// Near clip plane (OpenGL space).
  final double znear;

  /// Far clip plane (OpenGL space).
  final double zfar;

  /// Sign applied to clip-space Y (and to fy for screen-space math).
  /// +1 = OpenGL default; −1 = vertically flipped (Flutter texture).
  final double ndcYSign;

  /// Column-major OpenGL projection built from intrinsics.
  /// Uses [ndcYSign] to control vertical orientation.
  Matrix4 projectionMatrix() {
    final fovX = (2 * fx) / width;
    final fovY = ndcYSign * (2 * fy) / height;
    final a = zfar / (zfar - znear);
    final b = -(zfar * znear) / (zfar - znear);

    return Matrix4(
      fovX,
      0,
      0,
      0,
      0,
      fovY,
      0,
      0,
      0,
      0,
      a,
      1,
      0,
      0,
      b,
      0,
    );
  }

  /// Returns a column-major OpenGL view matrix (world → camera).
  Matrix4 viewMatrix() {
    final R = rotation; // camera -> world
    final t = position;

    // Upper-left 3×3 = R^T; translation = -R^T * t
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

  /// Returns the 3×3 inverse view rotation (camera → world), column-major.
  ///
  /// Handy for skydome lookups.
  List<double> invViewRotation3x3() {
    final R = rotation; // already camera -> world
    return <double>[
      R.row0.x,
      R.row1.x,
      R.row2.x,
      R.row0.y,
      R.row1.y,
      R.row2.y,
      R.row0.z,
      R.row1.z,
      R.row2.z,
    ];
  }


    /// Focal for shader uniforms; 
  double focalXForShader() =>fx;
  ///Y already carries the NDC sign.
  double focalYForShader() =>fx * ndcYSign;

  /// Convenience flags
  bool get yIsFlipped => ndcYSign < 0;

  /// Creates a copy with selected fields changed.
  GaussianCamera copyWith({
    int? id,
    int? width,
    int? height,
    Vector3? position,
    Matrix3? rotation,
    double? fx,
    double? fy,
    double? znear,
    double? zfar,
    double? ndcYSign,
  }) {
    return GaussianCamera(
      id: id ?? this.id,
      width: width ?? this.width,
      height: height ?? this.height,
      position: position ?? this.position,
      rotation: rotation ?? this.rotation,
      fx: fx ?? this.fx,
      fy: fy ?? this.fy,
      znear: znear ?? this.znear,
      zfar: zfar ?? this.zfar,
      ndcYSign: ndcYSign ?? this.ndcYSign,
    );
  }

  /// Returns a new camera that preserves the current horizontal FOV
  /// while changing the viewport size.
  GaussianCamera copyWithViewport({
    required double newWidth,
    required double newHeight,
  }) {
    final currentHFovDeg = 2 * math.atan((width / 2) / fx) * (180 / math.pi);
    final newFx = _focalPixels(newWidth, currentHFovDeg);
    final newFy = newFx; // square pixels
    return copyWith(
      width: newWidth.toInt(),
      height: newHeight.toInt(),
      fx: newFx,
      fy: newFy,
      
    );
  }

  /// Returns a new camera with updated position and rotation.
  GaussianCamera copyWithPose({
    required Vector3 position,
    required Matrix3 rotation,
  }) {
    return copyWith(position: position, rotation: rotation);
  }

  /// Current horizontal field of view in degrees.
  double get horizontalFovDegrees =>
      2 * math.atan((width / 2) / fx) * (180 / math.pi);

  /// Current vertical field of view in degrees.
  double get verticalFovDegrees =>
      2 * math.atan((height / 2) / fy) * (180 / math.pi);

  @override
  String toString() => 'GaussianCamera(id: $id, pos: $position)';

  // ---- internals ----

  /// Focal length (pixels) from width and horizontal FOV (degrees).
  static double _focalPixels(double width, double fovDeg) =>
      (width / 2) / math.tan(math.pi * fovDeg / 360.0);
}
