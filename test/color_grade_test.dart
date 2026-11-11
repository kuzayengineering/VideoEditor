import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';

void main() {
  test('no filter changes nothing', () {
    final c = applyGrade(GradeParams.neutral, 0.3, 0.6, 0.9);
    expect(c.r, closeTo(0.3, 1e-9));
    expect(c.g, closeTo(0.6, 1e-9));
    expect(c.b, closeTo(0.9, 1e-9));
  });

  test('HDR-safe: white stays white and nothing goes past it', () {
    for (final preset in FilterPreset.values) {
      if (preset == FilterPreset.sepia) continue; // tinted on purpose
      final p = preset.params;
      final w = applyGrade(p, 1, 1, 1);
      for (final v in [w.r, w.g, w.b]) {
        expect(v, lessThanOrEqualTo(1.0), reason: preset.name);
      }
      // Brightness and contrast never darken pure white unless warmed or
      // tinted (those only turn channels down).
      if (p.warmth == 0 && p.tint == 0) {
        expect(w.g, closeTo(1.0, 1e-9), reason: preset.name);
      }
    }
  });

  test('brightness and contrast keep the order of tones', () {
    for (final p in [
      const GradeParams(brightness: 1),
      const GradeParams(brightness: -1),
      const GradeParams(contrast: 1),
      const GradeParams(contrast: -1),
    ]) {
      var last = -1.0;
      for (var i = 0; i <= 100; i++) {
        final v = applyGrade(p, i / 100, i / 100, i / 100).g;
        expect(v, greaterThanOrEqualTo(last - 1e-9));
        last = v;
      }
    }
  });

  test('black & white has no colour; strength blends the look in', () {
    final m = applyGrade(FilterPreset.mono.params, 0.8, 0.3, 0.1);
    expect(m.r, closeTo(m.g, 1e-9));
    expect(m.g, closeTo(m.b, 1e-9));
    const half = ColorGrade(preset: FilterPreset.vivid, strength: 0.5);
    expect(half.params.saturation, closeTo(0.175, 1e-9));
    const plus = ColorGrade(
      preset: FilterPreset.warm,
      adjust: GradeParams(warmth: 0.8),
    );
    expect(plus.params.warmth, 1.0); // kept within range
  });

  test('saved with the clip', () {
    const g = ColorGrade(
      preset: FilterPreset.cinematic,
      strength: 0.7,
      adjust: GradeParams(brightness: 0.2, fade: 0.3),
    );
    final clip = Clip(
      id: 1,
      kind: ClipKind.video,
      name: 'x',
      sourceDurationUs: 1000000,
      sourceInUs: 0,
      sourceOutUs: 1000000,
      grade: g,
    );
    final back = Clip.fromJson(
      (jsonDecode(jsonEncode(clip.toJson())) as Map).cast<String, Object?>(),
    );
    expect(back.grade, g);
    expect(back.hasLook, isTrue);
    expect(clip.copyWith(grade: const ColorGrade()).hasLook, isFalse);
  });

  test('the live colour mix is close to the real maths', () {
    final id = gradeMatrix(GradeParams.neutral);
    expect(id[0], closeTo(1, 1e-6));
    expect(id[4], closeTo(0, 1e-3));
    final p = FilterPreset.warm.params;
    final m = gradeMatrix(p);
    // Mid grey through the matrix vs through the maths.
    const x = 0.5;
    final want = applyGrade(p, x, x, x);
    final r = m[0] * x + m[1] * x + m[2] * x + m[4] / 255;
    final b = m[10] * x + m[11] * x + m[12] * x + m[14] / 255;
    expect(r, closeTo(want.r, 0.05));
    expect(b, closeTo(want.b, 0.05));
  });

  test('lookup table file has the right size and corners', () {
    final cube = gradeCube(GradeParams.neutral, size: 5);
    final rows = cube
        .split('\n')
        .where((l) => RegExp(r'^[0-9.]+ [0-9.]+ [0-9.]+$').hasMatch(l))
        .toList();
    expect(rows.length, 125);
    expect(rows.first, '0.000000 0.000000 0.000000');
    expect(rows[1], '0.250000 0.000000 0.000000'); // red changes fastest
    expect(rows.last, '1.000000 1.000000 1.000000');
  });

  test('shadows, highlights and HDR intensity', () {
    for (final p in [
      const GradeParams(shadows: 1),
      const GradeParams(shadows: -1),
      const GradeParams(highlights: 1),
      const GradeParams(highlights: -1),
      const GradeParams(hdr: 1),
      const GradeParams(hdr: -1),
    ]) {
      var last = -1.0;
      for (var i = 0; i <= 200; i++) {
        final v = applyGrade(p, i / 200, i / 200, i / 200).g;
        expect(v, greaterThanOrEqualTo(last - 1e-9), reason: '${p.toJson()}');
        expect(v, lessThanOrEqualTo(1.0));
        last = v;
      }
    }
    double g(GradeParams p, double x, {double knee = kneeHlg}) =>
        applyGrade(p, x, x, x, knee: knee).g;
    // Shadows lift dark tones, leave white alone.
    expect(g(const GradeParams(shadows: 1), 0.2), greaterThan(0.3));
    expect(g(const GradeParams(shadows: 1), 1), closeTo(1, 1e-9));
    // Highlights down recovers bright tones, leaves black alone.
    expect(g(const GradeParams(highlights: -1), 0.8), lessThan(0.7));
    expect(g(const GradeParams(highlights: -1), 0), closeTo(0, 1e-9));
    // HDR intensity only works above paper white.
    expect(g(const GradeParams(hdr: 1), 0.6), closeTo(0.6, 1e-9));
    expect(g(const GradeParams(hdr: 1), 0.85), greaterThan(0.85));
    expect(g(const GradeParams(hdr: -1), 0.85), lessThan(0.85));
    expect(g(const GradeParams(hdr: -1), 1.0), closeTo(0.875, 1e-9));
    // PQ's paper white is lower.
    expect(g(const GradeParams(hdr: -1), 0.7, knee: kneePq), lessThan(0.7));
  });
}
