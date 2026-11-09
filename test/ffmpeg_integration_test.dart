// Runs real FFmpeg exports on small generated clips (HDR and SDR, with and
// without sound, portrait and landscape) and checks the results.
//
// Skipped automatically when FFmpeg with libx264/libx265 isn't installed.
// (The Windows app uses hardware encoders instead; the filter graph is the
// same.)
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/ffmpeg/ffmpeg_commands.dart';
import 'package:video_editor/model/export_settings.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

bool _hasFfmpeg() {
  try {
    final r = Process.runSync('ffmpeg', ['-hide_banner', '-encoders']);
    final out = '${r.stdout}';
    return r.exitCode == 0 &&
        out.contains('libx265') &&
        out.contains('libx264');
  } catch (_) {
    return false;
  }
}

Future<void> _run(List<String> args) async {
  final r = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    ...args,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
}

Future<MediaInfo> _probe(String path) async {
  final r = await Process.run('ffprobe', [...probeArgsPrefix, path]);
  return parseProbeJson('${r.stdout}');
}

Future<double> _avgLuma(String path, {double atSeconds = 0.1}) async {
  final r = await Process.run('ffmpeg', [
    '-hide_banner',
    '-v',
    'error',
    '-ss',
    '$atSeconds',
    '-i',
    path,
    '-vf',
    'signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-',
    '-frames:v',
    '1',
    '-f',
    'null',
    '-',
  ]);
  final m = RegExp(r'YAVG=([0-9.]+)').firstMatch('${r.stdout}${r.stderr}');
  return double.parse(m!.group(1)!);
}

void main() {
  final available = _hasFfmpeg();
  late Directory dir;
  late String hlg, sdr, rotated, silent, sdrWhite, hlgWhite;

  setUpAll(() async {
    if (!available) return;
    dir = await Directory.systemTemp.createTemp('ve_ffmpeg_');
    hlg = '${dir.path}/hlg60.mp4';
    sdr = '${dir.path}/sdr30.mp4';
    rotated = '${dir.path}/rotated.mp4';
    silent = '${dir.path}/silent.mp4';
    sdrWhite = '${dir.path}/sdr_white.mp4';
    hlgWhite = '${dir.path}/hlg_white.mp4';
    const hlgTags = [
      '-color_primaries',
      'bt2020',
      '-color_trc',
      'arib-std-b67',
      '-colorspace',
      'bt2020nc',
    ];
    await _run([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=s=1280x720:r=60:d=3',
      '-f',
      'lavfi',
      '-i',
      'sine=f=440:d=3:r=48000',
      '-pix_fmt',
      'yuv420p10le',
      '-c:v',
      'libx265',
      '-preset',
      'ultrafast',
      '-x265-params',
      'log-level=error',
      ...hlgTags,
      '-c:a',
      'aac',
      '-shortest',
      hlg,
    ]);
    await _run([
      '-f',
      'lavfi',
      '-i',
      'testsrc=s=1920x1080:r=30:d=4',
      '-f',
      'lavfi',
      '-i',
      'sine=f=660:d=4:r=44100',
      '-pix_fmt',
      'yuv420p',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-c:a',
      'aac',
      '-shortest',
      sdr,
    ]);
    await _run(['-display_rotation', '90', '-i', sdr, '-c', 'copy', rotated]);
    await _run([
      '-f',
      'lavfi',
      '-i',
      'smptebars=s=1280x720:r=30:d=2',
      '-pix_fmt',
      'yuv420p',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      silent,
    ]);
    await _run([
      '-f',
      'lavfi',
      '-i',
      'color=c=white:s=320x180:r=30:d=1',
      '-pix_fmt',
      'yuv420p',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-color_primaries',
      'bt709',
      '-color_trc',
      'bt709',
      '-colorspace',
      'bt709',
      sdrWhite,
    ]);
    await _run([
      '-f',
      'lavfi',
      '-i',
      'color=c=black:s=320x180:r=30:d=1,format=yuv420p10le,lutyuv=y=721:u=512:v=512',
      '-pix_fmt',
      'yuv420p10le',
      '-c:v',
      'libx265',
      '-preset',
      'ultrafast',
      '-x265-params',
      'log-level=error',
      ...hlgTags,
      hlgWhite,
    ]);
  });

  tearDownAll(() async {
    if (available) await dir.delete(recursive: true);
  });

  Clip clipFor(String path, MediaInfo info, {int inUs = 0, int? outUs}) => Clip(
    id: 0,
    kind: ClipKind.video,
    name: path.split('/').last,
    sourcePath: path,
    media: info,
    sourceDurationUs: info.durationUs,
    sourceInUs: inUs,
    sourceOutUs: outUs ?? info.durationUs,
  );

  group(
    'ffmpeg',
    skip: available ? false : 'FFmpeg with x264/x265 not installed',
    () {
      test('probe reads size, rotation, frame rate, HDR and audio', () async {
        final h = await _probe(hlg);
        expect(h.width, 1280);
        expect(h.height, 720);
        expect(h.frameRate, closeTo(60, 0.01));
        expect(h.transfer, ColorTransfer.hlg);
        expect(h.bitDepth, 10);
        expect(h.hasAudio, isTrue);
        expect(h.durationUs, closeTo(3 * usPerSecond, 50000));

        final r = await _probe(rotated);
        expect((r.width, r.height), (1080, 1920));
        expect(r.transfer, ColorTransfer.sdr);

        final s = await _probe(silent);
        expect(s.hasAudio, isFalse);
      });

      test(
        'mixed clips export to HLG with exact frame count and sync',
        () async {
          final infos = [
            for (final p in [hlg, sdr, rotated, silent]) await _probe(p),
          ];
          final project = Project.empty(id: 't').insertMedia([
            clipFor(hlg, infos[0], inUs: 500000, outUs: 2000000), // 1.5 s
            clipFor(sdr, infos[1], inUs: 1000000, outUs: 2000000), // 1.0 s
            clipFor(rotated, infos[2], outUs: 700000), // 0.7 s
            clipFor(silent, infos[3]), // 2.0 s
          ]);
          expect(project.frameRate, 60);
          expect(project.canvas, CanvasRatio.landscape16x9);

          final out = '${dir.path}/out_hlg.mp4';
          const settings = ExportSettings(
            resolution: ExportResolution.p720,
            frameRate: 60,
            quality: ExportQuality.standard,
          );
          final plan = buildExportPlan(
            project: project,
            settings: settings,
            encoder: VideoEncoder.hevcCandidates.firstWhere(
              (e) => e.name == 'libx265',
            ),
            outputPath: out,
          );
          expect(plan.expectedFrames, (1.5 + 1.0 + 0.7 + 2.0) * 60);

          final r = await Process.run('ffmpeg', plan.args);
          expect(r.exitCode, 0, reason: '${r.stderr}');
          expect('${r.stdout}', contains('progress=end'));

          final v = await Process.run('ffprobe', verifyArgs(out));
          final check = parseVerification(
            '${v.stdout}',
            plan.expectedFrames,
            plan.durationUs,
          );
          expect(check.actualFrames, plan.expectedFrames);
          expect(check.ok, isTrue);
          expect(check.isHdr, isTrue);

          final info = await _probe(out);
          expect((info.width, info.height), (1280, 720));
          expect(info.transfer, ColorTransfer.hlg);
          expect(info.bitDepth, 10);
          expect(info.hasAudio, isTrue);

          // Audio must last exactly as long as the video.
          final a = await Process.run('ffprobe', [
            '-v',
            'error',
            '-select_streams',
            'a:0',
            '-show_entries',
            'stream=duration',
            '-of',
            'csv=p=0',
            out,
          ]);
          expect(double.parse('${a.stdout}'.trim()), closeTo(5.2, 0.03));
        },
      );

      test('SDR export with H.264 at 30 fps', () async {
        final info = await _probe(hlg);
        final project = Project.empty(id: 't')
            .insertMedia([clipFor(hlg, info)]);
        final out = '${dir.path}/out_sdr.mp4';
        final settings = const ExportSettings(resolution: ExportResolution.p720)
            .copyWith(
              dynamicRange: DynamicRange.sdr,
              codec: VideoCodec.h264,
              frameRate: 30,
            );
        final plan = buildExportPlan(
          project: project,
          settings: settings,
          encoder: VideoEncoder.h264Candidates.firstWhere(
            (e) => e.name == 'libx264',
          ),
          outputPath: out,
        );
        final r = await Process.run('ffmpeg', plan.args);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final v = await Process.run('ffprobe', verifyArgs(out));
        final check = parseVerification(
          '${v.stdout}',
          plan.expectedFrames,
          plan.durationUs,
        );
        expect(check.actualFrames, 90);
        expect(check.isHdr, isFalse);
      });

      test('brightness: SDR white -> HLG reference white, and back', () async {
        Future<double> exportLuma(String src, DynamicRange range) async {
          final info = await _probe(src);
          final project = Project.empty(id: 't')
              .insertMedia([clipFor(src, info)]);
          final out = '${dir.path}/lvl_${range.name}_${src.hashCode}.mp4';
          final settings = const ExportSettings(
            resolution: ExportResolution.p720,
          ).copyWith(dynamicRange: range, frameRate: 30);
          final enc = range.isHdr ? 'libx265' : 'libx264';
          final plan = buildExportPlan(
            project: project,
            settings: settings.copyWith(
              codec: range.isHdr ? VideoCodec.hevc : VideoCodec.h264,
            ),
            encoder: [
              ...VideoEncoder.hevcCandidates,
              ...VideoEncoder.h264Candidates,
            ].firstWhere((e) => e.name == enc),
            outputPath: out,
          );
          final r = await Process.run('ffmpeg', plan.args);
          expect(r.exitCode, 0, reason: '${r.stderr}');
          return _avgLuma(out);
        }

        // Canvas is 16:9 and so is the source, so the frame is fully covered.
        expect(await exportLuma(sdrWhite, DynamicRange.hlg), closeTo(721, 6));
        expect(await exportLuma(sdrWhite, DynamicRange.hdr10), closeTo(572, 6));
        final sdrFromHdr = await exportLuma(hlgWhite, DynamicRange.sdr);
        expect(sdrFromHdr, inInclusiveRange(220, 235));
      });

      test('thumbnail of an HDR clip', () async {
        final info = await _probe(hlg);
        final out = '${dir.path}/thumb.jpg';
        final r = await Process.run(
          'ffmpeg',
          thumbnailArgs(hlg, info, 1000000, 90, out),
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final t = await _probe(out);
        expect(t.height, 90);
      });
    },
  );
}
