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

void main() {
  test('a setting is copied to the other clips from the same file', () {
    final c = EditorController(
      Project.empty(
        id: 'p',
        frameRate: 30,
      ).insertMedia([video('a', 4), video('b', 3), video('a', 5)]),
    );
    final clips = c.project.mainTrack.clips;
    final first = clips[0].id;
    expect(c.sameSourceAs(first), [clips[2].id]);
    c.apply(c.project.updateClip(first, (x) => x.copyWith(volume: 0.3)));
    c.applyToSameSource(
      first,
      (p, target, from) =>
          p.updateClip(target, (x) => x.copyWith(volume: from.volume)),
    );
    final after = c.project.mainTrack.clips;
    expect(after[2].volume, 0.3);
    expect(after[1].volume, 1.0);
    // One step to undo.
    c.undo();
    expect(c.project.mainTrack.clips[2].volume, 1.0);
  });
}
