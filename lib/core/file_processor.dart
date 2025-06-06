import 'dart:convert';
import 'dart:developer';
import 'dart:math' as math;
import 'dart:typed_data';

/// Processes PLY files containing Gaussian splat data.
///
/// This class handles parsing PLY file headers, extracting vertex properties,
/// and converting the data into the optimized binary format required by
/// the Gaussian splat renderer. The processor also handles importance-based
/// sorting to optimize rendering performance.
class FileProcessorImpl {
  /// Output format constants
  static const int _positionFloats = 3; // x, y, z
  static const int _scaleFloats = 3; // scale_x, scale_y, scale_z
  static const int _colorBytes = 4; // r, g, b, a
  static const int _rotationBytes = 4; // quaternion as bytes
  
  /// Total number of bytes per vertex in the output format.
  /// 
  /// Consists of: position (12 bytes) + scale (12 bytes) + color (4 bytes) 
  /// + rotation (4 bytes) = 32 bytes
  static const int outputRowLength = (_positionFloats + _scaleFloats) * 4 +
      _colorBytes +
      _rotationBytes;

  /// Spherical harmonics coefficient for color conversion
  static const double _shC0 = 0.28209479177387814;

  /// Default scale value for missing scale properties
  static const double _defaultScale = 0.01;

  /// Checks if the provided data represents a valid PLY file.
  ///
  /// Verifies the PLY magic header ("ply\n") at the beginning of the file.
  ///
  /// Parameters:
  /// - [data]: Binary data to check
  ///
  /// Returns `true` if the data appears to be a PLY file.
  bool isPly(Uint8List data) {
    if (data.length < 4) return false;
    return data[0] == 112 && // 'p'
        data[1] == 108 && // 'l'
        data[2] == 121 && // 'y'
        data[3] == 10; // '\n'
  }

  /// Processes a PLY buffer into the binary format expected by the renderer.
  ///
  /// This method:
  /// 1. Parses the PLY header to extract property definitions
  /// 2. Calculates importance scores for each vertex (size × opacity)
  /// 3. Sorts vertices by importance for optimal rendering
  /// 4. Converts vertex data to the packed binary format
  ///
  /// Parameters:
  /// - [inputBuffer]: Raw PLY file data
  ///
  /// Returns processed binary data ready for GPU upload.
  /// Throws [Exception] if the PLY file cannot be parsed.
  Uint8List processPlyBuffer(Uint8List inputBuffer) {
    final headerInfo = _parseHeader(inputBuffer);
    final vertexCount = headerInfo['vertexCount'] as int;
    final offsets = headerInfo['offsets'] as Map<String, int>;
    final types = headerInfo['types'] as Map<String, String>;
    final rowSize = headerInfo['rowSize'] as int;
    final dataStart = headerInfo['dataStart'] as int;

    _validateRequiredProperties(offsets);

    final inputData = ByteData.view(inputBuffer.buffer, dataStart);
    final sortedIndices = _calculateImportanceSort(
      inputData,
      vertexCount,
      rowSize,
      offsets,
      types,
    );

    return _convertVertexData(
      inputData,
      vertexCount,
      rowSize,
      offsets,
      types,
      sortedIndices,
    );
  }

  /// Parses PLY header and extracts metadata.
  Map<String, dynamic> _parseHeader(Uint8List inputBuffer) {
    final headerSize = math.min(inputBuffer.length, 1024 * 10);
    final headerBytes = inputBuffer.sublist(0, headerSize);
    final header = utf8.decode(headerBytes, allowMalformed: true);

    const headerEnd = "end_header\n";
    final headerEndIndex = header.indexOf(headerEnd);
    if (headerEndIndex < 0) {
      throw Exception("Unable to read PLY file header");
    }

    final vertexCountMatch =
        RegExp(r'element vertex (\d+)\n').firstMatch(header);
    if (vertexCountMatch == null) {
      throw Exception("Unable to parse vertex count from PLY header");
    }
    final vertexCount = int.parse(vertexCountMatch.group(1)!);

    final propertyInfo = _parseProperties(header);
    final dataStart = _findDataStart(inputBuffer, headerEnd);
    if (dataStart == 0) {
      throw Exception("Could not find end of PLY header");
    }

    return {
      'vertexCount': vertexCount,
      'offsets': propertyInfo['offsets'],
      'types': propertyInfo['types'],
      'rowSize': propertyInfo['rowSize'],
      'dataStart': dataStart,
    };
  }

  /// Validates that all required properties are present.
  void _validateRequiredProperties(Map<String, int> offsets) {
    const requiredProps = [
      'x',
      'y',
      'z',
      'scale_0',
      'scale_1',
      'scale_2',
      'f_dc_0',
      'f_dc_1',
      'f_dc_2',
      'rot_0',
      'rot_1',
      'rot_2',
      'rot_3',
    ];

    final missingProps =
        requiredProps.where((prop) => !offsets.containsKey(prop)).toList();

    if (missingProps.isNotEmpty) {
       log(
        'PLY file missing some properties: ${missingProps.join(', ')}. '
        'Using default values for missing properties.',
        name: 'FileProcessor',
        level: 800,
      );
    }
  }

  /// Calculates importance-based sorting indices.
  List<int> _calculateImportanceSort(
    ByteData inputData,
    int vertexCount,
    int rowSize,
    Map<String, int> offsets,
    Map<String, String> types,
  ) {
    final sizeList = Float32List(vertexCount);
    final sizeIndex = List<int>.generate(vertexCount, (i) => i);

    for (var i = 0; i < vertexCount; i++) {
      final inputRowStart = i * rowSize;

      // Calculate volume from scale components
      final scale0 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'scale_0',
          ) ??
          0.0;
      final scale1 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'scale_1',
          ) ??
          0.0;
      final scale2 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'scale_2',
          ) ??
          0.0;

      final size = math.exp(scale0) * math.exp(scale1) * math.exp(scale2);

      // Calculate opacity
      var opacityVal = 1.0;
      if (offsets.containsKey('opacity')) {
        final opacity = _readPropertySafe(
              inputData,
              inputRowStart,
              offsets,
              types,
              'opacity',
            ) ??
            0.0;
        opacityVal = 1.0 / (1.0 + math.exp(-opacity));
      }

      sizeList[i] = size * opacityVal;
    }

    // Sort by importance (descending)
    sizeIndex.sort((a, b) => sizeList[b].compareTo(sizeList[a]));
    return sizeIndex;
  }

  /// Converts vertex data to the packed binary format.
  Uint8List _convertVertexData(
    ByteData inputData,
    int vertexCount,
    int rowSize,
    Map<String, int> offsets,
    Map<String, String> types,
    List<int> sortedIndices,
  ) {
    final outputBuffer = Uint8List(vertexCount * outputRowLength);
    final outputView = ByteData.view(outputBuffer.buffer);

    for (var j = 0; j < vertexCount; j++) {
      final i = sortedIndices[j];
      final inputRowStart = i * rowSize;
      final outputRowStart = j * outputRowLength;

      try {
        _writeVertexData(
          inputData,
          inputRowStart,
          outputView,
          outputRowStart,
          offsets,
          types,
        );
      } catch (e) {
        _writeDefaultVertexData(outputView, outputRowStart);
      }
    }

    return outputBuffer;
  }

  /// Writes a single vertex to the output buffer.
  void _writeVertexData(
    ByteData inputData,
    int inputRowStart,
    ByteData outputView,
    int outputRowStart,
    Map<String, int> offsets,
    Map<String, String> types,
  ) {
    // Position (0-11 bytes)
    _writePosition(
      inputData,
      inputRowStart,
      outputView,
      outputRowStart,
      offsets,
      types,
    );

    // Scale (12-23 bytes)
    _writeScale(
      inputData,
      inputRowStart,
      outputView,
      outputRowStart,
      offsets,
      types,
    );

    // Color (24-27 bytes)
    _writeColor(
      inputData,
      inputRowStart,
      outputView,
      outputRowStart,
      offsets,
      types,
    );

    // Rotation (28-31 bytes)
    _writeRotation(
      inputData,
      inputRowStart,
      outputView,
      outputRowStart,
      offsets,
      types,
    );
  }

  /// Writes position data (x, y, z).
  void _writePosition(
    ByteData inputData,
    int inputRowStart,
    ByteData outputView,
    int outputRowStart,
    Map<String, int> offsets,
    Map<String, String> types,
  ) {
    final x =
        _readPropertySafe(inputData, inputRowStart, offsets, types, 'x') ?? 0.0;
    final y =
        _readPropertySafe(inputData, inputRowStart, offsets, types, 'y') ?? 0.0;
    final z =
        _readPropertySafe(inputData, inputRowStart, offsets, types, 'z') ?? 0.0;

    outputView
      ..setFloat32(outputRowStart + 0, x, Endian.little)
      ..setFloat32(outputRowStart + 4, y, Endian.little)
      ..setFloat32(outputRowStart + 8, z, Endian.little);
  }

  /// Writes scale data, converting from log scale to linear.
  void _writeScale(
    ByteData inputData,
    int inputRowStart,
    ByteData outputView,
    int outputRowStart,
    Map<String, int> offsets,
    Map<String, String> types,
  ) {
    if (offsets.containsKey('scale_0')) {
      final scale0 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'scale_0',
          ) ??
          0.0;
      final scale1 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'scale_1',
          ) ??
          0.0;
      final scale2 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'scale_2',
          ) ??
          0.0;

      outputView
        ..setFloat32(outputRowStart + 12, math.exp(scale0), Endian.little)
        ..setFloat32(outputRowStart + 16, math.exp(scale1), Endian.little)
        ..setFloat32(outputRowStart + 20, math.exp(scale2), Endian.little);
    } else {
      outputView
        ..setFloat32(outputRowStart + 12, _defaultScale, Endian.little)
        ..setFloat32(outputRowStart + 16, _defaultScale, Endian.little)
        ..setFloat32(outputRowStart + 20, _defaultScale, Endian.little);
    }
  }

  /// Writes color data from spherical harmonics or direct RGB.
  void _writeColor(
    ByteData inputData,
    int inputRowStart,
    ByteData outputView,
    int outputRowStart,
    Map<String, int> offsets,
    Map<String, String> types,
  ) {
    int rByte;
    int gByte;
    int bByte;
    int aByte;

    if (offsets.containsKey('f_dc_0')) {
      // Spherical harmonics color coefficients
      final fDc0 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'f_dc_0',
          ) ??
          0.0;
      final fDc1 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'f_dc_1',
          ) ??
          0.0;
      final fDc2 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'f_dc_2',
          ) ??
          0.0;

      rByte = ((0.5 + _shC0 * fDc0) * 255).clamp(0, 255).round();
      gByte = ((0.5 + _shC0 * fDc1) * 255).clamp(0, 255).round();
      bByte = ((0.5 + _shC0 * fDc2) * 255).clamp(0, 255).round();
    } else {
      // Direct RGB values
      final red =
          _readPropertySafe(inputData, inputRowStart, offsets, types, 'red') ??
              128.0;
      final green = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'green',
          ) ??
          128.0;
      final blue =
          _readPropertySafe(inputData, inputRowStart, offsets, types, 'blue') ??
              128.0;

      rByte = red.clamp(0, 255).round();
      gByte = green.clamp(0, 255).round();
      bByte = blue.clamp(0, 255).round();
    }

    // Opacity handling
    if (offsets.containsKey('opacity')) {
      final opacity = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'opacity',
          ) ??
          0.0;
      aByte = ((1.0 / (1.0 + math.exp(-opacity))) * 255).clamp(0, 255).round();
    } else {
      aByte = 255;
    }

    outputView
      ..setUint8(outputRowStart + 24, rByte)
      ..setUint8(outputRowStart + 25, gByte)
      ..setUint8(outputRowStart + 26, bByte)
      ..setUint8(outputRowStart + 27, aByte);
  }

  /// Writes rotation quaternion data.
  void _writeRotation(
    ByteData inputData,
    int inputRowStart,
    ByteData outputView,
    int outputRowStart,
    Map<String, int> offsets,
    Map<String, String> types,
  ) {
    if (offsets.containsKey('rot_0')) {
      final rot0 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'rot_0',
          ) ??
          0.0;
      final rot1 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'rot_1',
          ) ??
          0.0;
      final rot2 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'rot_2',
          ) ??
          0.0;
      final rot3 = _readPropertySafe(
            inputData,
            inputRowStart,
            offsets,
            types,
            'rot_3',
          ) ??
          1.0;

      // Normalize quaternion
      final qlen =
          math.sqrt(rot0 * rot0 + rot1 * rot1 + rot2 * rot2 + rot3 * rot3);

      // Convert to byte representation
      final q0Byte = ((rot0 / qlen) * 128 + 128).clamp(0, 255).round();
      final q1Byte = ((rot1 / qlen) * 128 + 128).clamp(0, 255).round();
      final q2Byte = ((rot2 / qlen) * 128 + 128).clamp(0, 255).round();
      final q3Byte = ((rot3 / qlen) * 128 + 128).clamp(0, 255).round();

      outputView
        ..setUint8(outputRowStart + 28, q0Byte)
        ..setUint8(outputRowStart + 29, q1Byte)
        ..setUint8(outputRowStart + 30, q2Byte)
        ..setUint8(outputRowStart + 31, q3Byte);
    } else {
      // Default quaternion values
      outputView
        ..setUint8(outputRowStart + 28, 255)
        ..setUint8(outputRowStart + 29, 0)
        ..setUint8(outputRowStart + 30, 0)
        ..setUint8(outputRowStart + 31, 0);
    }
  }

  /// Writes default vertex data when parsing fails.
  void _writeDefaultVertexData(ByteData outputView, int outputRowStart) {
    outputView
      ..setFloat32(outputRowStart + 0, 0, Endian.little) // x
      ..setFloat32(outputRowStart + 4, 0, Endian.little) // y
      ..setFloat32(outputRowStart + 8, 0, Endian.little) // z
      ..setFloat32(outputRowStart + 12, _defaultScale, Endian.little) // scale_x
      ..setFloat32(outputRowStart + 16, _defaultScale, Endian.little) // scale_y
      ..setFloat32(outputRowStart + 20, _defaultScale, Endian.little) // scale_z
      ..setUint8(outputRowStart + 24, 128) // r
      ..setUint8(outputRowStart + 25, 128) // g
      ..setUint8(outputRowStart + 26, 128) // b
      ..setUint8(outputRowStart + 27, 255) // a
      ..setUint8(outputRowStart + 28, 255) // rot[0]
      ..setUint8(outputRowStart + 29, 0) // rot[1]
      ..setUint8(outputRowStart + 30, 0) // rot[2]
      ..setUint8(outputRowStart + 31, 0); // rot[3]
  }

  /// Parses PLY properties and calculates offsets.
  Map<String, dynamic> _parseProperties(String header) {
    final offsets = <String, int>{};
    final types = <String, String>{};
    var rowOffset = 0;

    const typeMap = {
      'double': 8,
      'int': 4,
      'uint': 4,
      'float': 4,
      'short': 2,
      'ushort': 2,
      'uchar': 1,
    };

    final propertyLines = header
        .split('\n')
        .where((line) => line.startsWith('property '))
        .toList();

    for (final line in propertyLines) {
      final parts = line.split(' ');
      if (parts.length >= 3) {
        final type = parts[1];
        final name = parts[2];

        types[name] = type;
        offsets[name] = rowOffset;
        rowOffset += typeMap[type] ?? 4;
      }
    }

    return {
      'offsets': offsets,
      'types': types,
      'rowSize': rowOffset,
    };
  }

  /// Finds data start position after header.
  int _findDataStart(Uint8List inputBuffer, String headerEnd) {
    final headerEndBytes = utf8.encode(headerEnd);
    for (var i = 0; i <= inputBuffer.length - headerEndBytes.length; i++) {
      var found = true;
      for (var j = 0; j < headerEndBytes.length; j++) {
        if (inputBuffer[i + j] != headerEndBytes[j]) {
          found = false;
          break;
        }
      }
      if (found) {
        return i + headerEndBytes.length;
      }
    }
    return 0;
  }

  /// Safely reads a property with error handling.
  double? _readPropertySafe(
    ByteData data,
    int rowStart,
    Map<String, int> offsets,
    Map<String, String> types,
    String propertyName,
  ) {
    try {
      final offset = offsets[propertyName];
      final type = types[propertyName];
      if (offset == null || type == null) return null;

      return _readProperty(data, rowStart, offset, type);
    } catch (e) {
      return null;
    }
  }

  /// Reads a property value based on its type.
  double _readProperty(ByteData data, int rowStart, int offset, String type) {
    final position = rowStart + offset;

    switch (type) {
      case 'double':
        return data.getFloat64(position, Endian.little);
      case 'float':
        return data.getFloat32(position, Endian.little);
      case 'int':
        return data.getInt32(position, Endian.little).toDouble();
      case 'uint':
        return data.getUint32(position, Endian.little).toDouble();
      case 'short':
        return data.getInt16(position, Endian.little).toDouble();
      case 'ushort':
        return data.getUint16(position, Endian.little).toDouble();
      case 'uchar':
        return data.getUint8(position).toDouble();
      default:
        return 0;
    }
  }
}
