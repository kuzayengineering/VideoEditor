import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';

const s = usPerSecond;

Clip video(String name, int seconds) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: name,
  sourcePath: '$name.mp4',
  media: const MediaInfo(durationUs: 60 * s, width: 1920, height: 1080),
  sourceDurationUs: 60 * s,
  sourceInUs: 0,
  sourceOutUs: seconds * s,
);

/// Main clips a (0-4 s), b (4-7 s), c (7-12 s).
EditorController setUp() => EditorController(
  Project.empty(
    id: 'p',
    frameRate: 30,
  ).insertMedia([video('a', 4), video('b', 3), video('c', 5)]),
);

int idOf(EditorController c, String name) =>
    c.project.mainTrack.clips.firstWhere((x) => x.name == name).id;

void main() {
  test('deleting an earlier clip keeps the same frame showing', () {
    final c = setUp();
    c.seek(9 * s); // 2 s into c
    c.select(idOf(c, 'a'));
    c.deleteSelected();
    expect(c.playheadUs, 5 * s); // c now starts at 3 s
  });

  test('deleting a later clip leaves the playhead where it is', () {
    final c = setUp();
    c.seek(2 * s);
    c.select(idOf(c, 'c'));
    c.deleteSelected();
    expect(c.playheadUs, 2 * s);
  });

  test('deleting the clip under the playhead goes to the next clip', () {
    final c = setUp();
    c.seek(5 * s); // inside b
    c.select(idOf(c, 'b'));
    c.deleteSelected();
    expect(c.playheadUs, 4 * s); // the start of c
  });

  test('deleting the last clip under the playhead goes to the end', () {
    final c = setUp();
    c.seek(10 * s); // inside c
    c.select(idOf(c, 'c'));
    c.deleteSelected();
    expect(c.playheadUs, 7 * s);
  });
}
