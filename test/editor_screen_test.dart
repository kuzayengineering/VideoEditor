import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/main.dart';
import 'package:video_editor/model/demo.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';

void main() {
  testWidgets('home opens the demo project and Split works', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const VideoEditorApp());
    expect(find.text('New project'), findsOneWidget);

    await tester.tap(find.text('Try the demo project'));
    await tester.pumpAndSettle();
    expect(find.text('Demo project'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);

    // Step forward one frame, then split the first clip there.
    await tester.tap(find.byTooltip('Forward one frame (→)'));
    await tester.pump();
    expect(find.textContaining('00:00:01 /'), findsOneWidget);

    await tester.tap(find.text('Split'));
    await tester.pump();
    await tester.tap(find.byTooltip('Undo (Ctrl+Z)'));
    await tester.pump();

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3840 × 2160'), findsOneWidget);
  });

  test('controller: frame stepping and split at playhead', () {
    final c = EditorController(buildDemoProject('d'));
    c.stepFrame(1);
    expect(c.playheadUs, frameStartUs(1, 60));
    c.seek(3 * usPerSecond);
    expect(c.splitAtPlayhead(), isTrue);
    expect(c.project.mainTrack.clips.length, 4);
    c.undo();
    expect(c.project.mainTrack.clips.length, 3);
  });

  test(
    'controller: trimming the start keeps the playhead on the same frame',
    () {
      final c = EditorController(buildDemoProject('d'));
      c.seek(10 * usPerSecond); // inside the second clip
      final first = c.project.mainTrack.clips.first.id;
      c.beginTrim(first, start: true);
      c.updateTrim(2 * usPerSecond);
      c.endTrim();
      expect(c.project.durationUs, 22 * usPerSecond);
      expect(c.playheadUs, 8 * usPerSecond);
      c.undo();
      expect(c.project.durationUs, 24 * usPerSecond);
    },
  );
}
