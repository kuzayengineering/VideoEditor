import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../media_engine.dart';

/// Builds an mpv "EDL" address that plays several pieces of several files
/// back to back as if they were one video. This is what makes the timeline
/// preview seamless.
String buildEdl(List<PreviewSegment> segments) {
  String sec(int us) => (us / 1000000).toStringAsFixed(6);
  final parts = [
    for (final s in segments)
      // %<length>% lets file names contain commas and semicolons safely.
      '%${utf8.encode(s.source).length}%${s.source},${sec(s.inUs)},${sec(s.lengthUs)}',
  ];
  return 'edl://${parts.join(';')}';
}

/// Converts between timeline time (after each clip's speed change) and the
/// time inside the EDL (the clips at normal speed, back to back).
class SpeedMap {
  SpeedMap(List<PreviewSegment> segments)
    : speeds = [for (final s in segments) s.speed],
      timelineStarts = _starts([for (final s in segments) s.timelineUs]),
      edlStarts = _starts([for (final s in segments) s.lengthUs]);

  final List<double> speeds;
  final List<int> timelineStarts;
  final List<int> edlStarts;

  static List<int> _starts(List<int> lengths) {
    final out = <int>[];
    var t = 0;
    for (final l in lengths) {
      out.add(t);
      t += l;
    }
    return out;
  }

  int _index(List<int> starts, int t) {
    var i = 0;
    while (i + 1 < starts.length && starts[i + 1] <= t) {
      i++;
    }
    return i;
  }

  int segmentAtTimeline(int t) => _index(timelineStarts, t);
  int segmentAtEdl(int e) => _index(edlStarts, e);

  int toEdl(int timelineUs) {
    if (speeds.isEmpty) return timelineUs;
    final i = segmentAtTimeline(timelineUs);
    return edlStarts[i] +
        ((timelineUs - timelineStarts[i]) * speeds[i]).round();
  }

  int toTimeline(int edlUs) {
    if (speeds.isEmpty) return edlUs;
    final i = segmentAtEdl(edlUs);
    return timelineStarts[i] + ((edlUs - edlStarts[i]) / speeds[i]).round();
  }
}

/// Windows preview, powered by mpv. HDR footage is tone-mapped for the
/// (SDR) preview; exports keep full HDR. Turn, mirror, crop, opacity and
/// background are drawn by the screen around the video; speed is applied by
/// changing mpv's playback speed as each clip starts.
class MpvPreviewPlayer implements PreviewPlayer {
  MpvPreviewPlayer() {
    final native = _player.platform;
    if (native is NativePlayer) {
      // Stay on the last frame at the end instead of unloading, and always
      // seek to exact frames when asked to.
      native.setProperty('keep-open', 'yes');
      native.setProperty('hr-seek', 'yes');
      native.setProperty('hr-seek-framedrop', 'no');
    }
  }

  final Player _player = Player(
    configuration: const PlayerConfiguration(
      title: 'Video Editor preview',
      logLevel: MPVLogLevel.error,
    ),
  );
  late final VideoController _video = VideoController(_player);
  List<PreviewSegment> _segments = const [];
  SpeedMap _map = SpeedMap(const []);
  bool _exactSeeks = true;
  double _rate = 1.0;

  @override
  Widget buildView(BuildContext context) =>
      Video(controller: _video, controls: NoVideoControls, fill: Colors.black);

  /// mpv already seeks to exact frames quickly enough.
  @override
  Future<void> setScrubbing(bool on) async {}

  @override
  bool drawsEffects(List<PreviewSegment> segments) => false;

  /// Windows shows transitions from pre-rendered pieces instead.
  @override
  bool get blendsTransitions => false;

  @override
  Future<void> setTimeline(
    List<PreviewSegment> segments, {
    int canvasWidth = 1920,
    int canvasHeight = 1080,
    BlendLayers? blends,
  }) async {
    if (_sameMedia(segments, _segments)) {
      _segments = List.of(segments);
      return;
    }
    final position = await this.position();
    _segments = List.of(segments);
    _map = SpeedMap(_segments);
    if (segments.isEmpty) {
      await _player.stop();
      return;
    }
    await _player.open(Media(buildEdl(segments)), play: false);
    await seek(position);
  }

  Future<void> _applyRateFor(int edlUs) async {
    if (_map.speeds.isEmpty) return;
    final rate = _map.speeds[_map.segmentAtEdl(edlUs)];
    if ((rate - _rate).abs() > 0.0001) {
      _rate = rate;
      await _player.setRate(rate);
    }
  }

  @override
  Future<void> play() async {
    await _applyRateFor(_player.state.position.inMicroseconds);
    await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(int timeUs, {bool exact = true}) async {
    if (exact != _exactSeeks) {
      _exactSeeks = exact;
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty('hr-seek', exact ? 'yes' : 'no');
      }
    }
    final edl = _map.toEdl(timeUs);
    await _applyRateFor(edl);
    await _player.seek(Duration(microseconds: edl));
  }

  @override
  Future<int> position() async {
    final edl = _player.state.position.inMicroseconds;
    // Crossing into a clip with a different speed: switch playback speed.
    await _applyRateFor(edl);
    return _map.toTimeline(edl);
  }

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume * 100).clamp(0, 100).toDouble());

  @override
  Future<void> dispose() => _player.dispose();

  /// Same files and ranges in the same order (looks may differ: those are
  /// drawn by the screen, so the player needn't reload).
  static bool _sameMedia(List<PreviewSegment> a, List<PreviewSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].source != b[i].source ||
          a[i].inUs != b[i].inUs ||
          a[i].outUs != b[i].outUs ||
          a[i].speed != b[i].speed) {
        return false;
      }
    }
    return true;
  }
}

/// Plays one audio-track clip during the Windows preview.
class MpvAudioPlayer implements ClipAudioPlayer {
  MpvAudioPlayer() {
    final native = _player.platform;
    if (native is NativePlayer) {
      native.setProperty('vid', 'no'); // sound only
      native.setProperty('keep-open', 'yes');
    }
  }

  final Player _player = Player(
    configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
  );

  @override
  Future<void> open(String source) => _player.open(Media(source), play: false);

  @override
  Future<void> seek(int sourceUs) =>
      _player.seek(Duration(microseconds: sourceUs));

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume * 100).clamp(0, 100).toDouble());

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> dispose() => _player.dispose();
}

/// One picture-in-picture clip in the Windows preview (a second mpv player
/// whose picture the screen places on top of the main one).
class MpvOverlayPlayer implements OverlayPlayer {
  MpvOverlayPlayer() {
    final native = _player.platform;
    if (native is NativePlayer) {
      native.setProperty('keep-open', 'yes');
      native.setProperty('hr-seek', 'yes');
    }
  }

  final Player _player = Player(
    configuration: const PlayerConfiguration(
      title: 'Video Editor picture in picture',
      logLevel: MPVLogLevel.error,
    ),
  );
  late final VideoController _video = VideoController(_player);
  PreviewSegment? _segment;

  @override
  Widget buildView(BuildContext context) => Video(
    controller: _video,
    controls: NoVideoControls,
    fill: Colors.transparent,
    fit: BoxFit.fill,
  );

  @override
  Future<void> open(PreviewSegment segment) async {
    final old = _segment;
    _segment = segment;
    if (old != null && old.source == segment.source) {
      await _player.setRate(segment.speed);
      return;
    }
    await _player.open(Media(segment.source), play: false);
    await _player.setRate(segment.speed);
  }

  @override
  Future<void> seek(int offsetUs, {bool exact = true}) async {
    final s = _segment;
    if (s == null) return;
    final media = (offsetUs * s.speed).round().clamp(0, s.lengthUs);
    await _player.seek(Duration(microseconds: s.inUs + media));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume * 100).clamp(0, 100).toDouble());

  @override
  Future<void> dispose() => _player.dispose();
}
