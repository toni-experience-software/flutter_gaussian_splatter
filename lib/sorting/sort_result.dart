import 'dart:typed_data';
import 'package:vector_math/vector_math.dart';

/// Result of a depth sorting operation.
///
/// Contains the sorted indices and metadata about the sorting operation.
class SortResult {
  /// Creates a new [SortResult] with the specified parameters.
  ///
  /// Parameters:
  /// - [depthIndex]: Array of depth-sorted vertex indices
  /// - [viewProjection]: View-projection matrix used for sorting
  /// - [vertexCount]: Number of vertices that were sorted
  const SortResult({
    required this.depthIndex,
    required this.viewProjection,
    required this.vertexCount,
    int? visibleCount,
    this.generation = 0,
    this.dataGeneration = 0,
  }) : visibleCount = visibleCount ?? vertexCount;

  /// Depth-sorted indices array.
  final Uint32List depthIndex;

  /// View-projection matrix used for sorting.
  final Matrix4 viewProjection;

  /// Number of vertices that were sorted.
  final int vertexCount;

  /// Number of splats in front of the camera, occupying the prefix
  /// `[0, visibleCount)` of [depthIndex]. Behind-camera splats land in the
  /// tail and can be skipped at draw time. Defaults to [vertexCount].
  final int visibleCount;

  /// Renderer-assigned sort request generation.
  final int generation;

  /// Renderer-assigned splat data generation.
  final int dataGeneration;
}
