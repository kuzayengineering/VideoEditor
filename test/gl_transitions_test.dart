import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/clip.dart';

void main() {
  final gl = TransitionKind.values.where((k) => k.gl).toList();
  final kotlin = File(
    'android/app/src/main/kotlin/com/kuzayengineering/video_editor/GlTransitions.kt',
  ).readAsStringSync();

  test('gl-transitions: numbers are unique and from 100', () {
    final codes = TransitionKind.values.map((k) => k.code).where((c) => c > 0);
    expect(codes.toSet().length, codes.length);
    expect(gl.length, greaterThan(80));
    for (final k in gl) {
      expect(k.code, greaterThanOrEqualTo(100));
    }
  });

  test('gl-transitions: each has a picker strip and an Android shader', () {
    for (final k in gl) {
      expect(
        File('assets/transitions/${k.glName}.webp').existsSync(),
        isTrue,
        reason: k.name,
      );
      expect(kotlin, contains('${k.code} to """'), reason: k.name);
    }
  });

  test('gl-transitions: Windows stand-ins are FFmpeg names in use', () {
    final builtIn = TransitionKind.values
        .where((k) => !k.gl)
        .map((k) => k.ffmpegName)
        .toSet();
    for (final k in gl) {
      expect(builtIn, contains(k.ffmpegName), reason: k.name);
    }
  });
}
