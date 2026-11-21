import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

const s = usPerSecond;

Clip sound(String name, int startS, int lengthS) => Clip(
  id: 0,
  kind: ClipKind.audio,
  name: name,
  sourcePath: '$name.mp3',
  media: MediaInfo(durationUs: 60 * s, width: 0, height: 0, hasVideo: false),
  sourceDurationUs: 60 * s,
  sourceInUs: 0,
  sourceOutUs: lengthS * s,
  startUs: startS * s,
);

void main() {
  test('volume and fades shape the loudness', () {
    final c = sound(
      'm',
      0,
      10,
    ).copyWith(volume: 0.5, fadeInUs: 2 * s, fadeOutUs: 4 * s);
    expect(c.gainAt(0), 0);
    expect(c.gainAt(1 * s), closeTo(0.25, 1e-9));
    expect(c.gainAt(5 * s), 0.5);
    expect(c.gainAt(8 * s), closeTo(0.25, 1e-9));
    // Fades longer than the clip are shrunk to fit.
    final short = sound('m', 0, 2).copyWith(fadeInUs: 3 * s, fadeOutUs: 1 * s);
    final f = short.effectiveFades;
    expect(f.fadeIn + f.fadeOut, lessThanOrEqualTo(2 * s));
  });

  test('sound clips move but never overlap their neighbours', () {
    final p = Project.empty(id: 'x')
        .addAudio(sound('a', 0, 5))
        .addAudio(sound('b', 10, 5));
    final track = p.audioTracks.single;
    final a = track.clips[0].id, b = track.clips[1].id;
    expect(p.moveAudioClip(a, 3 * s).placementOf(a)!.startUs, 3 * s);
    // Can't go past "b" (which starts at 10 s): stops at 5 s.
    expect(p.moveAudioClip(a, 8 * s).placementOf(a)!.startUs, 5 * s);
    expect(p.moveAudioClip(b, 2 * s).placementOf(b)!.startUs, 5 * s);
    expect(p.moveAudioClip(a, -4 * s).placementOf(a)!.startUs, 0);
  });

  test('dragged clips pass others and land in the nearest free spot', () {
    // a 0-5 s, b 10-15 s, c 20-25 s, all on one row.
    final p = Project.empty(id: 'x')
        .addAudio(sound('a', 0, 5))
        .addAudio(sound('b', 10, 5))
        .addAudio(sound('c', 20, 5));
    final row = p.audioTracks.single;
    final c = row.clips[2].id;
    // Dropped at 4 s: overlaps a and b; the nearest free spot is 5-10 s.
    expect(p.moveLayerClip(c, 4 * s).placementOf(c)!.startUs, 5 * s);
    // Dropped at 1 s: 0-5 is taken, nearest free start is 5 s.
    expect(p.moveLayerClip(c, 1 * s).placementOf(c)!.startUs, 5 * s);
    // A clip too long for any gap goes after the last one.
    final long = p.addAudio(sound('d', 30, 8));
    final d = long.audioTracks.first.clips.last.id;
    expect(long.moveLayerClip(d, 2 * s).placementOf(d)!.startUs, 25 * s);
  });

  test('dragged clips change rows, and empty rows go at the end', () {
    final p = Project.empty(id: 'x')
        .addAudio(sound('a', 0, 5))
        .addAudio(sound('b', 2, 5)); // overlaps a: goes on a second row
    expect(p.audioTracks.length, 2);
    final b = p.audioTracks[1].clips.single.id;
    final rowA = p.audioTracks[0].id;
    // Onto the first row at 1 s: lands right after a.
    final moved = p.moveLayerClip(b, 1 * s, trackId: rowA);
    expect(moved.placementOf(b)!.track.id, rowA);
    expect(moved.placementOf(b)!.startUs, 5 * s);
    expect(moved.audioTracks.length, 2); // kept during the drag
    expect(moved.withoutEmptyLayerTracks().audioTracks.length, 1);
    // Onto a new row, exactly where dropped.
    final a = p.audioTracks[0].clips.single.id;
    final fresh = p.moveLayerClip(a, 3 * s, newTrack: true);
    expect(fresh.audioTracks.length, 3);
    expect(fresh.placementOf(a)!.startUs, 3 * s);
  });

  test('extracting sound mutes the video and keeps sync', () {
    const info = MediaInfo(durationUs: 30 * s, width: 1920, height: 1080);
    final video = const Clip(
      id: 0,
      kind: ClipKind.video,
      name: 'beach',
      sourcePath: 'beach.mp4',
      media: info,
      sourceDurationUs: 30 * s,
      sourceInUs: 5 * s,
      sourceOutUs: 15 * s,
    ).copyWith(speed: 2, rotation: 1);
    var p = Project.empty(id: 'x')
        .insertMedia([video, video.copyWith(name: 'second')]);
    final second = p.mainTrack.clips[1].id;
    p = p.extractAudio(second);
    final a = p.audioTracks.single.clips.single;
    expect(p.placementOf(second)!.clip.volume, 0);
    expect(a.kind, ClipKind.audio);
    expect(a.startUs, 5 * s); // first clip lasts 10 s / 2× = 5 s
    expect((a.sourceInUs, a.sourceOutUs, a.speed), (5 * s, 15 * s, 2.0));
    expect(a.rotation, 0);
  });

  test('clips can be rearranged; bad orders are ignored', () {
    const info = MediaInfo(durationUs: 30 * s, width: 1920, height: 1080);
    Clip v(String n) => Clip(
      id: 0,
      kind: ClipKind.video,
      name: n,
      sourcePath: '$n.mp4',
      media: info,
      sourceDurationUs: 30 * s,
      sourceInUs: 0,
      sourceOutUs: 5 * s,
    );
    final p = Project.empty(id: 'x').insertMedia([v('a'), v('b'), v('c')]);
    final ids = [for (final c in p.mainTrack.clips) c.id];
    final q = p.reorderMain([ids[2], ids[0], ids[1]]);
    expect(q.mainTrack.clips.map((c) => c.name), ['c', 'a', 'b']);
    expect(identical(p.reorderMain(ids), p), isTrue);
    expect(identical(p.reorderMain([ids[0], ids[1]]), p), isTrue);
  });

  test('volume and fades survive saving', () {
    final p = Project.empty(id: 'x').addAudio(
      sound('m', 2, 8).copyWith(volume: 1.5, fadeInUs: 500000, fadeOutUs: s),
    );
    final back = Project.fromJson(
      (jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, Object?>(),
    );
    final c = back.audioTracks.single.clips.single;
    expect((c.volume, c.fadeInUs, c.fadeOutUs), (1.5, 500000, s));
    expect(c.media!.hasVideo, isFalse);
  });
}
