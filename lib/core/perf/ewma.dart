/// Exponentially Weighted Moving Average for smoothing time series data.
class Ewma {

  /// Creates an EWMA with optional smoothing factor.
  Ewma({this.alpha = 0.12});

  /// Smoothing factor (0-1). Higher values respond faster to changes.
  final double alpha;
  double _v = 0;

  /// Adds a new value and returns the updated average.
  double add(double x) => _v = (_v == 0) ? x : alpha * x + (1 - alpha) * _v;

  /// Current averaged value.
  double get value => _v;
}
