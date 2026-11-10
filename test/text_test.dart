import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/text_render.dart';

const s = usPerSecond;

void main() {
  group('animation', () {
    test('fade in and out', () {
      const spec = TextSpec(
        animIn: TextAnim.fade,
        animInUs: s,
        animOut: TextAnim.fade,
        animOutUs: s,
      );
      expect(textFrameAt(spec, 0, 4 * s).alpha, 0);
      expect(textFrameAt(spec, s ~/ 2, 4 * s).alpha, closeTo(0.5, 1e-9));
      expect(textFrameAt(spec, 2 * s, 4 * s).alpha, 1);
      expect(
        textFrameAt(spec, 3 * s + s ~/ 2, 4 * s).alpha,
        closeTo(0.5, 1e-9),
      );
    });

    test('slides arrive from and leave towards their direction', () {
      const up = TextSpec(
        animIn: TextAnim.slideUp,
        animInUs: s,
        animOut: TextAnim.slideUp,
        animOutUs: s,
      );
      expect(
        textFrameAt(up, 0, 4 * s).dy,
        closeTo(slideDistance, 1e-9),
      ); // below
      expect(textFrameAt(up, 2 * s, 4 * s).dy, 0);
      expect(textFrameAt(up, 4 * s - 1, 4 * s).dy, lessThan(-0.11)); // above
      const left = TextSpec(animIn: TextAnim.slideLeft, animInUs: s);
      expect(textFrameAt(left, 0, 4 * s).dx, greaterThan(0)); // from the right
    });

    test('pop grows from half size', () {
      const pop = TextSpec(
        animIn: TextAnim.pop,
        animInUs: s,
        animOut: TextAnim.none,
      );
      expect(textFrameAt(pop, 0, 4 * s).scale, 0.5);
      expect(textFrameAt(pop, s, 4 * s).scale, 1);
    });

    test('typewriter shows letters one by one', () {
      const tw = TextSpec(
        text: 'Hello',
        animIn: TextAnim.typewriter,
        animInUs: s,
        animOut: TextAnim.none,
      );
      expect(textFrameAt(tw, 0, 4 * s).visibleChars, 0);
      expect(textFrameAt(tw, s ~/ 5, 4 * s).visibleChars, 1);
      expect(textFrameAt(tw, s ~/ 2, 4 * s).visibleChars, 3);
      expect(textFrameAt(tw, 2 * s, 4 * s).visibleChars, isNull); // all
    });

    test('animations never take more than half the text each', () {
      const spec = TextSpec(animIn: TextAnim.fade, animInUs: 5 * s);
      expect(textFrameAt(spec, s, 2 * s).alpha, 1);
    });
  });

  group('timeline', () {
    test('texts go on text tracks, stack when overlapping, and save', () {
      var p = Project.empty(id: 'x')
          .addText(Clip.text(const TextSpec(text: 'A'), startUs: 0))
          .addText(Clip.text(const TextSpec(text: 'B'), startUs: s))
          .addText(Clip.text(const TextSpec(text: 'C'), startUs: 5 * s));
      expect(p.textTracks.length, 2);
      expect(p.textsAt(2 * s).map((x) => x.clip.text!.text), ['A', 'B']);
      expect(p.durationUs, 8 * s);

      final a = p.textTracks.first.clips.first.id;
      p = p.trimEnd(a, 10 * s); // can't run into "C" at 5 s
      expect(p.placementOf(a)!.endUs, 5 * s);
      p = p.splitAt(2 * s, clipId: a);
      expect(p.textTracks.first.clips.length, 3);

      final back = Project.fromJson(
        (jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, Object?>(),
      );
      expect(back.textTracks.length, 2);
      expect(back.textTracks.first.clips.first.text!.text, 'A');
      expect(back.textTracks.first.clips.first.kind, ClipKind.text);
    });
  });

  testWidgets('text pictures are drawn at export size', (tester) async {
    // (Widget tests run on simulated time: file work must be synchronous
    // or wrapped in runAsync.)
    final dir = Directory.systemTemp.createTempSync('ve_text_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final p = Project.empty(id: 'x').addText(
      Clip.text(
        const TextSpec(
          text: 'Hey',
          animIn: TextAnim.typewriter,
          boxColorValue: 0x80000000,
          outline: 0.05,
          rotation: 15,
        ),
        startUs: 0,
      ),
    );
    final images = await tester.runAsync(
      () => renderTextImages(p, 1920, 1080, dir),
    );
    final img = images!.values.single;
    expect(img.width.isEven && img.height.isEven, isTrue);
    expect(img.height, greaterThan(1080 * 0.08)); // at least the letter size
    expect(img.typewriterPaths.length, 4); // 0..3 letters
    expect(File(img.fullPath).lengthSync(), greaterThan(100));
  });
}
