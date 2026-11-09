import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/demo.dart';
import 'package:video_editor/model/history.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

const s = usPerSecond;

Clip video(String name, int seconds) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: name,
  sourceDurationUs: (seconds + 4) * s,
  sourceInUs: 2 * s,
  sourceOutUs: (seconds + 2) * s,
);

Clip audio(String name, int startSeconds, int seconds) => Clip(
  id: 0,
  kind: ClipKind.audio,
  name: name,
  sourceDurationUs: seconds * s,
  sourceInUs: 0,
  sourceOutUs: seconds * s,
  startUs: startSeconds * s,
);

Project twoClips() => Project.empty(
  id: 't',
  frameRate: 30,
).appendVideo(video('A', 10)).appendVideo(video('B', 5));

void main() {
  group('timecode', () {
    test('formats minutes, seconds and frames', () {
      expect(formatTimecode(0, 30), '00:00:00');
      expect(formatTimecode(61 * s + s ~/ 2, 30), '01:01:15');
      expect(formatTimecode(3600 * s, 60), '1:00:00:00');
    });

    test('frame helpers round-trip', () {
      for (final fps in [24.0, 25.0, 30.0, 60.0]) {
        for (final f in [0, 1, 59, 1234]) {
          expect(frameIndexAt(frameStartUs(f, fps), fps), f);
        }
      }
      expect(snapToFrame(1010000, 60), frameStartUs(61, 60));
    });
  });

  group('project', () {
    test('main track clips sit end to end', () {
      final p = twoClips();
      final placements = p.placementsOn(p.mainTrack);
      expect(placements.map((e) => e.startUs), [0, 10 * s]);
      expect(p.durationUs, 15 * s);
      expect(p.mainClipAt(12 * s)!.clip.name, 'B');
    });

    test('split cuts a clip in two without changing total length', () {
      final p = twoClips().splitAt(4 * s);
      expect(p.mainTrack.clips.length, 3);
      expect(p.durationUs, 15 * s);
      final [a1, a2, _] = p.mainTrack.clips;
      expect(a1.sourceOutUs, 6 * s); // source started at 2 s
      expect(a2.sourceInUs, 6 * s);
      expect(a1.id, isNot(a2.id));
    });

    test('split respects playback speed', () {
      final p0 = Project.empty(
        id: 't',
        frameRate: 30,
      ).appendVideo(video('A', 10).copyWith(speed: 2));
      expect(p0.durationUs, 5 * s);
      final p = p0.splitAt(1 * s);
      expect(p.mainTrack.clips.first.sourceOutUs, 4 * s); // 2 s + 1 s × 2
    });

    test('split on a clip edge does nothing', () {
      final p = twoClips();
      expect(identical(p.splitAt(10 * s), p), isTrue);
      expect(identical(p.splitAt(0), p), isTrue);
    });

    test('duplicate inserts a copy right after the original', () {
      final p = twoClips();
      final first = p.mainTrack.clips.first.id;
      final d = p.duplicateClip(first);
      expect(d.mainTrack.clips.map((c) => c.name), ['A', 'A', 'B']);
      expect(d.durationUs, 25 * s);
      expect(d.mainTrack.clips[1].id, isNot(first));
    });

    test('delete removes a clip and closes the gap', () {
      final p = twoClips();
      final d = p.deleteClip(p.mainTrack.clips.first.id);
      expect(d.mainTrack.clips.map((c) => c.name), ['B']);
      expect(d.durationUs, 5 * s);
    });

    test('trim start shortens, and can bring back trimmed footage', () {
      final p = twoClips();
      final id = p.mainTrack.clips.first.id;
      final shorter = p.trimStart(id, 3 * s);
      expect(shorter.mainTrack.clips.first.sourceInUs, 5 * s);
      expect(shorter.durationUs, 12 * s);
      // Only 2 s of extra footage exists before the in-point.
      final longer = p.trimStart(id, -10 * s);
      expect(longer.mainTrack.clips.first.sourceInUs, 0);
      expect(longer.durationUs, 17 * s);
    });

    test('trim end is limited by the source file and one-frame minimum', () {
      final p = twoClips();
      final id = p.mainTrack.clips.first.id;
      expect(p.trimEnd(id, 100 * s).mainTrack.clips.first.sourceOutUs, 14 * s);
      final tiny = p.trimEnd(id, -100 * s).mainTrack.clips.first;
      expect(tiny.durationUs, p.minClipUs);
    });

    test('audio clips go on a new track when they would overlap', () {
      final p = Project.empty(id: 't')
          .addAudio(audio('Music', 0, 20))
          .addAudio(audio('Voice', 3, 5))
          .addAudio(audio('Late', 25, 5));
      expect(p.audioTracks.length, 2);
      expect(p.audioTracks[0].clips.map((c) => c.name), ['Music', 'Late']);
      expect(p.audioTracks[1].clips.map((c) => c.name), ['Voice']);
      expect(p.durationUs, 30 * s);
    });

    test('audio trim cannot run into the neighbouring clip', () {
      final p = Project.empty(id: 't')
          .addAudio(audio('One', 0, 5).copyWith())
          .addAudio(
            Clip(
              id: 0,
              kind: ClipKind.audio,
              name: 'Two',
              sourceDurationUs: 30 * s,
              sourceInUs: 10 * s,
              sourceOutUs: 15 * s,
              startUs: 8 * s,
            ),
          );
      final two = p.audioTracks.single.clips[1];
      final t = p.trimStart(two.id, -20 * s);
      final moved = t.audioTracks.single.clips[1];
      expect(moved.startUs, 5 * s); // stops at the end of "One"
      expect(moved.sourceInUs, 7 * s);
    });

    test('deleting the last clip on an audio track removes the track', () {
      final p = Project.empty(id: 't').addAudio(audio('Music', 0, 5));
      final d = p.deleteClip(p.audioTracks.single.clips.single.id);
      expect(d.audioTracks, isEmpty);
    });

    test('custom canvas ratios are reduced and matched to presets', () {
      expect(CanvasRatio.custom(1920, 1080), CanvasRatio.landscape16x9);
      expect(CanvasRatio.custom(6, 3).label, '2:1');
    });

    test('save and load keeps everything', () {
      final p = buildDemoProject('demo').splitAt(3 * s);
      final text = jsonEncode(p.toJson());
      final back = Project.fromJson(
        (jsonDecode(text) as Map).cast<String, Object?>(),
      );
      expect(jsonEncode(back.toJson()), text);
    });

    test('refuses projects from a newer app version', () {
      final json = twoClips().toJson()..['formatVersion'] = 99;
      expect(() => Project.fromJson(json), throwsFormatException);
    });
  });

  group('history', () {
    test('undo and redo walk through edits', () {
      final h = EditHistory(twoClips());
      h.apply(h.current.splitAt(4 * s));
      h.apply(h.current.splitAt(2 * s));
      expect(h.current.mainTrack.clips.length, 4);
      h.undo();
      expect(h.current.mainTrack.clips.length, 3);
      h.undo();
      expect(h.current.mainTrack.clips.length, 2);
      expect(h.canUndo, isFalse);
      h.redo();
      expect(h.current.mainTrack.clips.length, 3);
    });

    test('a new edit clears redo', () {
      final h = EditHistory(twoClips());
      h.apply(h.current.splitAt(4 * s));
      h.undo();
      h.apply(h.current.splitAt(2 * s));
      expect(h.canRedo, isFalse);
    });

    test('edits that change nothing are not recorded', () {
      final h = EditHistory(twoClips());
      h.apply(h.current.splitAt(0));
      expect(h.canUndo, isFalse);
    });

    test('a drag counts as one undo step', () {
      final h = EditHistory(twoClips());
      final id = h.current.mainTrack.clips.first.id;
      final base = h.beginGesture();
      for (var i = 1; i <= 10; i++) {
        h.updateGesture(base.trimEnd(id, -i * s ~/ 10));
      }
      h.endGesture();
      expect(h.current.durationUs, 14 * s);
      h.undo();
      expect(h.current.durationUs, 15 * s);
      expect(h.canUndo, isFalse);
    });
  });
}
