import 'project.dart';
import 'timecode.dart';

/// Sound, text and picture-in-picture clips stick to the video frame they
/// start on: when the main video is edited (clips added, removed, moved,
/// trimmed, sped up or slowed down), they move with that frame.
extension LayerAnchors on Project {
  List<Track> get _layerTracks => [
    ...overlayTracks,
    ...audioTracks,
    ...textTracks,
  ];

  /// The frame of the main video at timeline time [t], if there is video
  /// there.
  ClipAnchor? anchorAt(int t) {
    for (final p in placementsOn(mainTrack)) {
      final c = p.clip;
      if (!c.isMedia || t < p.startUs || t >= p.endUs) continue;
      return ClipAnchor(c.id, c.sourcePath!, c.sourceTimeAt(t - p.startUs));
    }
    return null;
  }

  /// Where [a]'s frame is on the timeline now, or null if it's gone.
  int? timeOfAnchor(ClipAnchor a, {int? near}) {
    int? best;
    for (final p in placementsOn(mainTrack)) {
      final c = p.clip;
      if (c.sourcePath != a.source) continue;
      final off = c.offsetOfSource(a.sourceUs);
      if (off == null) continue;
      final t = p.startUs + off;
      // Its own clip first; otherwise the copy of that moment nearest to
      // where the layer was (e.g. after a split).
      if (c.id == a.clipId) return t;
      if (best == null ||
          (near != null && (t - near).abs() < (best - near).abs())) {
        best = t;
      }
    }
    return best;
  }

  /// Records, for every layer clip, the frame it starts on now (nothing
  /// moves).
  Project withAnchorsRecorded() {
    var changed = false;
    Track fix(Track t) {
      var any = false;
      final clips = [
        for (final c in t.clips)
          () {
            final a = anchorAt(c.startUs);
            if (a == c.anchor) return c;
            any = true;
            return a == null
                ? c.copyWith(clearAnchor: true)
                : c.copyWith(anchor: a);
          }(),
      ];
      if (!any) return t;
      changed = true;
      return t.withClips(clips);
    }

    final overlays = [for (final t in overlayTracks) fix(t)];
    final audio = [for (final t in audioTracks) fix(t)];
    final texts = [for (final t in textTracks) fix(t)];
    if (!changed) return this;
    return copyWith(
      overlayTracks: overlays,
      audioTracks: audio,
      textTracks: texts,
    );
  }

  /// Moves every layer clip to where its frame is now, then records the
  /// frames again. Clips whose frame is gone stay put. Clips that would
  /// now overlap another on their row move to a free row.
  Project withLayersFollowed() {
    final moves = <int, int>{};
    for (final t in _layerTracks) {
      for (final c in t.clips) {
        final a = c.anchor;
        if (a == null) continue;
        final at = timeOfAnchor(a, near: c.startUs);
        if (at == null) continue;
        final start = snapToFrame(at, frameRate);
        if (start != c.startUs) moves[c.id] = start;
      }
    }
    if (moves.isEmpty) return withAnchorsRecorded();

    // Take the moved clips off their rows, then put them back where there
    // is room (their own row if it's free there).
    var p = this;
    final moved = <(Clip, int)>[];
    Track strip(Track t) {
      final keep = <Clip>[];
      for (final c in t.clips) {
        final to = moves[c.id];
        if (to == null) {
          keep.add(c);
        } else {
          moved.add((c.copyWith(startUs: to), t.id));
        }
      }
      return keep.length == t.clips.length ? t : t.withClips(keep);
    }

    p = p.copyWith(
      overlayTracks: [for (final t in overlayTracks) strip(t)],
      audioTracks: [for (final t in audioTracks) strip(t)],
      textTracks: [for (final t in textTracks) strip(t)],
    );
    moved.sort((a, b) => a.$1.startUs.compareTo(b.$1.startUs));
    for (final (clip, trackId) in moved) {
      p = p._putBack(clip, trackId);
    }
    return p.withAnchorsRecorded();
  }

  Project _putBack(Clip clip, int trackId) {
    bool fits(Track t) => t.clips.every(
      (c) => clip.endUs <= c.startUs || clip.startUs >= c.endUs,
    );
    List<Track> place(List<Track> tracks) {
      final i = tracks.indexWhere((t) => t.id == trackId);
      if (i < 0 || !fits(tracks[i])) return tracks;
      final clips = [...tracks[i].clips, clip]
        ..sort((a, b) => a.startUs.compareTo(b.startUs));
      return [...tracks]..[i] = tracks[i].withClips(clips);
    }

    final o = place(overlayTracks),
        a = place(audioTracks),
        x = place(textTracks);
    if (!identical(o, overlayTracks) ||
        !identical(a, audioTracks) ||
        !identical(x, textTracks)) {
      return copyWith(overlayTracks: o, audioTracks: a, textTracks: x);
    }
    // Its row is taken there: another free row (a new one if needed).
    return placeOnFreeTrack(clip);
  }
}

/// After an edit from [before] to [after]: if the main video changed, the
/// layers follow their frames; otherwise their frames are recorded afresh
/// (they were moved, added or changed themselves).
Project settleLayers(Project before, Project after) {
  if (identical(after.mainTrack, before.mainTrack) ||
      _sameMain(before, after)) {
    return after.withAnchorsRecorded();
  }
  return after.withLayersFollowed();
}

bool _sameMain(Project a, Project b) {
  final x = a.placementsOn(a.mainTrack), y = b.placementsOn(b.mainTrack);
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    final p = x[i], q = y[i];
    if (p.startUs != q.startUs ||
        p.clip.id != q.clip.id ||
        p.clip.sourceInUs != q.clip.sourceInUs ||
        p.clip.sourceOutUs != q.clip.sourceOutUs ||
        p.clip.speed != q.clip.speed ||
        p.clip.reversed != q.clip.reversed ||
        p.clip.sourcePath != q.clip.sourcePath) {
      return false;
    }
  }
  return true;
}
