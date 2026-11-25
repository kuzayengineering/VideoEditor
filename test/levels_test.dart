import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/color_grade.dart';

void main() {
  test('black and white points set the ends of the range', () {
    double grey(GradeParams p, double v) => applyGrade(p, v, v, v).r;
    // Positive: the darkest 15 % become black, the brightest 15 % white.
    const deep = GradeParams(blackPoint: 1, whitePoint: 1);
    expect(grey(deep, 0.1), 0);
    expect(grey(deep, 0.9), 1);
    expect(grey(deep, 0.5), closeTo(0.5, 1e-9));
    // Negative: black raised, white lowered.
    const soft = GradeParams(blackPoint: -1, whitePoint: -1);
    expect(grey(soft, 0), closeTo(0.15, 1e-9));
    expect(grey(soft, 1), closeTo(0.85, 1e-9));
    // Saved and read back.
    const p = GradeParams(blackPoint: 0.3, whitePoint: -0.2);
    expect(GradeParams.fromJson(p.toJson()), p);
    expect(p.values.length, 11);
  });
}
