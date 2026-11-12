import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';
import 'package:video_editor/ui/frame_snap.dart';
import 'package:video_editor/ui/timeline_view.dart';

const s = usPerSecond;
const box = Size(400, 225);

void main() {
  test('items snap to the centre lines and the frame edges', () {
    const item = Size(100, 50);
    // Near the centre.
    var r = snapInFrame(0.51, 0.3, item, 0, box);
    expect(r.x, 0.5);
    expect(r.guideX, 0.5);
    expect(r.guideY, isNull);
    // Left edge near the frame's left edge (its centre at 50 px).
    r = snapInFrame(55 / 400, 0.3, item, 0, box);
    expect(r.x * 400, closeTo(50, 1e-9));
    expect(r.guideX, 0);
    // Bottom edge on the frame's bottom edge.
    r = snapInFrame(0.3, (225 - 25 - 6) / 225, item, 0, box);
    expect(r.y * 225, closeTo(200, 1e-9));
    expect(r.guideY, 1);
    // Turned a quarter: its outline is 50 wide, so the edge is 25 px in.
    r = snapInFrame(380 / 400, 0.3, item, math.pi / 2, box);
    expect(r.x * 400, closeTo(375, 1e-6));
    expect(r.guideX, 1);
    // Far from everything: unchanged.
    r = snapInFrame(0.3, 0.3, item, 0, box);
    expect((r.x, r.y, r.guideX, r.guideY), (0.3, 0.3, null, null));
  });

  testWidgets('hold a text clip on the timeline, then drag: it snaps to the '
      'end of the video clip', (tester) async {
    final video = Clip(
      id: 0,
      kind: ClipKind.video,
      name: 'v',
      sourcePath: 'v.mp4',
      media: const MediaInfo(durationUs: 5 * s, width: 1920, height: 1080),
      sourceDurationUs: 5 * s,
      sourceInUs: 0,
      sourceOutUs: 5 * s,
    );
    final project = Project.empty(id: 'p', frameRate: 30)
        .insertMedia([video])
        .addText(Clip.text(const TextSpec(), startUs: s, durationUs: 2 * s));
    final c = EditorController(project);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 400, child: TimelineView(controller: c)),
          ),
        ),
      ),
    );
    final pps = c.pixelsPerSecond;
    final textId = c.project.textTracks.single.clips.single.id;
    // Text row: below the main row. Middle of the text clip (at 2 s).
    final y =
        TimelineView.mainTrackTop +
        TimelineView.mainTrackHeight +
        TimelineView.trackGap +
        TimelineView.audioTrackHeight / 2;
    final g = await tester.startGesture(Offset(200 + 2 * pps, y));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(c.selectedClipId, textId);
    // Two seconds later its end would be at the video's end (5 s); stop a
    // few pixels short: it snaps.
    await g.moveBy(Offset(2 * pps - 6, 0));
    await tester.pump();
    await g.moveBy(const Offset(0.5, 0));
    await tester.pump();
    await g.up();
    await tester.pump();
    final placed = c.project.placementOf(textId)!;
    expect(placed.startUs, 3 * s);
    expect(placed.endUs, 5 * s);
    // One undo step.
    c.undo();
    expect(c.project.placementOf(textId)!.startUs, s);
  });
}
