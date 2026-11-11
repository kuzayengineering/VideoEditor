import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';

const s = usPerSecond;

class _Player implements PreviewPlayer {
  int rebuilds = 0;
  final grades = <Map<int, List<double>>>[];
  @override
  Future<void> setTimeline(
    List<PreviewSegment> segments, {
    int canvasWidth = 1920,
    int canvasHeight = 1080,
    BlendLayers? blends,
  }) async => rebuilds++;
  @override
  bool get gradesLive => true;
  @override
  Future<void> setGrades(Map<int, List<double>> g) async => grades.add(g);
  @override
  bool get blendsTransitions => false;
  @override
  bool drawsEffects(List<PreviewSegment> segments) => true;
  @override
  Widget buildView(BuildContext context) => const SizedBox();
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> setScrubbing(bool on) async {}
  @override
  Future<void> seek(int timeUs, {bool exact = true}) async {}
  @override
  Future<int> position() async => 0;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  test('filter sliders update the player live, rebuilding only once', () async {
    final clip = Clip(
      id: 0,
      kind: ClipKind.video,
      name: 'v',
      sourcePath: 'v.mp4',
      media: const MediaInfo(durationUs: 5 * s, width: 1920, height: 1080),
      sourceDurationUs: 5 * s,
      sourceInUs: 0,
      sourceOutUs: 5 * s,
    );
    final c = EditorController(
      Project.empty(id: 'p', frameRate: 30).insertMedia([clip]),
    );
    final player = _Player();
    c.attachPreview(player);
    await Future<void>.delayed(Duration.zero);
    expect(player.rebuilds, 1);
    final id = c.project.mainTrack.clips.single.id;

    void drag(double v) => c.liveEdit(
      (b) => b.updateClip(
        id,
        (x) => x.copyWith(
          grade: ColorGrade(adjust: GradeParams(brightness: v)),
        ),
      ),
    );

    // The first move gives the clip a filter: one rebuild.
    drag(0.1);
    expect(player.rebuilds, 2);
    // Further moves only send the values.
    drag(0.2);
    drag(0.3);
    expect(player.rebuilds, 2);
    expect(player.grades.last[id]!.first, closeTo(0.3, 1e-9));
    // Letting go doesn't rebuild either.
    c.endLiveEdit();
    expect(player.rebuilds, 2);
    expect(player.grades.last[id]!.first, closeTo(0.3, 1e-9));
  });
}
