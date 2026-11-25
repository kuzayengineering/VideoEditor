import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/ffmpeg/ffmpeg_commands.dart';
import 'package:video_editor/engine/mp4_location.dart';

void main() {
  final hasFfmpeg = Process.runSync('which', ['ffmpeg']).exitCode == 0;

  Future<void> check(List<String> extra, String name) async {
    final dir = await Directory.systemTemp.createTemp('loc');
    final f = File('${dir.path}/$name.mp4');
    final r = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=s=320x240:d=1',
      ...extra,
      f.path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    await setMp4Location(f, '+37.4219-122.0840/');
    final p = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format_tags',
      '-of',
      'json',
      f.path,
    ]);
    expect(locationFromProbeJson('${p.stdout}'), '+37.4219-122.0840/');
    // The phone-style entry itself is there.
    expect(
      latin1.decode(await f.readAsBytes(), allowInvalid: true),
      contains('©xyz'),
    );
    // And the video still plays to the end without errors.
    final play = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-i',
      f.path,
      '-f',
      'null',
      '-',
    ]);
    expect(play.exitCode, 0);
    expect('${play.stderr}'.trim(), isEmpty);
    // Setting it again replaces it.
    await setMp4Location(f, '-33.8688+151.2093/');
    final p2 = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format_tags',
      '-of',
      'json',
      f.path,
    ]);
    expect(locationFromProbeJson('${p2.stdout}'), '-33.8688+151.2093/');
    await dir.delete(recursive: true);
  }

  test('location in a file with the movie box first (fast start)', () async {
    await check(['-movflags', '+faststart'], 'fast');
  }, skip: !hasFfmpeg);

  test('location in a file with the movie box last', () async {
    await check([], 'last');
  }, skip: !hasFfmpeg);
}
