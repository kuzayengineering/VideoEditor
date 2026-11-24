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

  /// Exact pictures of each clip's first frame, by "source@time" (a clip's
  /// start rarely falls on a once-a-second picture).
  final Map<String, ui.Image> _firsts = {};
  final Set<String> _firstsWanted = {};
  final List<(String, MediaInfo, int)> _firstQueue = [];
  bool _firstsRunning = false;

  static String _key(String source, int timeUs) => '$source@$timeUs';

  /// Starts making pictures for every real clip in [project] (once per file).
  void ensureFor(Project project) {
    if (!engine.supportsMedia) return;
    for (final clip in [
      ...project.mainTrack.clips,
      for (final t in project.overlayTracks) ...t.clips,
    ]) {
      if (!clip.isMedia) continue;
      final first = clip.sourceTimeAt(0);
      if (_firstsWanted.add(_key(clip.sourcePath!, first))) {
        _firstQueue.add((clip.sourcePath!, clip.media!, first));
      }
      if (_sources.containsKey(clip.sourcePath)) continue;
      final thumbs = _SourceThumbs(clip.sourcePath!, clip.media!);
      _sources[clip.sourcePath!] = thumbs;
      _fill(thumbs);
    }
    _fillFirsts();
  }

  /// Makes the queued first-frame pictures, newest first (just split or
  /// trimmed), one at a time.
  Future<void> _fillFirsts() async {
    if (_firstsRunning) return;
    _firstsRunning = true;
    while (_firstQueue.isNotEmpty && !_disposed) {
      final (source, info, t) = _firstQueue.removeLast();
      try {
        final files = await engine.thumbnails(
          source,
          info,
          [t],
          height: height,
          exact: true,
        );
        final path = files.isEmpty ? null : files.first;
        if (path == null || _disposed) continue;
        final codec = await ui.instantiateImageCodec(
          await File(path).readAsBytes(),
          targetHeight: height,
        );
        _firsts[_key(source, t)] = (await codec.getNextFrame()).image;
        if (!_disposed) notifyListeners();
      } catch (_) {}
    }
    _firstsRunning = false;
  }

  /// The exact picture of [clip]'s first frame, once made.
  ui.Image? firstImageOf(Clip clip) => clip.isMedia
      ? _firsts[_key(clip.sourcePath!, clip.sourceTimeAt(0))]
      : null;

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
  /// With [fromUs]–[toUs] (a clip's part of the file), only pictures from
  /// inside that part are used, so a cut-out moment never shows.
  ui.Image? imageAt(String source, int timeUs, {int? fromUs, int? toUs}) {
    final t = _sources[source];
    if (t == null || t.images.isEmpty) return null;
    final idx = (timeUs / t.intervalUs).round().clamp(0, t.times.length - 1);
    bool inside(int time) =>
        (fromUs == null || time >= fromUs) && (toUs == null || time <= toUs);
    // Exact slot first, then the nearest ready neighbour.
    for (var d = 0; d < t.times.length; d++) {
      for (final k in [idx - d, idx + d]) {
        if (k < 0 || k >= t.times.length || !inside(t.times[k])) continue;
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
    for (final img in _firsts.values) {
      img.dispose();
    }
    _firsts.clear();
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
