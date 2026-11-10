// Checks that our transition maths (used for Android's real transitions and
// for the picker's little previews) draws the same pictures as FFmpeg's
// xfade filter, which the Windows version uses. Skipped without FFmpeg.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/transition_math.dart';

const w = 64, h = 48;

/// Two easy-to-tell-apart test pictures with gradients and shapes, so a
/// shift or a flipped direction shows up as a big difference.
Uint8List picture(bool second) {
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      if (!second) {
        final square = x > 8 && x < 24 && y > 6 && y < 20;
        out[i] = square ? 255 : 40 + x * 3;
        out[i + 1] = square ? 255 : 20 + y * 4;
        out[i + 2] = square ? 255 : 30;
      } else {
        final checker = ((x ~/ 8) + (y ~/ 8)).isEven;
        out[i] = 20;
        out[i + 1] = checker ? 200 : 90 + y;
        out[i + 2] = 240 - x * 2;
      }
    }
  }
  return out;
}

Sampler sampler(Uint8List img) => (u, v) {
  final x = (u * w).floor().clamp(0, w - 1);
  final y = (v * h).floor().clamp(0, h - 1);
  final i = (y * w + x) * 3;
  return (r: img[i] / 255, g: img[i + 1] / 255, b: img[i + 2] / 255);
};

bool get hasFfmpeg {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  final skip = hasFfmpeg ? false : 'FFmpeg is not installed';
  late Directory dir;
  late Set<String> known;
  final a = picture(false), b = picture(true);

  setUpAll(() {
    if (!hasFfmpeg) return;
    dir = Directory.systemTemp.createTempSync('xfade');
    // 2 s of each picture, 10 frames a second.
    File('${dir.path}/a.rgb')
        .writeAsBytesSync([for (var i = 0; i < 20; i++) ...a]);
    File('${dir.path}/b.rgb')
        .writeAsBytesSync([for (var i = 0; i < 20; i++) ...b]);
    final help = Process.runSync('ffmpeg', [
      '-hide_banner',
      '-h',
      'filter=xfade',
    ]);
    known = RegExp(
      r'^\s+(\w+)\s+-?\d*\s',
      multiLine: true,
    ).allMatches('${help.stdout}').map((m) => m.group(1)!).toSet();
  });

  tearDownAll(() {
    if (hasFfmpeg) dir.deleteSync(recursive: true);
  });

  for (final kind in TransitionKind.values.where((k) => !k.isDip)) {
    test('${kind.label} matches FFmpeg', () {
      if (!known.contains(kind.ffmpegName)) {
        markTestSkipped('this FFmpeg has no ${kind.ffmpegName}');
        return;
      }
      final raw = [
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgb24',
        '-s',
        '${w}x$h',
        '-framerate',
        '10',
      ];
      final r = Process.runSync('ffmpeg', [
        '-v',
        'error',
        ...raw,
        '-i',
        '${dir.path}/a.rgb',
        ...raw,
        '-i',
        '${dir.path}/b.rgb',
        '-filter_complex',
        '[0]format=gbrp[x];[1]format=gbrp[y];'
            '[x][y]xfade=transition=${kind.ffmpegName}:duration=1:offset=0.5,'
            'format=rgb24',
        '-f',
        'rawvideo',
        '-y',
        '${dir.path}/out.rgb',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = File('${dir.path}/out.rgb').readAsBytesSync();
      final frame = w * h * 3;
      // Frame 5 + k is k tenths into the transition.
      for (final k in [2, 5, 8]) {
        final t = k / 10;
        final ff = Uint8List.sublistView(out, (5 + k) * frame, (6 + k) * frame);
        var far = 0, bFromFf = 0, bFromOurs = 0;
        var sum = 0.0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final c = transitionPixel(
              kind.code,
              x / w,
              y / h,
              t,
              w.toDouble(),
              h.toDouble(),
              sampler(a),
              sampler(b),
            );
            final i = (y * w + x) * 3;
            final d =
                ((c.r * 255 - ff[i]).abs() +
                    (c.g * 255 - ff[i + 1]).abs() +
                    (c.b * 255 - ff[i + 2]).abs()) /
                3;
            sum += d;
            if (d > 40) far++;
            // How much looks like the incoming picture (its blue).
            if (ff[i + 2] > 120 && ff[i] < 60) bFromFf++;
            if (c.b * 255 > 120 && c.r * 255 < 60) bFromOurs++;
          }
        }
        final n = w * h;
        if (kind == TransitionKind.dissolve) {
          // Random speckles: compare how much of each picture shows.
          expect(
            (bFromFf - bFromOurs).abs() / n,
            lessThan(0.08),
            reason: 't=$t',
          );
        } else {
          expect(
            far / n,
            lessThan(0.05),
            reason: 't=$t: ${far * 100 ~/ n}% differ',
          );
          expect(sum / n, lessThan(12), reason: 't=$t: mean ${sum / n}');
        }
      }
    }, skip: skip);
  }
}
