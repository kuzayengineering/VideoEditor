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
  sourceInUs: 10 * s,
  sourceOutUs: (10 + seconds) * s,
);

/// Main video a (0-4 s) and b (4-8 s), a text at 5 s (1 s into b) and a
/// sound clip at 1 s (in a).
EditorController setUp() {
  var p = Project.empty(id: 'p', frameRate: 30)
      .insertMedia([video('a', 4), video('b', 4)])
      .addText(Clip.text(const TextSpec(text: 'Hi'), startUs: 5 * s))
      .addAudio(
        Clip(
          id: 0,
          kind: ClipKind.audio,
          name: 'music',
          sourcePath: 'music.mp3',
          media: const MediaInfo(durationUs: 30 * s, width: 0, height: 0),
          sourceDurationUs: 30 * s,
          sourceInUs: 0,
          sourceOutUs: 2 * s,
          startUs: 1 * s,
        ),
      );
  return EditorController(p);
}

int startOf(EditorController c, String name) => [
  for (final t in [...c.project.textTracks, ...c.project.audioTracks])
    for (final x in t.clips)
      if (x.name == name) x.startUs,
].single;

int idOf(EditorController c, String name) =>
    c.project.mainTrack.clips.firstWhere((x) => x.name == name).id;

void main() {
  test('adding a clip earlier moves the layers with their frames', () {
    final c = setUp();
    c.apply(c.project.insertMedia([video('intro', 2)], index: 0));
    expect(startOf(c, 'Hi'), 7 * s);
    expect(startOf(c, 'music'), 3 * s);
    c.undo();
    expect(startOf(c, 'Hi'), 5 * s);
    expect(startOf(c, 'music'), 1 * s);
  });

  test('speeding up an earlier clip pulls later layers in', () {
    final c = setUp();
    c.apply(c.project.updateClip(idOf(c, 'a'), (x) => x.copyWith(speed: 2)));
    // a is now 2 s long: b starts at 2 s, the text 1 s into it.
    expect(startOf(c, 'Hi'), 3 * s);
    // The sound sat 1 s into a (its 1 s of film): now 0.5 s in.
    expect(startOf(c, 'music'), 500000);
  });

  test('slowing the clip a layer is on keeps it on its frame', () {
    final c = setUp();
    c.apply(c.project.updateClip(idOf(c, 'b'), (x) => x.copyWith(speed: 0.5)));
    expect(startOf(c, 'Hi'), 6 * s);
    expect(startOf(c, 'music'), 1 * s);
  });

  test('a moved layer sticks to its new frame', () {
    final c = setUp();
    final text = c.project.textTracks.single.clips.single;
    c.apply(c.project.moveAudioClip(text.id, 2 * s)); // now in a
    expect(startOf(c, 'Hi'), 2 * s);
    c.apply(c.project.insertMedia([video('intro', 3)], index: 0));
    expect(startOf(c, 'Hi'), 5 * s);
  });

  test('when its frame is deleted the layer stays where it was', () {
    final c = setUp();
    c.apply(c.project.deleteClip(idOf(c, 'b')));
    expect(startOf(c, 'Hi'), 5 * s);
    // ...and from then on it follows nothing until there is video there.
    c.apply(c.project.insertMedia([video('c', 6)]));
    // c fills 4-10 s: the text is re-attached to c's frame at 5 s.
    c.apply(c.project.insertMedia([video('intro', 1)], index: 0));
    expect(startOf(c, 'Hi'), 6 * s);
  });

  test('a split clip keeps its layers on the right half', () {
    final c = setUp();
    c.apply(c.project.splitAt(6 * s)); // b becomes 4-6 and 6-8
    c.apply(c.project.insertMedia([video('intro', 2)], index: 0));
    expect(startOf(c, 'Hi'), 7 * s);
  });

  test('anchors are saved with the project', () {
    final c = setUp();
    final text = c.project.textTracks.single.clips.single;
    expect(text.anchor, isNotNull);
    final back = Project.fromJson(c.project.toJson());
    expect(back.textTracks.single.clips.single.anchor, text.anchor);
  });
}
