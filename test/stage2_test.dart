import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/ffmpeg/ffmpeg_commands.dart';
import 'package:video_editor/engine/ffmpeg/mpv_preview.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';

const s = usPerSecond;

const info = MediaInfo(
  durationUs: 20 * s,
  width: 1920,
  height: 1080,
  frameRate: 30,
);

Clip clip({int inS = 2, int outS = 12, bool reversed = false}) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: 'c',
  sourcePath: 'a.mp4',
  media: info,
  sourceDurationUs: info.durationUs,
  sourceInUs: inS * s,
  sourceOutUs: outS * s,
  reversed: reversed,
);

void main() {
  test('speed changes timeline length and split point', () {
    var p = Project.empty(id: 'x', frameRate: 30).insertMedia([clip()]);
    final id = p.mainTrack.clips.single.id;
    p = p.setSpeed(id, 2);
    expect(p.durationUs, 5 * s);
    p = p.splitAt(1 * s);
    expect(p.mainTrack.clips.first.sourceOutUs, 4 * s); // 2 s + 1 s × 2
    expect(p.setSpeed(id, 100).mainTrack.clips.first.speed, Clip.maxSpeed);
  });

  test('reversed clips: split and trim work on the right end', () {
    var p = Project.empty(
      id: 'x',
      frameRate: 30,
    ).insertMedia([clip(reversed: true)]);
    final c = p.mainTrack.clips.single;
    expect(c.sourceTimeAt(0), 12 * s); // starts at the end of its range
    expect(c.sourceTimeAt(3 * s), 9 * s);

    final split = p.splitAt(3 * s);
    final [first, second] = split.mainTrack.clips;
    expect((first.sourceInUs, first.sourceOutUs), (9 * s, 12 * s));
    expect((second.sourceInUs, second.sourceOutUs), (2 * s, 9 * s));

    // Trimming the start of a backwards clip cuts the end of its range.
    p = p.trimStart(c.id, 1 * s);
    expect(p.mainTrack.clips.single.sourceOutUs, 11 * s);
    // Extending the end reveals earlier footage, down to the file start.
    p = p.trimEnd(c.id, 10 * s);
    expect(p.mainTrack.clips.single.sourceInUs, 0);
  });

  test('reverse copy is ready only while it covers the range', () {
    final c = clip(reversed: true)
        .copyWith(reverseProxy: const ReverseProxy('r.mp4', 2 * s, 12 * s));
    expect(c.reverseReady, isTrue);
    expect(c.copyWith(sourceInUs: 1 * s).reverseReady, isFalse);
    final seg = PreviewSegment.of(c.copyWith(sourceInUs: 4 * s));
    expect(seg.source, 'r.mp4');
    expect((seg.inUs, seg.outUs), (0, 8 * s));
  });

  test('turn and mirror carry the crop along with the picture', () {
    final c = EditorController(
      Project.empty(
        id: 'x',
      ).insertMedia([clip().copyWith(crop: const CropRect(0, 0, 0.5, 0.25))]),
    );
    c.select(c.project.mainTrack.clips.single.id);
    c.rotateSelected();
    var x = c.project.mainTrack.clips.single;
    expect(x.rotation, 1);
    // Top-left strip → right-hand top strip after a clockwise turn.
    expect(x.crop, const CropRect(0.75, 0, 1, 0.5));
    expect(x.displaySize, (width: 1080 * 0.25, height: 1920 * 0.5));
    c.mirrorSelected();
    x = c.project.mainTrack.clips.single;
    expect(x.crop, const CropRect(0, 0, 0.25, 0.5));
    c.undo();
    c.undo();
    expect(c.project.mainTrack.clips.single.rotation, 0);
  });

  test('slider edits are one undo step', () {
    final c = EditorController(Project.empty(id: 'x').insertMedia([clip()]));
    final id = c.project.mainTrack.clips.single.id;
    for (final v in [0.9, 0.7, 0.5]) {
      c.liveEdit((b) => b.updateClip(id, (x) => x.copyWith(opacity: v)));
    }
    c.endLiveEdit();
    expect(c.project.mainTrack.clips.single.opacity, 0.5);
    c.undo();
    expect(c.project.mainTrack.clips.single.opacity, 1.0);
  });

  test('looks and background survive saving', () {
    final p = Project.empty(id: 'x')
        .insertMedia([
          clip().copyWith(
            rotation: 3,
            flipV: true,
            crop: const CropRect(0.1, 0.2, 0.9, 0.8),
            opacity: 0.4,
            speed: 0.5,
          ),
        ])
        .withBackground(const BackgroundFill.blur());
    final back = Project.fromJson(
      (jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, Object?>(),
    );
    final c = back.mainTrack.clips.single;
    expect((c.rotation, c.flipV, c.opacity, c.speed), (3, true, 0.4, 0.5));
    expect(c.crop, const CropRect(0.1, 0.2, 0.9, 0.8));
    expect(back.background, const BackgroundFill.blur());
  });

  test('audio tempo is chained for big speed changes', () {
    expect(atempoChain(1), '');
    expect(atempoChain(4), 'atempo=2.00000,atempo=2.00000,');
    expect(atempoChain(0.25), 'atempo=0.50000,atempo=0.50000,');
    expect(atempoChain(1.5), 'atempo=1.50000,');
  });

  test('Windows preview maps timeline time through clip speeds', () {
    final m = SpeedMap(const [
      PreviewSegment('a', 0, 4 * s, speed: 2), // 2 s on the timeline
      PreviewSegment('b', 0, 3 * s, speed: 0.5), // 6 s on the timeline
    ]);
    expect(m.toEdl(1 * s), 2 * s);
    expect(m.toEdl(3 * s), 4 * s + s ~/ 2);
    expect(m.toTimeline(4 * s + s ~/ 2), 3 * s);
    expect(m.segmentAtTimeline(5 * s), 1);
  });
}
