import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

/// Calculate packed covariance entries for a single Gaussian splat.
///
/// Takes linear scale values and byte-encoded quaternion components,
/// returning three packed integers suitable for GPU texture upload.
///
/// Parameters:
/// - [scaleX], [scaleY], [scaleZ]: Linear scale values (already exp(scale_*))
/// - [q0Byte], [q1Byte], [q2Byte], [q3Byte]: Quaternion components in 0-255
/// encoding
///
/// Returns three [int] values that should be reinterpreted as floats
/// before uploading to an RGBA32F texture.
List<int> packedCovariance({
  required double scaleX,
  required double scaleY,
  required double scaleZ,
  required int q0Byte,
  required int q1Byte,
  required int q2Byte,
  required int q3Byte,
}) {
  // Decode quaternion bytes to normalized Quaternion
  final quat = _decodeQuaternion(q0Byte, q1Byte, q2Byte, q3Byte);

  // Build rotation matrix from quaternion
  final rotMat = quat.asRotationMatrix();

  // Scale rows: M = diag(scale) · R
  final scale = Vector3(scaleX, scaleY, scaleZ);
  final M = Matrix3.columns(
    rotMat.getColumn(0)..scale(scale.x),
    rotMat.getColumn(1)..scale(scale.y),
    rotMat.getColumn(2)..scale(scale.z),
  );

  // Calculate covariance: Σ = M · M^T and multiply by 4 (spec requirement)
  final sigma = (M * M.transposed()) as Matrix3;

  final s00 = 4 * sigma.entry(0, 0);
  final s01 = 4 * sigma.entry(0, 1);
  final s02 = 4 * sigma.entry(0, 2);
  final s11 = 4 * sigma.entry(1, 1);
  final s12 = 4 * sigma.entry(1, 2);
  final s22 = 4 * sigma.entry(2, 2);

  // Pack two half-floats per 32-bit word
  return [
    _packHalf2x16(s00, s01),
    _packHalf2x16(s02, s11),
    _packHalf2x16(s12, s22),
  ];
}

/// Reinterpret the bit pattern of a 32-bit int as a 32-bit float.
///
/// This is used to convert packed integer representations back to
/// float values for GPU upload.
double intBitsToFloat(int bits) {
  final tmp = Uint32List(1)..[0] = bits;
  return Float32List.view(tmp.buffer)[0];
}

/// Decode quaternion from byte-encoded components.
///
/// Maps 0-255 byte values to -1 to 1 range and normalizes the result.
Quaternion _decodeQuaternion(
  int q0Byte,
  int q1Byte,
  int q2Byte,
  int q3Byte,
) {
  final w = (q0Byte - 128) / 128.0;
  final x = (q1Byte - 128) / 128.0;
  final y = (q2Byte - 128) / 128.0;
  final z = (q3Byte - 128) / 128.0;

  final len = math.sqrt(w * w + x * x + y * y + z * z);
  if (len == 0) return Quaternion.identity();

  return Quaternion(x / len, y / len, z / len, w / len);
}

final Float32List _floatView = Float32List(1);
final Uint32List _intView = Uint32List.view(_floatView.buffer);

/// Convert a 32-bit float to 16-bit half-float representation.
///
/// Matches the JavaScript floatToHalf implementation exactly for
/// cross-platform compatibility.
int _floatToHalf(double f) {
  _floatView[0] = f;
  final v = _intView[0];

  final sign = (v >> 31) & 0x0001;
  final exp = (v >> 23) & 0x00ff;
  var frac = v & 0x007fffff;

  int newExp;
  if (exp == 0) {
    newExp = 0;
  } else if (exp < 113) {
    newExp = 0;
    frac |= 0x00800000;
    frac = frac >> (113 - exp);
    if ((frac & 0x01000000) != 0) {
      newExp = 1;
      frac = 0;
    }
  } else if (exp < 142) {
    newExp = exp - 112;
  } else {
    newExp = 31;
    frac = 0;
  }

  return (sign << 15) | (newExp << 10) | (frac >> 13);
}

/// Pack two 16-bit half-floats into a single 32-bit integer.
///
/// Matches the JavaScript packHalf2x16 implementation for
/// cross-platform compatibility.
int _packHalf2x16(double a, double b) {
  final packed = _floatToHalf(a) | (_floatToHalf(b) << 16);
  return packed & 0xffffffff; // Ensure 32-bit unsigned result
}
