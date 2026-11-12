// Real speech recognition: downloads the small English model (once per run)
// and captions the JFK sample (a public-domain recording).
//
// Runs when VC_CAPTIONS_LIB points at a built native/captions library and
// FFmpeg is installed (the automatic build does both).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/captions/caption_maker.dart';
import 'package:video_editor/captions/speech_models.dart';
import 'package:video_editor/engine/ffmpeg/ffmpeg_commands.dart';
import 'package:video_editor/engine/ffmpeg/ffmpeg_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

void main() {
  final lib = Platform.environment['VC_CAPTIONS_LIB'];
  final skip = lib == null || !File(lib).existsSync()
      ? 'VC_CAPTIONS_LIB is not set'
      : null;

  test(
    'captions the JFK sample with word timing',
    () async {
      final dir = await Directory.systemTemp.createTemp('vc_captions');
      addTearDown(() => dir.delete(recursive: true));
      final video = '${dir.path}/jfk.mp4';
      final r = await Process.run('ffmpeg', [
        '-v', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=gray:s=320x180:r=30:d=13',
        '-i', 'test/assets/jfk.wav',
        // Two seconds of silence first, to check the timing.
        '-af', 'adelay=2000:all=1',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-shortest', video,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final probe = await Process.run('ffprobe', [...probeArgsPrefix, video]);
      final info = parseProbeJson('${probe.stdout}');

      final clip = Clip(
        id: 0,
        kind: ClipKind.video,
        name: 'jfk',
        sourcePath: video,
        media: info,
        sourceDurationUs: info.durationUs,
        sourceInUs: 0,
        sourceOutUs: info.durationUs,
      );
      final project = Project.empty(id: 'p', frameRate: 30).insertMedia([clip]);
      final cache = Platform.environment['VC_MODEL_DIR'];
      final maker = CaptionMaker(
        FfmpegEngine(ffmpegPath: 'ffmpeg', ffprobePath: 'ffprobe'),
        store: SpeechModelStore(
          folder: () async => cache != null ? Directory(cache) : dir,
        ),
      );
      final statuses = <String>{};
      final lines = await maker.make(
        project,
        accuracy: CaptionAccuracy.fast,
        english: true,
        onStatus: (m, _) => statuses.add(m),
      );
      final text = lines.map((l) => l.text).join(' ').toLowerCase();
      expect(text, contains('fellow americans'));
      expect(text, contains('ask not what your country can do for you'));
      expect(lines.length, greaterThan(1));
      // Speech starts at about 2.3 s (2 s of added silence).
      expect(lines.first.startUs, inInclusiveRange(2000000, 3200000));
      expect(lines.last.endUs, lessThanOrEqualTo(13 * usPerSecond));
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i].startUs, greaterThanOrEqualTo(lines[i - 1].endUs));
      }
      expect(statuses, contains('Listening to the speech…'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
