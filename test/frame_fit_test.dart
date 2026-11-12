import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';

const s = usPerSecond;

Clip video(String name, {int w = 1920, int h = 1080}) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: name,
  sourcePath: '$name.mp4',
  media: MediaInfo(durationUs: 5 * s, width: w, height: h, frameRate: 30),
  sourceDurationUs: 5 * s,
  sourceInUs: 0,
  sourceOutUs: 5 * s,
);

void main() {
  test('Fill frame cuts the middle to the frame shape; Fit undoes it', () {
    final portrait = video('p', w: 1080, h: 1920);
    expect(portrait.matchesShape(16 / 9), isFalse);
    final filled = portrait.filled(16 / 9);
    expect(filled.fills, isTrue);
    expect(filled.matchesShape(16 / 9), isTrue);
    // Full width, the middle 31.6 % of the height.
    expect(filled.crop.left, 0);
    expect(filled.crop.right, 1);
    expect(filled.crop.height, closeTo(1080 * 9 / 16 / 1920, 1e-9));
    expect(filled.crop.top, closeTo((1 - filled.crop.height) / 2, 1e-9));
    final back = filled.fitted();
    expect(back.fills, isFalse);
    expect(back.crop, CropRect.full);

    // Within an existing crop.
    final cropped = video('w')
        .copyWith(crop: const CropRect(0.1, 0, 0.9, 1))
        .filled(1);
    expect(cropped.crop.top, 0);
    expect(cropped.crop.width * 1920, closeTo(1080, 1e-6));
    expect(cropped.crop.left + cropped.crop.width / 2, closeTo(0.5, 1e-9));
    expect(cropped.fitted().crop, const CropRect(0.1, 0, 0.9, 1));
  });

  test('changing the frame shape re-cuts filling clips', () {
    var p = Project.empty(
      id: 'x',
      frameRate: 30,
    ).insertMedia([video('a'), video('b', w: 1080, h: 1920)]);
    final id = p.mainTrack.clips[1].id;
    p = p.updateClip(id, (c) => c.filled(p.canvas.value));
    p = p.withCanvas(CanvasRatio.square);
    final b = p.mainTrack.clips[1];
    expect(b.fills, isTrue);
    expect(b.matchesShape(1), isTrue);
    expect(p.mainTrack.clips[0].fills, isFalse);
  });

  test('saved with the clip', () {
    final c = video('p', w: 1080, h: 1920).filled(16 / 9);
    final back = Clip.fromJson(c.toJson());
    expect(back.fillFrom, CropRect.full);
    expect(back.crop, c.crop);
  });

  test('cropping the only clip gives the frame its shape', () {
    final c = EditorController(
      Project.empty(id: 'x', frameRate: 30).insertMedia([video('a')]),
    );
    c.select(c.project.mainTrack.clips.single.id);
    // A square crop from a 16:9 video.
    final changed = c.cropSelected(const CropRect(0.21875, 0, 0.78125, 1));
    expect(changed, isTrue);
    expect(c.project.canvas.sameShapeAs(CanvasRatio.square), isTrue);
    c.undo();
    expect(c.project.canvas.sameShapeAs(CanvasRatio.landscape16x9), isTrue);
    expect(c.project.mainTrack.clips.single.crop, CropRect.full);
  });

  test('with several clips the frame keeps its shape', () {
    final c = EditorController(
      Project.empty(
        id: 'x',
        frameRate: 30,
      ).insertMedia([video('a'), video('b')]),
    );
    c.select(c.project.mainTrack.clips.first.id);
    expect(c.cropSelected(const CropRect(0.21875, 0, 0.78125, 1)), isFalse);
    expect(c.project.canvas.sameShapeAs(CanvasRatio.landscape16x9), isTrue);
    c.matchCanvasToSelected();
    expect(c.project.canvas.sameShapeAs(CanvasRatio.square), isTrue);
  });

  test('turning a filling clip keeps it filling', () {
    final c = EditorController(
      Project.empty(
        id: 'x',
        frameRate: 30,
      ).insertMedia([video('a'), video('b')]),
    );
    c.select(c.project.mainTrack.clips.first.id);
    c.rotateSelected();
    var clip = c.selected!.clip;
    expect(clip.matchesShape(16 / 9), isFalse);
    c.toggleFillSelected();
    clip = c.selected!.clip;
    expect(clip.fills, isTrue);
    expect(clip.matchesShape(16 / 9), isTrue);
    c.rotateSelected();
    clip = c.selected!.clip;
    expect(clip.fills, isTrue);
    expect(clip.matchesShape(16 / 9), isTrue);
    expect(clip.fillFrom, CropRect.full);
    c.toggleFillSelected();
    expect(c.selected!.clip.crop, CropRect.full);
  });
}
