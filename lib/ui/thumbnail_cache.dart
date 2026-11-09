import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';
import '../model/timecode.dart';

/// Keeps small preview pictures of each video for the timeline. Pictures are
/// made in the background, a batch at a time, so the timeline fills in
/// progressively without freezing the app.
class ThumbnailCache extends ChangeNotifier {
  ThumbnailCache(this.engine);

  final MediaEngine engine;
  static const height = 96;

  final Map<String, _SourceThumbs> _sources = {};
  bool _disposed = false;

  /// Starts making pictures for every real clip in [project] (once per file).
  void ensureFor(Project project) {
    if (!engine.supportsMedia) return;
    for (final clip in project.mainTrack.clips) {
      if (!clip.isMedia || _sources.containsKey(clip.sourcePath)) continue;
      final thumbs = _SourceThumbs(clip.sourcePath!, clip.media!);
      _sources[clip.sourcePath!] = thumbs;
      _fill(thumbs);
    }
  }

  Future<void> _fill(_SourceThumbs t) async {
    final times = t.times;
    const batch = 8;
    for (var i = 0; i < times.length && !_disposed; i += batch) {
      final slice = times.sublist(i, math.min(times.length, i + batch));
      List<String?> files;
      try {
        files = await engine.thumbnails(
          t.source,
          t.info,
          slice,
          height: height,
        );
      } catch (_) {
        return;
      }
      for (var j = 0; j < slice.length; j++) {
        final path = files[j];
        if (path == null || _disposed) continue;
        try {
          final bytes = await File(path).readAsBytes();
          final codec = await ui.instantiateImageCodec(
            bytes,
            targetHeight: height,
          );
          final frame = await codec.getNextFrame();
          t.images[slice[j]] = frame.image;
        } catch (_) {}
      }
      if (!_disposed) notifyListeners();
    }
  }

  /// The picture nearest to [timeUs] in [source], or null if none is ready.
  ui.Image? imageAt(String source, int timeUs) {
    final t = _sources[source];
    if (t == null || t.images.isEmpty) return null;
    final idx = (timeUs / t.intervalUs).round().clamp(0, t.times.length - 1);
    // Exact slot first, then the nearest ready neighbour.
    for (var d = 0; d < t.times.length; d++) {
      for (final k in [idx - d, idx + d]) {
        if (k < 0 || k >= t.times.length) continue;
        final img = t.images[t.times[k]];
        if (img != null) return img;
      }
      if (d > 6) break;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _sources.values) {
      for (final img in t.images.values) {
        img.dispose();
      }
    }
    _sources.clear();
    super.dispose();
  }
}

class _SourceThumbs {
  _SourceThumbs(this.source, this.info) {
    // One picture per second, but at most 120 per file.
    intervalUs = math.max(usPerSecond, (info.durationUs / 120).ceil());
    final count = math.max(1, (info.durationUs / intervalUs).ceil());
    times = [for (var i = 0; i < count; i++) i * intervalUs];
  }

  final String source;
  final MediaInfo info;
  late final int intervalUs;
  late final List<int> times;
  final Map<int, ui.Image> images = {};
}
