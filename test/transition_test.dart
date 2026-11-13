import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

const s = usPerSecond;

Clip video(String name, int seconds) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: name,
  sourcePath: '$name.mp4',
  media: MediaInfo(
    durationUs: 20 * s,
    width: 1920,
    height: 1080,
    frameRate: 30,
  ),
  sourceDurationUs: 20 * s,
  sourceInUs: 2 * s,
  sourceOutUs: (2 + seconds) * s,
);

Project three() => Project.empty(
  id: 'x',
  frameRate: 30,
).insertMedia([video('a', 4), video('b', 4), video('c', 4)]);

void main() {
  test('a transition overlaps the clips and shortens the video', () {
    var p = three();
    expect(p.durationUs, 12 * s);
    p = p.setTransition(
      0,
      const TransitionSpec(TransitionKind.fade, durationUs: s),
    );
    final ps = p.placementsOn(p.mainTrack);
    expect(ps.map((x) => x.startUs), [0, 3 * s, 7 * s]);
    expect(p.durationUs, 11 * s);
    final tr = p.transitionAt(3 * s + s ~/ 2)!;
    expect((tr.index, tr.startUs, tr.durationUs), (0, 3 * s, s));
    expect(p.transitionAt(5 * s), isNull);
    // During the overlap the incoming clip counts as "current".
    expect(p.mainClipAt(3 * s + 100)!.clip.name, 'b');
  });

  test('transition length is limited to half the shorter clip', () {
    final p = Project.empty(id: 'x', frameRate: 30)
        .insertMedia([video('a', 4), video('b', 1)])
        .setTransition(
          0,
          const TransitionSpec(TransitionKind.fade, durationUs: 3 * s),
        );
    expect(p.transitionUsAfter(0), s ~/ 2);
    expect(p.transitionUsAfter(1), 0); // nothing after the last clip
  });

  test('preview pieces: half trims and dips until a copy is rendered', () {
    final p = three().setTransition(
      0,
      const TransitionSpec(TransitionKind.slideLeft, durationUs: s),
    );
    final segs = segmentsOf(p);
    expect(segs.length, 3);
    expect(segs.fold(0, (t, x) => t + x.timelineUs), p.durationUs);
    expect((segs[0].inUs, segs[0].outUs), (2 * s, 6 * s - s ~/ 2));
    expect(segs[1].inUs, 2 * s + s ~/ 2);
    expect(segs[0].dipOutUs, s ~/ 2);
    expect(segs[1].dipInUs, s ~/ 2);
    expect(dipsOf(p).single, (
      startUs: 3 * s,
      durationUs: s,
      color: 0xFF000000,
    ));
    // Android mixes it instead: no dip.
    expect(dipsOf(p, blend: true), isEmpty);

    // With a rendered copy: cut by the whole length, the copy in between.
    final key = p.transitionKey(0);
    final withFile = segmentsOf(p, transitionFiles: {key: '/t.mp4'});
    expect(withFile.length, 4);
    expect(withFile[1].source, '/t.mp4');
    expect((withFile[1].inUs, withFile[1].outUs), (s, 2 * s));
    expect(withFile.fold(0, (t, x) => t + x.timelineUs), p.durationUs);
    expect(dipsOf(p, transitionFiles: {key: '/t.mp4'}), isEmpty);
  });

  test('mini project for rendering a transition preview', () {
    final p = three().setTransition(
      1,
      const TransitionSpec(TransitionKind.zoom, durationUs: s),
    );
    final mini = p.transitionPreviewProject(1)!;
    expect(mini.mainTrack.clips.length, 2);
    expect(mini.durationUs, 3 * s); // 2d + 2d - d
    expect(mini.transitionUsAfter(0), s);
    // The key changes when anything about the transition changes.
    final k1 = p.transitionKey(1);
    final k2 = p
        .setTransition(
          1,
          const TransitionSpec(TransitionKind.fade, durationUs: s),
        )
        .transitionKey(1);
    expect(k1, isNot(k2));
    expect(three().transitionKey(1), '');
  });

  test(
    'splitting keeps the transition on the right piece; saving keeps it',
    () {
      var p = three().setTransition(
        0,
        const TransitionSpec(TransitionKind.fadeBlack, durationUs: s),
      );
      p = p.splitAt(s);
      expect(p.mainTrack.clips[0].transition, isNull);
      expect(p.mainTrack.clips[1].transition!.kind, TransitionKind.fadeBlack);
      final back = Project.fromJson(
        (jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, Object?>(),
      );
      expect(
        back.mainTrack.clips[1].transition,
        p.mainTrack.clips[1].transition,
      );
      expect(back.durationUs, p.durationUs);
    },
  );

  test('Android layers: lined up, incoming clip on the second layer', () {
    // Clips a, b, c of 4 s; a→b mixes (1 s), b→c dips through white (1 s).
    final p = three()
        .setTransition(
          0,
          const TransitionSpec(TransitionKind.wipeLeft, durationUs: s),
        )
        .setTransition(
          1,
          const TransitionSpec(TransitionKind.fadeWhite, durationUs: s),
        );
    expect(p.durationUs, 10 * s);
    final a = segmentsOf(p, blend: true);
    final layers = blendLayersOf(p)!;
    final b = layers.layerB;
    int total(List<PreviewSegment> x) => x.fold(0, (t, e) => t + e.timelineUs);
    expect(total(a), p.durationUs);
    expect(total(b), p.durationUs);
    // Layer A: a whole (sound fades out at its end), b without its first
    // second, then the white dip halves.
    expect((a[0].inUs, a[0].outUs), (2 * s, 6 * s));
    expect(a[0].blendOutUs, s);
    expect(a[1].inUs, 3 * s);
    expect(a[1].dipOutUs, s ~/ 2);
    expect(a[2].dipInUs, s ~/ 2);
    // Layer B: a without its last second, b from its start.
    expect((b[0].inUs, b[0].outUs), (2 * s, 5 * s));
    expect(b[1].inUs, 2 * s);
    // The cut between the layers' pieces lines up with the dip on both.
    expect(
      a[0].timelineUs + a[1].timelineUs,
      b[0].timelineUs + b[1].timelineUs,
    );
    expect(layers.windows.single, const BlendWindow(3 * s, s, 30));
    // b's first second of sound, fading in where the transition starts.
    final audio = layers.audio.single;
    expect(audio['startUs'], 3 * s);
    expect(audio['fadeInUs'], s);
    expect((audio['inUs'], audio['outUs']), (2 * s, 3 * s));
    expect(dipsOf(p, blend: true).single.color, 0xFFFFFFFF);
    expect(blendLayersOf(three()), isNull);
  });

  test('picture-in-picture layers line up with the main layer', () {
    var p = three(); // a, b, c: 4 s each
    p = p.addOverlay(
      video('pip', 3).copyWith(
        startUs: 2 * s,
        pip: const PipLayout(x: 0.25, y: 0.25, size: 0.5, angle: 10),
        opacity: 0.8,
      ),
    );
    // One that runs past the end is cut at the end.
    p = p.addOverlay(video('late', 3).copyWith(startUs: 11 * s));
    expect(p.overlayTracks.length, 1);
    final base = segmentsOf(p, blend: true);
    final layers = pipLayersOf(p, base, canvasWidth: 1920, canvasHeight: 1080);
    expect(layers.length, 1);
    final l = layers.single;
    int total(List<Map<String, Object?>> x) => x.fold(
      0,
      (t, e) =>
          t +
          (((e['outUs'] as int) - (e['inUs'] as int)) / (e['speed'] as double))
              .round(),
    );
    // As long as the main video (the export's length).
    expect(total(l.segments), 12 * s);
    expect(l.windows.length, 2);
    expect(l.windows[0]['startUs'], 2 * s);
    expect(l.windows[0]['endUs'], 5 * s);
    expect(l.windows[0]['w'], 960 / 1920);
    expect(l.windows[0]['opacity'], 0.8);
    expect(l.windows[1]['endUs'], 12 * s);
    // Filler first (from the main video, tiny, silent), then the clip.
    expect(l.segments.first['boxW'], 32);
    expect(l.segments.first['silent'], true);
    expect(l.segments[1]['source'], 'pip.mp4');
    expect(l.segments[1]['boxW'], 960);
    expect(l.segments[1]['boxH'], 540);
    // Saved and loaded with its place.
    final back = Project.fromJson(
      (jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, Object?>(),
    );
    expect(
      back.overlayTracks.single.clips.first.pip,
      p.overlayTracks.single.clips.first.pip,
    );
    // Deleting the last clips removes the track.
    var q = p;
    for (final c in p.overlayTracks.single.clips) {
      q = q.deleteClip(c.id);
    }
    expect(q.overlayTracks, isEmpty);
  });

  test('a clip at a changed speed plays from its ready-made copy', () {
    var p = three();
    final slow = p.mainTrack.clips[1];
    p = p.updateClip(slow.id, (c) => c.copyWith(speed: 0.5));
    expect(p.speedKey(0), '');
    final key = p.speedKey(1);
    expect(key, isNotEmpty);
    // Before the copy is ready: the clip itself, at its speed.
    var segs = segmentsOf(p);
    expect(segs[1].speed, 0.5);
    expect(segs[1].hasEffects, isTrue);
    // Ready: the copy, from its start to the clip's length on the timeline.
    segs = segmentsOf(p, transitionFiles: {key: 'slow.mp4'});
    expect(segs[1].source, 'slow.mp4');
    expect((segs[1].inUs, segs[1].outUs), (0, 8 * s));
    expect(segs[1].hasEffects, isFalse);
    expect(segs.length, 3);
    // Its sound level isn't part of the copy (the mixer handles it)...
    final quieter = p.updateClip(slow.id, (c) => c.copyWith(volume: 0.5));
    expect(quieter.speedKey(1), key);
    // ...but anything about its picture is: a new copy is needed.
    final cropped = p.updateClip(
      slow.id,
      (c) => c.copyWith(crop: const CropRect(0.1, 0, 1, 1)),
    );
    expect(cropped.speedKey(1), isNot(key));
  });
}
