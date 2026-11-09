import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';

/// Plays the audio-track clips (music, voice-overs, extracted sound) in step
/// with the preview, one small player per clip, and keeps every volume and
/// fade up to date as the playhead moves.
class AudioPreviewMixer {
  AudioPreviewMixer(this.engine);

  final MediaEngine engine;
  final Map<int, _Slot> _slots = {};
  double _mainVolume = -1;

  /// While recording a voice-over, other sound is silenced so it isn't
  /// picked up by the microphone.
  bool muted = false;

  static ({String source, int Function(int sourceUs) map}) _sourceFor(Clip c) {
    final proxy = c.reverseProxy;
    if (c.reverseReady && proxy != null) {
      return (source: proxy.path, map: proxy.proxyTimeOf);
    }
    return (source: c.sourcePath!, map: (int us) => us);
  }

  /// Creates players for new audio clips and removes ones no longer needed.
  void sync(Project project) {
    final wanted = <int, Clip>{
      for (final t in project.audioTracks)
        for (final c in t.clips)
          if (c.isMedia && (c.media?.hasAudio ?? false)) c.id: c,
    };
    for (final id in _slots.keys.toList()) {
      final c = wanted[id];
      if (c == null || _sourceFor(c).source != _slots[id]!.source) {
        unawaited(_slots.remove(id)!.player.dispose());
      }
    }
    for (final entry in wanted.entries) {
      if (_slots.containsKey(entry.key)) continue;
      final source = _sourceFor(entry.value).source;
      final player = engine.createAudioPlayer();
      _slots[entry.key] = _Slot(player, source, player.open(source));
    }
  }

  /// Called on every display refresh: starts, stops and adjusts players.
  void update(
    Project project,
    int playheadUs,
    bool playing,
    PreviewPlayer? main,
  ) {
    final current = project.mainClipAt(playheadUs);
    if (main != null) {
      var v = current == null
          ? 1.0
          : current.clip.gainAt(playheadUs - current.startUs);
      if (muted) v = 0;
      v = v.clamp(0.0, 1.0);
      if ((v - _mainVolume).abs() > 0.01) {
        _mainVolume = v;
        unawaited(main.setVolume(v));
      }
    }
    for (final t in project.audioTracks) {
      for (final c in t.clips) {
        final slot = _slots[c.id];
        if (slot == null) continue;
        final offset = playheadUs - c.startUs;
        final active = playing && offset >= 0 && offset < c.durationUs;
        if (active && !slot.playing) {
          slot.playing = true;
          final m = _sourceFor(c);
          final target = m.map(c.sourceTimeAt(offset));
          unawaited(() async {
            await slot.ready;
            await slot.player.setRate(c.speed);
            await slot.player.seek(target);
            if (slot.playing) await slot.player.play();
          }());
        } else if (!active && slot.playing) {
          slot.playing = false;
          unawaited(slot.player.pause());
        }
        if (active) {
          final v = muted ? 0.0 : c.gainAt(offset).clamp(0.0, 1.0);
          if ((v - slot.volume).abs() > 0.01) {
            slot.volume = v;
            unawaited(slot.player.setVolume(v));
          }
        }
      }
    }
  }

  /// Pauses all audio-track players (they restart from the right place on
  /// the next [update] while playing).
  void stopAll() {
    for (final s in _slots.values) {
      if (s.playing) {
        s.playing = false;
        unawaited(s.player.pause());
      }
    }
  }

  void dispose() {
    for (final s in _slots.values) {
      unawaited(s.player.dispose());
    }
    _slots.clear();
  }
}

class _Slot {
  _Slot(this.player, this.source, this.ready);

  final ClipAudioPlayer player;
  final String source;
  final Future<void> ready;
  bool playing = false;
  double volume = -1;
}

/// Loudness outlines of the sound files, for drawing on the timeline.
class WaveformCache extends ChangeNotifier {
  WaveformCache(this.engine);

  final MediaEngine engine;
  final Map<String, Uint8List?> _peaks = {};
  bool _disposed = false;

  /// 100 values per second, 0–255; null while still being read.
  Uint8List? peaksFor(String source) => _peaks[source];

  void ensureFor(Project project) {
    if (!engine.supportsMedia) return;
    for (final t in project.audioTracks) {
      for (final c in t.clips) {
        final source = c.sourcePath;
        if (!c.isMedia || source == null || _peaks.containsKey(source)) {
          continue;
        }
        _peaks[source] = null;
        engine.waveform(source).then((p) {
          if (_disposed) return;
          _peaks[source] = p;
          notifyListeners();
        }, onError: (Object _) {});
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
