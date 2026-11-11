import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';
import 'package:video_editor/ui/pip_view.dart';

const s = usPerSecond;

class _FakePlayer implements OverlayPlayer {
  final calls = <String>[];
  @override
  Widget buildView(BuildContext context) =>
      const ColoredBox(color: Colors.blue);
  @override
  Future<void> open(PreviewSegment segment) async => calls.add('open');
  @override
  Future<void> seek(int offsetUs, {bool exact = true}) async =>
      calls.add('seek $offsetUs');
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async => calls.add('dispose');
}

class _FakeEngine extends NoMediaEngine {
  _FakeEngine();
  final players = <_FakePlayer>[];
  @override
  OverlayPlayer? createOverlayPlayer() {
    final p = _FakePlayer();
    players.add(p);
    return p;
  }
}

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
  sourceInUs: 0,
  sourceOutUs: seconds * s,
);

void main() {
  testWidgets('a picture-in-picture clip shows, follows the playhead and '
      'can be dragged', (t) async {
    var project = Project.empty(
      id: 'p',
      frameRate: 30,
    ).insertMedia([video('main', 6)]);
    project = project.addOverlay(
      video('pip', 2).copyWith(
        startUs: 1 * s,
        pip: const PipLayout(x: 0.5, y: 0.5, size: 0.5),
      ),
    );
    final c = EditorController(project);
    final engine = _FakeEngine();
    final players = PipPlayers(engine, c);
    final gestures = PipGestures(c);
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 225,
            child: PipOverlayView(
              controller: c,
              players: players,
              gestures: gestures,
            ),
          ),
        ),
      ),
    );
    // Not showing yet at 0 s (but its player is ready, a second ahead).
    expect(
      find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.blue),
      findsNothing,
    );
    expect(engine.players.length, 1);
    c.seek(1500000, exact: true);
    await t.pumpAndSettle();
    // Showing: half the width, centred.
    final box = t.getRect(
      find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.blue),
    );
    expect(box.width, closeTo(200, 1));
    expect(engine.players.single.calls, contains('seek 500000'));
    // Drag it right by 100 px (a quarter of the width).
    await t.dragFrom(box.center, const Offset(100, 0));
    await t.pumpAndSettle();
    final pip = c.project.overlayTracks.single.clips.single.pip!;
    // (Less the few pixels Flutter waits for before a drag starts.)
    expect(pip.x, inInclusiveRange(0.68, 0.76));
    expect(c.selected?.clip.name, 'pip');
    // Past its end it disappears; far away its player is put aside.
    c.seek(5500000, exact: true);
    await t.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.blue),
      findsNothing,
    );
    players.dispose();
  });
}
