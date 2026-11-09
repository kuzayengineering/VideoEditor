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

/// Windows preview, powered by mpv. HDR footage is tone-mapped for the
/// (SDR) preview; exports keep full HDR.
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
  bool _exactSeeks = true;

  @override
  Widget buildView(BuildContext context) =>
      Video(controller: _video, controls: NoVideoControls, fill: Colors.black);

  @override
  Future<void> setTimeline(List<PreviewSegment> segments) async {
    if (_listEquals(segments, _segments)) return;
    final position = await this.position();
    _segments = List.of(segments);
    if (segments.isEmpty) {
      await _player.stop();
      return;
    }
    await _player.open(Media(buildEdl(segments)), play: false);
    await seek(position);
  }

  @override
  Future<void> play() => _player.play();

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
    await _player.seek(Duration(microseconds: timeUs));
  }

  @override
  Future<int> position() async => _player.state.position.inMicroseconds;

  @override
  Future<void> dispose() => _player.dispose();

  static bool _listEquals(List<PreviewSegment> a, List<PreviewSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
