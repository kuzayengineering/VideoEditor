import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/captions/caption_maker.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

const s = usPerSecond;
const ms = 1000;

List<SpokenWord> words(String text, {int startMs = 0, int stepMs = 300}) {
  final out = <SpokenWord>[];
  var t = startMs;
  for (final w in text.split(' ')) {
    out.add(SpokenWord(t * ms, (t + stepMs - 50) * ms, w));
    t += stepMs;
  }
  return out;
}

void main() {
  test('words are grouped into short lines at sentences and pauses', () {
    final lines = groupCaptions([
      ...words('Hello there. How are you today?'),
      // A long pause, then more.
      ...words('Fine thanks', startMs: 5000),
    ]);
    expect(lines.map((l) => l.text), [
      'Hello there.',
      'How are you today?',
      'Fine thanks',
    ]);
    // No overlaps, in order, each shown at least 0.8 s.
    for (var i = 0; i < lines.length; i++) {
      expect(lines[i].endUs - lines[i].startUs, greaterThanOrEqualTo(600 * ms));
      if (i > 0) {
        expect(lines[i].startUs, greaterThanOrEqualTo(lines[i - 1].endUs));
      }
    }
    expect(lines.first.startUs, 0);
  });

  test('long sentences are split to fit the screen', () {
    final lines = groupCaptions(
      words(
        'this is a rather long sentence that keeps going on and on without '
        'any punctuation at all until the very end',
        stepMs: 200,
      ),
    );
    expect(lines.length, greaterThan(2));
    for (final l in lines) {
      expect(l.text.length, lessThanOrEqualTo(32));
    }
    expect(
      lines.map((l) => l.text).join(' '),
      'this is a rather long sentence that keeps going on and on without '
      'any punctuation at all until the very end',
    );
  });

  test('punctuation joins the word before it', () {
    expect(joinWords(['Hello', ',', 'world', '!']), 'Hello, world!');
    expect(joinWords(["it", "'s", 'fine']), "it's fine");
  });

  test('words are moved onto the timeline with the clip speed', () {
    final clip = Clip(
      id: 1,
      kind: ClipKind.video,
      name: 'v',
      sourcePath: 'v.mp4',
      media: const MediaInfo(durationUs: 10 * s, width: 1920, height: 1080),
      sourceDurationUs: 10 * s,
      sourceInUs: 2 * s,
      sourceOutUs: 6 * s,
      speed: 2,
    );
    var p = Project.empty(id: 'p', frameRate: 30).insertMedia([clip]);
    p = p.insertMedia([clip.copyWith(speed: 1)], index: 0);
    final placed = p.placementsOn(p.mainTrack)[1]; // starts at 4 s, 2 s long
    final moved = CaptionMaker.placeWords(placed, [
      const SpokenWord(1 * s, 2 * s, 'one'),
      const SpokenWord(3 * s, 3500 * ms, 'two'),
      const SpokenWord(5 * s, 6 * s, 'gone'), // past the clip's end
    ]);
    expect(moved.map((w) => (w.startUs, w.endUs, w.text)), [
      (4500 * ms, 5 * s, 'one'),
      (5500 * ms, 5750 * ms, 'two'),
    ]);
  });

  test('captions go on their own row and are replaced when redone', () {
    final clip = Clip(
      id: 1,
      kind: ClipKind.video,
      name: 'v',
      sourcePath: 'v.mp4',
      media: const MediaInfo(durationUs: 10 * s, width: 1920, height: 1080),
      sourceDurationUs: 10 * s,
      sourceInUs: 0,
      sourceOutUs: 10 * s,
    );
    var p = Project.empty(id: 'p', frameRate: 30).insertMedia([clip]);
    p = p.addText(Clip.text(const TextSpec(text: 'Title'), startUs: 0));
    const style = TextSpec(size: 0.06);
    p = p.withCaptions(
      const [CaptionLine(0, s, 'Hi'), CaptionLine(s, 2 * s, 'there')],
      style,
      fromUs: 0,
      toUs: 10 * s,
    );
    expect(p.textTracks.length, 2);
    final row = p.textTracks.firstWhere((t) => t.captions);
    expect(row.clips.map((c) => c.text!.text), ['Hi', 'there']);
    expect(row.clips.first.text!.size, 0.06);
    // Saved and loaded: still the captions row.
    final back = Project.fromJson(p.toJson());
    expect(back.textTracks.where((t) => t.captions).length, 1);
    // Redo part of it: only that part is replaced.
    p = p.withCaptions(
      const [CaptionLine(1200 * ms, 2 * s, 'everyone')],
      style,
      fromUs: s,
      toUs: 3 * s,
    );
    final again = p.textTracks.firstWhere((t) => t.captions);
    expect(again.clips.map((c) => c.text!.text), ['Hi', 'everyone']);
    expect(p.textTracks.length, 2);
    // Unique ids.
    final ids = [
      for (final t in [p.mainTrack, ...p.textTracks])
        for (final c in t.clips) c.id,
    ];
    expect(ids.toSet().length, ids.length);
  });
}
