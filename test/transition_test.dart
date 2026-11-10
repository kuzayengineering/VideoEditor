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
    expect(dipsOf(p).single, (startUs: 3 * s, durationUs: s));

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
}
