import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/app_settings.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/editor_controller.dart';

const s = usPerSecond;

Clip video(String name) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: name,
  sourcePath: '$name.mp4',
  media: const MediaInfo(durationUs: 60 * s, width: 1920, height: 1080),
  sourceDurationUs: 60 * s,
  sourceInUs: 0,
  sourceOutUs: 4 * s,
);

void main() {
  test('cropped, turned or mirrored clips get a preview copy', () {
    final p = Project.empty(id: 'p', frameRate: 30).insertMedia([video('a')]);
    final id = p.mainTrack.clips.single.id;
    expect(p.speedKey(0), '');
    for (final changed in [
      p.updateClip(id, (c) => c.copyWith(crop: const CropRect(0.1, 0, 1, 1))),
      p.updateClip(id, (c) => c.copyWith(rotation: 1)),
      p.updateClip(id, (c) => c.copyWith(flipH: true)),
    ]) {
      expect(changed.speedKey(0), isNotEmpty);
    }
  });

  test('timeline zoom is remembered per project', () {
    final p = Project.empty(id: 'zoom-test', frameRate: 30);
    final c = EditorController(p);
    c.setZoom(120);
    expect(EditorController(p).pixelsPerSecond, 120);
    AppSettings.instance.forgetProject('zoom-test');
    expect(EditorController(p).pixelsPerSecond, 32);
  });

  test('new texts show at once (no fade-in), and fade out', () {
    const spec = TextSpec(text: 'Hi');
    expect(spec.animIn, TextAnim.none);
    expect(spec.animOut, TextAnim.fade);
  });

  test('text opacity is kept, saved and read back', () {
    const spec = TextSpec(text: 'Hi', colorValue: 0xFFE53935);
    final faded = spec.copyWith(opacity: 0.4, size: 0.1);
    expect(faded.colorValue, 0xFFE53935);
    expect(faded.opacity, 0.4);
    final back = TextSpec.fromJson(faded.toJson());
    expect(back.opacity, 0.4);
    expect(back.colorValue, 0xFFE53935);
    expect(TextSpec.fromJson(spec.toJson()).opacity, 1);
    expect(const TextSpec().colorValue, 0xFFFFFFFF);
  });

  test('main-clip cutout: saved, and sent with the background colour', () {
    final p = Project.empty(id: 'p', frameRate: 30)
        .insertMedia([video('a')])
        .withBackground(const BackgroundFill.color(0xFF102030));
    final id = p.mainTrack.clips.single.id;
    final cut = p.updateClip(id, (c) => c.copyWith(cutout: true));
    final clip = cut.mainTrack.clips.single;
    expect(Clip.fromJson(clip.toJson()).cutout, isTrue);
    final seg = segmentsOf(cut).single;
    expect(seg.hasEffects, isTrue);
    final m = seg.toMap();
    expect(m['cutout'], isTrue);
    expect(m['cutoutFill'], 0xFF102030);
  });

  test('recolour settings are saved and count as a change to the look', () {
    final p = Project.empty(id: 'p', frameRate: 30).insertMedia([video('a')]);
    final id = p.mainTrack.clips.single.id;
    final r = p.updateClip(
      id,
      (c) => c.copyWith(
        partColors: const PartColors(hair: 0xFFE53935, strength: 0.6),
      ),
    );
    final clip = r.mainTrack.clips.single;
    expect(clip.hasLook, isTrue);
    final back = Clip.fromJson(clip.toJson()).partColors!;
    expect(back.hair, 0xFFE53935);
    expect(back.clothes, 0);
    expect(back.strength, 0.6);
    expect(back.colors, [0xFFE53935, 0, 0]);
    // Nothing picked: not saved, no change.
    final none = p.updateClip(
      id,
      (c) => c.copyWith(partColors: const PartColors()),
    );
    expect(none.mainTrack.clips.single.hasLook, isFalse);
  });
}
