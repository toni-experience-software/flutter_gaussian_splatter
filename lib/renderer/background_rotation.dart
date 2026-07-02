import 'dart:math' as math;
import 'dart:typed_data';

/// Builds a yaw/pitch background rotation as a column-major 3x3 matrix.
///
/// Positive [yawDeg] rotates to the right around the Y axis; positive
/// [pitchDeg] rotates upward around the X axis. Shared by every backend so the
/// sky orientation cannot drift between them.
Float32List backgroundRotation3x3(double yawDeg, double pitchDeg) {
  final y = yawDeg * math.pi / 180.0;
  final p = pitchDeg * math.pi / 180.0;
  final cy = math.cos(y);
  final sy = math.sin(y);
  final cp = math.cos(p);
  final sp = math.sin(p);

  return Float32List.fromList(<double>[
    cy,
    sy * sp,
    sy * cp,
    0,
    cp,
    -sp,
    -sy,
    cy * sp,
    cy * cp,
  ]);
}

/// Default background orientation applied after a background is enabled.
///
/// Historically the ANGLE backend pitched the sky by 90° right after init;
/// hoisting it here keeps both backends visually identical.
const double defaultBackgroundYawDegrees = 90;

/// Default background pitch (degrees).
const double defaultBackgroundPitchDegrees = 0;
