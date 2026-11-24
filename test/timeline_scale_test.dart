import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/ui/timeline_scale.dart';

const s = 1000000;

void main() {
  test('even scale when every clip is wide enough', () {
    final sc = TimelineScale(100, [(0, 4 * s, 60), (4 * s, 8 * s, 60)]);
    expect(sc.xOf(2 * s), closeTo(200, 1e-6));
    expect(sc.xOf(10 * s), closeTo(1000, 1e-6));
    expect(sc.timeAt(450), 4500000);
  });

  test('a short clip is spread out to a square; later clips shift along', () {
    // a 0-4 s, b 4-4.1 s (10 px at 100 px/s, needs 60), c 4.1-8 s.
    final sc = TimelineScale(100, [
      (0, 4 * s, 60),
      (4 * s, 4100000, 60),
      (4100000, 8 * s, 60),
    ]);
    expect(sc.xOf(4 * s), closeTo(400, 1e-6)); // a unchanged
    expect(sc.xOf(4100000) - sc.xOf(4 * s), closeTo(60, 1e-6)); // b square
    expect(sc.xOf(8 * s) - sc.xOf(4100000), closeTo(390, 1e-6)); // c as is
    // Back and forth agree, also inside the spread-out part.
    for (final t in [0, 3 * s, 4050000, 4100000, 6 * s, 20 * s]) {
      expect((sc.timeAt(sc.xOf(t)) - t).abs(), lessThanOrEqualTo(1));
    }
    // Zoomed in far enough, nothing is spread.
    final near = TimelineScale(1000, [(4 * s, 4100000, 60)]);
    expect(near.xOf(4100000) - near.xOf(4 * s), closeTo(100, 1e-6));
  });

  test('a short clip on another row spreads that stretch for all rows', () {
    // Main 0-10 s; a 0.05 s sound at 2 s (needs 34 px).
    final sc = TimelineScale(100, [(0, 10 * s, 60), (2 * s, 2050000, 34)]);
    expect(sc.xOf(2050000) - sc.xOf(2 * s), closeTo(34, 1e-6));
    expect(sc.xOf(10 * s), closeTo(1000 - 5 + 34, 1e-6));
  });
}
