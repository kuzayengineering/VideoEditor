/// Where each moment sits along the timeline, in pixels from the start.
///
/// Normally [pixelsPerSecond] throughout, but every clip is given at least
/// its minimum width (a square on its row): the stretch of time it covers
/// is spread out to make room, and everything after it shifts along. So
/// the time scale isn't even where there are short clips (they scroll by
/// faster while playing), until zooming in far enough that they no longer
/// need it.
class TimelineScale {
  TimelineScale(this.pixelsPerSecond, List<(int, int, double)> clips) {
    final points = <int>{0};
    for (final (start, end, _) in clips) {
      if (end > start) {
        points
          ..add(start)
          ..add(end);
      }
    }
    _points = points.toList()..sort();
    final base = pixelsPerSecond / 1e6;
    _slopes = List.filled(_points.length - 1, base);
    for (final (start, end, minPx) in clips) {
      if (end <= start) continue;
      final from = _indexOf(start), to = _indexOf(end);
      var width = 0.0;
      for (var i = from; i < to; i++) {
        width += (_points[i + 1] - _points[i]) * _slopes[i];
      }
      if (width >= minPx || width <= 0) continue;
      // Spread its stretch out until it is wide enough.
      final grow = minPx / width;
      for (var i = from; i < to; i++) {
        _slopes[i] *= grow;
      }
    }
    _xs = List.filled(_points.length, 0);
    for (var i = 0; i + 1 < _points.length; i++) {
      _xs[i + 1] = _xs[i] + (_points[i + 1] - _points[i]) * _slopes[i];
    }
  }

  final double pixelsPerSecond;
  late final List<int> _points;
  late final List<double> _slopes; // pixels per microsecond
  late final List<double> _xs;

  double get _base => pixelsPerSecond / 1e6;

  int _indexOf(int t) {
    var lo = 0, hi = _points.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_points[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Pixels from the start of the timeline to moment [timeUs].
  double xOf(int timeUs) {
    if (timeUs <= 0 || _slopes.isEmpty) return timeUs * _base;
    if (timeUs >= _points.last) {
      return _xs.last + (timeUs - _points.last) * _base;
    }
    // The segment [points[i], points[i + 1]) holding it.
    var i = _indexOf(timeUs);
    if (_points[i] > timeUs) i--;
    return _xs[i] + (timeUs - _points[i]) * _slopes[i];
  }

  /// The moment at [x] pixels from the start of the timeline.
  int timeAt(double x) {
    if (x <= 0 || _slopes.isEmpty) return (x / _base).round();
    if (x >= _xs.last) return _points.last + ((x - _xs.last) / _base).round();
    var lo = 0, hi = _xs.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_xs[mid] <= x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return _points[lo] + ((x - _xs[lo]) / _slopes[lo]).round();
  }

  /// The moment [dx] pixels away from moment [timeUs] (dragging).
  int timeMovedBy(int timeUs, double dx) => timeAt(xOf(timeUs) + dx);
}
