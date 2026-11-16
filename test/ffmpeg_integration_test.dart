// Runs real FFmpeg exports on small generated clips (HDR and SDR, with and
// without sound, portrait and landscape) and checks the results.
//
// Skipped automatically when FFmpeg with libx264/libx265 isn't installed.
// (The Windows app uses hardware encoders instead; the filter graph is the
// same.)
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/ffmpeg/ffmpeg_commands.dart';
import 'package:video_editor/engine/media_engine.dart';
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

Clip media16x9Placeholder() => const Clip(
  id: 0,
  kind: ClipKind.video,
  name: 'shape',
  sourcePath: 'unused',
  media: MediaInfo(
    durationUs: 1000000,
    width: 1920,
    height: 1080,
    frameRate: 30,
  ),
  sourceDurationUs: 1000000,
  sourceInUs: 0,
  sourceOutUs: 1000000,
);

extension on Project {
  /// Removes the first clip (used to set the canvas shape from a clip that
  /// isn't exported).
  Project deleteFirst() => deleteClip(mainTrack.clips.first.id);
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

      test(
        'picture in picture: placed, timed, see-through and turned',
        () async {
          Future<String> solid(
            String name,
            String color,
            double seconds,
          ) async {
            final path = '${dir.path}/$name.mp4';
            await _run([
              '-f',
              'lavfi',
              '-i',
              'color=c=$color:s=640x360:r=30:d=$seconds',
              '-f',
              'lavfi',
              '-i',
              'sine=f=440:d=$seconds:r=48000',
              '-pix_fmt',
              'yuv420p',
              '-c:v',
              'libx264',
              '-preset',
              'ultrafast',
              '-c:a',
              'aac',
              '-shortest',
              path,
            ]);
            return path;
          }

          final red = await solid('pip_red', 'red', 2);
          final blue = await solid('pip_blue', 'blue', 2);
          final ri = await _probe(red), bi = await _probe(blue);

          Future<List<int>> rgbAt(String path, double t, int x, int y) async {
            final r = await Process.run('ffmpeg', [
              '-hide_banner',
              '-v',
              'error',
              '-ss',
              '$t',
              '-i',
              path,
              '-frames:v',
              '1',
              '-vf',
              'crop=2:2:$x:$y,scale=1:1,format=rgb24',
              '-f',
              'rawvideo',
              '-',
            ], stdoutEncoding: null);
            return (r.stdout as List<int>).take(3).toList();
          }

          Future<String> export(
            String name,
            PipLayout layout, {
            double opacity = 1,
          }) async {
            var project = Project.empty(
              id: 't',
              frameRate: 30,
            ).insertMedia([clipFor(red, ri)]);
            project = project.addOverlay(
              clipFor(
                blue,
                bi,
                outUs: 1000000,
              ).copyWith(startUs: 500000, opacity: opacity, pip: layout),
            );
            final out = '${dir.path}/$name.mp4';
            final plan = buildExportPlan(
              project: project,
              settings: const ExportSettings(resolution: ExportResolution.p720)
                  .copyWith(
                    dynamicRange: DynamicRange.sdr,
                    codec: VideoCodec.h264,
                    frameRate: 30,
                  ),
              encoder: VideoEncoder.h264Candidates.firstWhere(
                (e) => e.name == 'libx264',
              ),
              outputPath: out,
            );
            final r = await Process.run('ffmpeg', plan.args);
            expect(r.exitCode, 0, reason: '${r.stderr}');
            final v = await Process.run('ffprobe', verifyArgs(out));
            expect(
              parseVerification(
                '${v.stdout}',
                plan.expectedFrames,
                plan.durationUs,
              ).actualFrames,
              60,
            );
            return out;
          }

          // Half the width, centred, from 0.5 s to 1.5 s.
          final plain = await export(
            'pip_plain',
            const PipLayout(x: 0.5, y: 0.5, size: 0.5),
          );
          expect(
            (await rgbAt(plain, 1.0, 639, 359))[2],
            greaterThan(200),
          ); // blue
          expect((await rgbAt(plain, 1.0, 20, 20))[0], greaterThan(200)); // red
          expect((await rgbAt(plain, 0.2, 639, 359))[0], greaterThan(200));
          expect((await rgbAt(plain, 1.8, 639, 359))[0], greaterThan(200));
          // Its right edge is at 960 px (the box is 640 × 360).
          expect((await rgbAt(plain, 1.0, 950, 359))[2], greaterThan(200));
          expect((await rgbAt(plain, 1.0, 975, 359))[0], greaterThan(200));

          // Half see-through: a mix.
          final faded = await export(
            'pip_faded',
            const PipLayout(x: 0.5, y: 0.5, size: 0.5),
            opacity: 0.5,
          );
          final mix = await rgbAt(faded, 1.0, 639, 359);
          expect(mix[0], inInclusiveRange(80, 180));
          expect(mix[2], inInclusiveRange(80, 180));

          // Turned 45°: the box's corners are now outside it (red shows),
          // the centre is still blue.
          final turned = await export(
            'pip_turned',
            const PipLayout(x: 0.5, y: 0.5, size: 0.5, angle: 45),
          );
          expect((await rgbAt(turned, 1.0, 639, 359))[2], greaterThan(200));
          expect((await rgbAt(turned, 1.0, 330, 190))[0], greaterThan(200));
        },
      );

      test('picture in picture in an HDR export', () async {
        final info = await _probe(hlg);
        var project = Project.empty(id: 't').insertMedia([clipFor(hlg, info)]);
        project = project.addOverlay(
          clipFor(hlg, info, outUs: 1000000).copyWith(
            startUs: 200000,
            opacity: 0.7,
            rotation: 1,
            pip: const PipLayout(x: 0.3, y: 0.3, size: 0.3, angle: -20),
          ),
        );
        final out = '${dir.path}/pip_hdr.mp4';
        final plan = buildExportPlan(
          project: project,
          settings: const ExportSettings(resolution: ExportResolution.p720)
              .copyWith(dynamicRange: DynamicRange.hlg, frameRate: 30),
          encoder: VideoEncoder.hevcCandidates.firstWhere(
            (e) => e.name == 'libx265',
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
        expect(check.ok, isTrue);
        expect(check.isHdr, isTrue);
      });

      test(
        'filters: exact on a colour, colourless mono, unchanged when tiny',
        () async {
          // A solid colour (SDR) to compare against the filter maths.
          final orange = '${dir.path}/grade_src.mp4';
          await _run([
            '-f',
            'lavfi',
            '-i',
            'color=c=0xC07040:s=320x180:r=30:d=1',
            '-pix_fmt',
            'yuv444p',
            '-c:v',
            'libx264',
            '-qp',
            '0',
            '-color_primaries',
            'bt709',
            '-color_trc',
            'bt709',
            '-colorspace',
            'bt709',
            orange,
          ]);
          final oi = await _probe(orange);

          Future<String> export(
            String src,
            MediaInfo info,
            ColorGrade? grade,
            String name,
            DynamicRange range,
          ) async {
            final project = Project.empty(
              id: 't',
              frameRate: 30,
            ).insertMedia([clipFor(src, info).copyWith(grade: grade)]);
            final out = '${dir.path}/$name.mp4';
            final work = Directory('${dir.path}/work_$name')..createSync();
            final plan = buildExportPlan(
              project: project,
              settings: const ExportSettings(resolution: ExportResolution.p720)
                  .copyWith(
                    dynamicRange: range,
                    codec: range.isHdr ? VideoCodec.hevc : VideoCodec.h264,
                    frameRate: 30,
                  ),
              encoder:
                  [
                    ...VideoEncoder.hevcCandidates,
                    ...VideoEncoder.h264Candidates,
                  ].firstWhere(
                    (e) => e.name == (range.isHdr ? 'libx265' : 'libx264'),
                  ),
              outputPath: out,
              workDir: work.path,
            );
            for (final f in plan.sideFiles.entries) {
              File(f.key).writeAsStringSync(f.value);
            }
            final r = await Process.run(
              'ffmpeg',
              plan.args,
              workingDirectory: plan.workingDirectory,
            );
            expect(r.exitCode, 0, reason: '${r.stderr}');
            return out;
          }

          Future<List<int>> rgb(String path) async {
            final r = await Process.run('ffmpeg', [
              '-hide_banner',
              '-v',
              'error',
              '-ss',
              '0.5',
              '-i',
              path,
              '-frames:v',
              '1',
              '-vf',
              'scale=1:1,format=rgb24',
              '-f',
              'rawvideo',
              '-',
            ], stdoutEncoding: null);
            return (r.stdout as List<int>).take(3).toList();
          }

          Future<List<double>> yuvMeans(String path) async {
            final r = await Process.run('ffmpeg', [
              '-hide_banner',
              '-v',
              'error',
              '-ss',
              '0.5',
              '-i',
              path,
              '-frames:v',
              '1',
              '-vf',
              'signalstats,metadata=print:file=-',
              '-f',
              'null',
              '-',
            ]);
            double v(String k) => double.parse(
              RegExp('signalstats.$k=([0-9.]+)')
                  .firstMatch('${r.stdout}')!
                  .group(1)!,
            );
            return [v('YAVG'), v('UAVG'), v('VAVG')];
          }

          // The filter's colour matches the maths (within encoding rounding).
          const warm = ColorGrade(preset: FilterPreset.vintage);
          final graded = await export(
            orange,
            oi,
            warm,
            'g_vintage',
            DynamicRange.sdr,
          );
          final got = await rgb(graded);
          // The colour as it comes out without a filter (video storage
          // rounds it a little), run through the maths.
          final plain = await rgb(
            await export(orange, oi, null, 'g_plain', DynamicRange.sdr),
          );
          final want = applyGrade(
            warm.params,
            plain[0] / 255,
            plain[1] / 255,
            plain[2] / 255,
          );
          expect(got[0], closeTo(want.r * 255, 4), reason: '$got from $plain');
          expect(got[1], closeTo(want.g * 255, 4), reason: '$got from $plain');
          expect(got[2], closeTo(want.b * 255, 4), reason: '$got from $plain');

          // Black & white has no colour left.
          final mono = await export(
            orange,
            oi,
            const ColorGrade(preset: FilterPreset.mono),
            'g_mono',
            DynamicRange.sdr,
          );
          final m = await rgb(mono);
          expect((m[0] - m[2]).abs(), lessThan(4));

          // A tiny change leaves the picture as it was (no colour shift from
          // the round trip through the lookup table), in SDR and HLG.
          const tiny = ColorGrade(adjust: GradeParams(brightness: 0.001));
          for (final (src, info, range) in [
            (orange, oi, DynamicRange.sdr),
            (hlg, await _probe(hlg), DynamicRange.hlg),
          ]) {
            final a = await yuvMeans(
              await export(src, info, null, 'g_none_${range.name}', range),
            );
            final b = await yuvMeans(
              await export(src, info, tiny, 'g_tiny_${range.name}', range),
            );
            final scale = range.isHdr ? 4 : 1; // 10-bit numbers are 4× bigger
            for (var i = 0; i < 3; i++) {
              expect(
                (a[i] - b[i]).abs(),
                lessThan(2.0 * scale),
                reason: '${range.name} channel $i: $a vs $b',
              );
            }
          }
        },
      );

      test(
        'sound effects: pitch up an octave keeps the length; all run',
        () async {
          final tone = '${dir.path}/fx_tone.mp4';
          await _run([
            '-f',
            'lavfi',
            '-i',
            'color=c=gray:s=320x180:r=30:d=2',
            '-f',
            'lavfi',
            '-i',
            'sine=f=440:d=2:r=48000',
            '-pix_fmt',
            'yuv420p',
            '-c:v',
            'libx264',
            '-preset',
            'ultrafast',
            '-c:a',
            'aac',
            '-b:a',
            '256k',
            '-shortest',
            tone,
          ]);
          final info = await _probe(tone);

          Future<String> export(AudioFx fx, String name) async {
            final project = Project.empty(
              id: 't',
              frameRate: 30,
            ).insertMedia([clipFor(tone, info).copyWith(audioFx: fx)]);
            final out = '${dir.path}/$name.mp4';
            final plan = buildExportPlan(
              project: project,
              settings: const ExportSettings(resolution: ExportResolution.p480)
                  .copyWith(
                    dynamicRange: DynamicRange.sdr,
                    codec: VideoCodec.h264,
                    frameRate: 30,
                  ),
              encoder: VideoEncoder.h264Candidates.firstWhere(
                (e) => e.name == 'libx264',
              ),
              outputPath: out,
            );
            final r = await Process.run('ffmpeg', plan.args);
            expect(r.exitCode, 0, reason: '${r.stderr}');
            return out;
          }

          // Counts how often the sound crosses zero (twice per wave).
          Future<(double hz, double seconds)> measure(String path) async {
            final r = await Process.run('ffmpeg', [
              '-v',
              'error',
              '-i',
              path,
              '-ac',
              '1',
              '-ar',
              '48000',
              '-f',
              'f32le',
              '-',
            ], stdoutEncoding: null);
            final bytes = Uint8List.fromList(r.stdout as List<int>);
            final f = bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
            var crossings = 0;
            // Middle second only (no fade edges).
            for (var i = 24000 + 1; i < 72000; i++) {
              if ((f[i - 1] < 0) != (f[i] < 0)) crossings++;
            }
            return (crossings / 2, f.length / 48000);
          }

          final up = await measure(
            await export(const AudioFx(pitch: 12), 'fx_up'),
          );
          expect(up.$1, closeTo(880, 15));
          expect(up.$2, closeTo(2.0, 0.05));
          final down = await measure(
            await export(const AudioFx(pitch: -12), 'fx_down'),
          );
          expect(down.$1, closeTo(220, 10));

          // Everything at once runs (equalizer, delay, reverb).
          await export(
            AudioFx(
              pitch: 3,
              eq: EqPreset.voice.gains,
              reverb: ReverbKind.hall,
              delayMs: 250,
            ),
            'fx_all',
          );
        },
      );

      test(
        'noise reduction: hiss is quieter, hum is removed, all kinds run',
        () async {
          // A 1 kHz tone under steady hiss, then hiss alone; and a 60 Hz hum.
          final noisy = '${dir.path}/noisy.mp4';
          await _run([
            '-f',
            'lavfi',
            '-i',
            'color=c=gray:s=320x180:r=30:d=4',
            '-f',
            'lavfi',
            '-i',
            'sine=f=1000:d=4:r=48000,volume=0.3[t];'
                'anoisesrc=d=4:r=48000:c=white:a=0.03[n];'
                'sine=f=60:d=4:r=48000,volume=0.2[h];'
                '[t]volume=enable=\'gte(t,2)\':volume=0[t2];'
                '[t2][n][h]amix=inputs=3:normalize=0',
            '-pix_fmt',
            'yuv420p',
            '-c:v',
            'libx264',
            '-preset',
            'ultrafast',
            '-c:a',
            'aac',
            '-b:a',
            '256k',
            '-shortest',
            noisy,
          ]);
          final info = await _probe(noisy);

          Future<String> export(AudioFx fx, String name) async {
            final project = Project.empty(
              id: 't',
              frameRate: 30,
            ).insertMedia([clipFor(noisy, info).copyWith(audioFx: fx)]);
            final out = '${dir.path}/$name.mp4';
            final plan = buildExportPlan(
              project: project,
              settings: const ExportSettings(resolution: ExportResolution.p480)
                  .copyWith(
                    dynamicRange: DynamicRange.sdr,
                    codec: VideoCodec.h264,
                    frameRate: 30,
                  ),
              encoder: VideoEncoder.h264Candidates.firstWhere(
                (e) => e.name == 'libx264',
              ),
              outputPath: out,
            );
            final r = await Process.run('ffmpeg', plan.args);
            expect(r.exitCode, 0, reason: '${r.stderr}');
            return out;
          }

          // Level of one band of the sound (dB), from 2.5 s to 3.5 s.
          Future<double> band(String path, String filter) async {
            final r = await Process.run('ffmpeg', [
              '-hide_banner',
              '-v',
              'error',
              '-ss',
              '2.5',
              '-t',
              '1',
              '-i',
              path,
              '-vn',
              '-af',
              '$filter,astats=metadata=1:reset=0,'
                  'ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-',
              '-f',
              'null',
              '-',
            ]);
            final all = RegExp(r'RMS_level=(-?[0-9.]+)')
                .allMatches('${r.stdout}')
                .map((m) => double.parse(m.group(1)!))
                .toList();
            if (all.isEmpty) fail('no audio stats: ${r.stderr}');
            return all.last;
          }

          const hissBand = 'highpass=f=2000,highpass=f=2000';
          const humBand = 'lowpass=f=100,lowpass=f=100';
          final before = (
            hiss: await band(noisy, hissBand),
            hum: await band(noisy, humBand),
          );

          final hiss = await export(
            const AudioFx(noise: NoiseKind.hiss, noiseAmount: 1),
            'nr_hiss',
          );
          expect(
            await band(hiss, hissBand),
            lessThan(before.hiss - 10),
            reason: 'hiss reduced',
          );

          final hum = await export(
            const AudioFx(noise: NoiseKind.hum, noiseAmount: 1),
            'nr_hum',
          );
          expect(
            await band(hum, humBand),
            lessThan(before.hum - 15),
            reason: 'hum removed',
          );

          for (final k in [NoiseKind.wind, NoiseKind.road, NoiseKind.breath]) {
            await export(AudioFx(noise: k), 'nr_${k.name}');
          }
        },
      );

      test('smooth slow motion makes new in-between frames', () async {
        // Moving test picture at 30 fps.
        final moving = '${dir.path}/moving.mp4';
        await _run([
          '-f',
          'lavfi',
          '-i',
          'testsrc2=s=320x180:r=30:d=2',
          '-pix_fmt',
          'yuv420p',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          moving,
        ]);
        final info = await _probe(moving);

        Future<int> repeats(bool smooth) async {
          final project = Project.empty(id: 't', frameRate: 30).insertMedia([
            clipFor(moving, info).copyWith(speed: 0.5, smoothSlowMo: smooth),
          ]);
          final out = '${dir.path}/slow_$smooth.mp4';
          final plan = buildExportPlan(
            project: project,
            settings: const ExportSettings(resolution: ExportResolution.p480)
                .copyWith(
                  dynamicRange: DynamicRange.sdr,
                  codec: VideoCodec.h264,
                  frameRate: 30,
                ),
            encoder: VideoEncoder.h264Candidates.firstWhere(
              (e) => e.name == 'libx264',
            ),
            outputPath: out,
          );
          final r = await Process.run('ffmpeg', plan.args);
          expect(r.exitCode, 0, reason: '${r.stderr}');
          // Count frames (nearly) the same as the one before: the average
          // difference between neighbours is tiny for a repeated frame.
          final h = await Process.run('ffmpeg', [
            '-v',
            'error',
            '-i',
            out,
            '-an',
            '-vf',
            'tblend=all_mode=difference,signalstats,'
                'metadata=print:key=lavfi.signalstats.YAVG:file=-',
            '-f',
            'null',
            '-',
          ]);
          final diffs = RegExp(r'YAVG=([0-9.]+)')
              .allMatches('${h.stdout}')
              .map((m) => double.parse(m.group(1)!))
              .toList();
          expect(diffs, isNotEmpty);
          final same = diffs.where((d) => d < 1.0).length;
          return same;
        }

        // Plain slow motion shows each frame twice: about half repeat.
        final plain = await repeats(false);
        expect(plain, greaterThan(40));
        // Smooth: (almost) every frame is new (a few at the very ends,
        // where there's no neighbour to make frames from).
        expect(await repeats(true), lessThan(plain ~/ 5));
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('480p export carries the chosen recording date', () async {
        final info = await _probe(hlg);
        final project = Project.empty(id: 't')
            .insertMedia([clipFor(hlg, info)]);
        final out = '${dir.path}/out_480.mp4';
        final when = DateTime.utc(2024, 7, 4, 15, 30);
        final settings = const ExportSettings(resolution: ExportResolution.p480)
            .copyWith(
              dynamicRange: DynamicRange.sdr,
              codec: VideoCodec.h264,
              frameRate: 30,
              creationTime: when,
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
        final back = await _probe(out);
        expect((back.width, back.height), (854, 480));
        expect(back.createdAt, when);
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

      Future<(MediaInfo, ExportVerification)> exportProject(
        Project project,
        ExportSettings settings,
        String name,
      ) async {
        final out = '${dir.path}/$name.mp4';
        final enc = settings.codec == VideoCodec.hevc ? 'libx265' : 'libx264';
        final plan = buildExportPlan(
          project: project,
          settings: settings,
          encoder: [
            ...VideoEncoder.hevcCandidates,
            ...VideoEncoder.h264Candidates,
          ].firstWhere((e) => e.name == enc),
          outputPath: out,
        );
        final r = await Process.run('ffmpeg', plan.args);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final v = await Process.run('ffprobe', verifyArgs(out));
        return (
          await _probe(out),
          parseVerification(
            '${v.stdout}',
            plan.expectedFrames,
            plan.durationUs,
          ),
        );
      }

      test('rotate, mirror, crop and double speed', () async {
        final info = await _probe(hlg);
        final c = clipFor(hlg, info).copyWith(
          rotation: 1,
          flipH: true,
          crop: const CropRect(0, 0.25, 1, 0.75),
          speed: 2,
        );
        final project = Project.empty(id: 't').insertMedia([c]);
        // Turned 90° the 1280x720 clip is 720x1280; keeping the middle half
        // of its height gives 720x640.
        expect(project.mainTrack.clips.single.displaySize, (
          width: 720.0,
          height: 640.0,
        ));
        final (out, check) = await exportProject(
          project,
          const ExportSettings(
            resolution: ExportResolution.p720,
            frameRate: 60,
          ),
          'look',
        );
        expect(check.actualFrames, 90); // 3 s at 2x = 1.5 s at 60 fps
        expect(out.transfer, ColorTransfer.hlg);
      });

      test('opacity over a white background, and blurred background', () async {
        // A black clip at 50 % over white should come out mid grey.
        final black = '${dir.path}/black.mp4';
        await _run([
          '-f',
          'lavfi',
          '-i',
          'color=c=black:s=640x360:r=30:d=1',
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
          black,
        ]);
        final info = await _probe(black);
        final sdr30 = const ExportSettings(resolution: ExportResolution.p720)
            .copyWith(
              dynamicRange: DynamicRange.sdr,
              codec: VideoCodec.h264,
              frameRate: 30,
            );
        final faded = Project.empty(id: 't')
            .insertMedia([clipFor(black, info).copyWith(opacity: 0.5)])
            .withBackground(const BackgroundFill.color(0xFFFFFFFF));
        final (_, check) = await exportProject(faded, sdr30, 'opacity');
        expect(check.actualFrames, 30);
        final y = await _avgLuma('${dir.path}/opacity.mp4');
        expect(y, closeTo(126, 8));

        // Portrait clip on a landscape canvas with a blurred background.
        final rInfo = await _probe(rotated);
        final blurred = Project.empty(id: 't', frameRate: 30)
            .insertMedia([media16x9Placeholder(), clipFor(rotated, rInfo)])
            .deleteFirst()
            .withBackground(const BackgroundFill.blur());
        expect(blurred.canvas, CanvasRatio.landscape16x9);
        final (out, check2) = await exportProject(blurred, sdr30, 'blur');
        expect((out.width, out.height), (1280, 720));
        expect(check2.ok, isTrue);
      });

      test('reverse: pieces reversed and joined last-to-first', () async {
        final info = await _probe(hlg);
        final work = await Directory('${dir.path}/rev').create();
        final out = '${dir.path}/reversed.mp4';
        final plan = buildReversePlan(
          source: hlg,
          info: info,
          inUs: 500000,
          outUs: 2500000,
          encoder: VideoEncoder.hevcCandidates.firstWhere(
            (e) => e.name == 'libx265',
          ),
          workDir: work.path,
          outputPath: out,
        );
        expect(plan.chunkArgs.length, 2); // 2 s in 1 s pieces (720p)
        for (final a in plan.chunkArgs) {
          final r = await Process.run('ffmpeg', a);
          expect(r.exitCode, 0, reason: '${r.stderr}');
        }
        await File(plan.concatListPath).writeAsString(plan.concatList);
        final r = await Process.run('ffmpeg', plan.concatArgs);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final rev = await _probe(out);
        expect(rev.durationUs, closeTo(2 * usPerSecond, 60000));
        expect(rev.transfer, ColorTransfer.hlg);

        // First frame of the reversed copy == last used frame of the original.
        Future<String> frameHash(String path, double at) async {
          final x = await Process.run('ffmpeg', [
            '-hide_banner',
            '-v',
            'error',
            '-ss',
            '$at',
            '-i',
            path,
            '-frames:v',
            '1',
            '-vf',
            'scale=32:18,format=gray',
            '-f',
            'rawvideo',
            '-',
          ], stdoutEncoding: null);
          return (x.stdout as List<int>).map((b) => b ~/ 32).join();
        }

        final firstOfReversed = await frameHash(out, 0);
        final lastOfOriginal = await frameHash(hlg, 2.5 - 1 / 60);
        final firstOfOriginal = await frameHash(hlg, 0.5);
        expect(firstOfReversed, lastOfOriginal);
        expect(firstOfReversed, isNot(firstOfOriginal));

        // The reversed clip exports at the right length.
        final clip = clipFor(hlg, info, inUs: 500000, outUs: 2500000).copyWith(
          reversed: true,
          reverseProxy: ReverseProxy(out, 500000, 2500000),
        );
        final (_, check) = await exportProject(
          Project.empty(id: 't').insertMedia([clip]),
          const ExportSettings(
            resolution: ExportResolution.p720,
            frameRate: 60,
          ),
          'reversed_export',
        );
        expect(check.actualFrames, 120);
      });

      Future<double> rmsDb(String path, double from, double length) async {
        final r = await Process.run('ffmpeg', [
          '-hide_banner',
          '-v',
          'error',
          '-ss',
          '$from',
          '-t',
          '$length',
          '-i',
          path,
          '-vn',
          '-af',
          'astats=metadata=1:reset=0,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-',
          '-f',
          'null',
          '-',
        ]);
        final all = RegExp(r'RMS_level=(-?[0-9.]+|-inf)')
            .allMatches('${r.stdout}')
            .map((m) => m.group(1)!)
            .toList();
        if (all.isEmpty) fail('no audio stats: ${r.stderr}');
        final last = all.last;
        return last == '-inf' ? -200 : double.parse(last);
      }

      test(
        'audio tracks are mixed in at their place, volume and fades',
        () async {
          final music = '${dir.path}/tone.wav';
          await _run([
            '-f',
            'lavfi',
            '-i',
            'sine=f=1000:d=6:r=48000',
            '-ac',
            '2',
            music,
          ]);
          final videoInfo = await _probe(silent); // 2 s, no sound
          final toneInfo = await _probe(music);
          expect(toneInfo.hasVideo, isFalse);
          Clip tone({double volume = 1, int fadeIn = 0}) => Clip(
            id: 0,
            kind: ClipKind.audio,
            name: 'tone',
            sourcePath: music,
            media: toneInfo,
            sourceDurationUs: toneInfo.durationUs,
            sourceInUs: 0,
            sourceOutUs: 3 * usPerSecond,
            startUs: 1 * usPerSecond,
            volume: volume,
            fadeInUs: fadeIn,
          );
          final sdr30 = const ExportSettings(resolution: ExportResolution.p720)
              .copyWith(
                dynamicRange: DynamicRange.sdr,
                codec: VideoCodec.h264,
                frameRate: 30,
              );
          final base = Project.empty(id: 't')
              .insertMedia([clipFor(silent, videoInfo)]);

          final (_, check) = await exportProject(
            base.addAudio(tone()),
            sdr30,
            'mix_full',
          );
          expect(check.actualFrames, 60); // video length decides; music is cut
          final full = '${dir.path}/mix_full.mp4';
          expect(
            await rmsDb(full, 0.1, 0.7),
            lessThan(-60),
          ); // silence before 1 s
          final loud = await rmsDb(full, 1.2, 0.6);
          expect(loud, greaterThan(-30));

          await exportProject(
            base.addAudio(tone(volume: 0.5)),
            sdr30,
            'mix_half',
          );
          final half = await rmsDb('${dir.path}/mix_half.mp4', 1.2, 0.6);
          expect(loud - half, closeTo(6.0, 0.6)); // half volume = -6 dB

          await exportProject(
            base.addAudio(tone(fadeIn: 800000)),
            sdr30,
            'mix_fade',
          );
          final early = await rmsDb('${dir.path}/mix_fade.mp4', 1.0, 0.2);
          expect(early, lessThan(loud - 8)); // still fading in
        },
      );

      test('a muted video clip and its extracted sound', () async {
        final info = await _probe(sdr); // has a 660 Hz tone
        final p0 = Project.empty(id: 't').insertMedia([clipFor(sdr, info)]);
        final p1 = p0.extractAudio(p0.mainTrack.clips.single.id);
        expect(p1.mainTrack.clips.single.volume, 0);
        expect(p1.audioTracks.single.clips.single.kind, ClipKind.audio);
        expect(p1.audioTracks.single.clips.single.startUs, 0);
        final sdr30 = const ExportSettings(resolution: ExportResolution.p720)
            .copyWith(
              dynamicRange: DynamicRange.sdr,
              codec: VideoCodec.h264,
              frameRate: 30,
            );
        await exportProject(p1, sdr30, 'extracted');
        expect(
          await rmsDb('${dir.path}/extracted.mp4', 0.5, 1),
          greaterThan(-35),
        );
        final muted = p1.deleteClip(p1.audioTracks.single.clips.single.id);
        await exportProject(muted, sdr30, 'muted');
        expect(await rmsDb('${dir.path}/muted.mp4', 0.5, 1), lessThan(-60));
      });

      test('text overlays: timing, fade, position, HDR white', () async {
        // A plain dark video and a white 200x100 "text" picture.
        final dark = '${dir.path}/dark.mp4';
        await _run([
          '-f',
          'lavfi',
          '-i',
          'color=c=0x101010:s=1280x720:r=30:d=4',
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
          dark,
        ]);
        final png = '${dir.path}/text.png';
        await _run([
          '-f',
          'lavfi',
          '-i',
          'color=c=white:s=200x100,format=rgba',
          '-frames:v',
          '1',
          png,
        ]);
        final info = await _probe(dark);
        const spec = TextSpec(
          text: 'Hi',
          x: 0.25,
          y: 0.5,
          animIn: TextAnim.fade,
          animInUs: 1000000,
          animOut: TextAnim.none,
        );
        final project = Project.empty(id: 't')
            .insertMedia([clipFor(dark, info)])
            .addText(Clip.text(spec, startUs: 1000000, durationUs: 2000000));
        final textId = project.textTracks.single.clips.single.id;
        final images = {
          textId: TextImages(fullPath: png, width: 200, height: 100),
        };

        Future<double> lumaAt(String video, double t) async {
          // The text should be centred at (320, 360): sample its middle.
          final r = await Process.run('ffmpeg', [
            '-hide_banner',
            '-v',
            'error',
            '-ss',
            '$t',
            '-i',
            video,
            '-vf',
            'crop=80:40:280:340,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-',
            '-frames:v',
            '1',
            '-f',
            'null',
            '-',
          ]);
          return double.parse(
            RegExp(r'YAVG=([0-9.]+)').firstMatch('${r.stdout}')!.group(1)!,
          );
        }

        Future<String> export(ExportSettings settings, String name) async {
          final out = '${dir.path}/$name.mp4';
          final plan = buildExportPlan(
            project: project,
            settings: settings,
            encoder:
                [
                  ...VideoEncoder.hevcCandidates,
                  ...VideoEncoder.h264Candidates,
                ].firstWhere(
                  (e) =>
                      e.name ==
                      (settings.dynamicRange.isHdr ? 'libx265' : 'libx264'),
                ),
            outputPath: out,
            textImages: images,
            workDir: dir.path,
          );
          for (final f in plan.sideFiles.entries) {
            await File(f.key).writeAsString(f.value);
          }
          final r = await Process.run('ffmpeg', plan.args);
          expect(r.exitCode, 0, reason: '${r.stderr}');
          final v = await Process.run('ffprobe', verifyArgs(out));
          expect(
            parseVerification(
              '${v.stdout}',
              plan.expectedFrames,
              plan.durationUs,
            ).ok,
            isTrue,
          );
          return out;
        }

        final sdr = await export(
          const ExportSettings(resolution: ExportResolution.p720).copyWith(
            dynamicRange: DynamicRange.sdr,
            codec: VideoCodec.h264,
            frameRate: 30,
          ),
          'text_sdr',
        );
        final before = await lumaAt(sdr, 0.5);
        final fadingIn = await lumaAt(sdr, 1.5);
        final full = await lumaAt(sdr, 2.5);
        final after = await lumaAt(sdr, 3.5);
        expect(before, lessThan(40)); // not there yet
        expect(full, greaterThan(225)); // solid white text
        expect(
          fadingIn,
          inInclusiveRange(before + 40, full - 40),
        ); // half faded
        expect(after, lessThan(40)); // gone after 3 s

        final hlg = await export(
          const ExportSettings(
            resolution: ExportResolution.p720,
            frameRate: 30,
          ),
          'text_hlg',
        );
        // White text sits at HDR reference white (~721 of 1023), not 940.
        expect(await lumaAt(hlg, 2.5), closeTo(721, 12));
      });

      test('slide, pop and typewriter animations export', () async {
        final dark = '${dir.path}/dark2.mp4';
        await _run([
          '-f',
          'lavfi',
          '-i',
          'color=c=black:s=640x360:r=30:d=3',
          '-pix_fmt',
          'yuv420p',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          dark,
        ]);
        final png = '${dir.path}/t2.png';
        await _run([
          '-f',
          'lavfi',
          '-i',
          'color=c=yellow:s=120x40,format=rgba',
          '-frames:v',
          '1',
          png,
        ]);
        final info = await _probe(dark);
        var project = Project.empty(id: 't').insertMedia([clipFor(dark, info)]);
        final images = <int, TextImages>{};
        for (final (anIn, anOut) in [
          (TextAnim.slideLeft, TextAnim.pop),
          (TextAnim.pop, TextAnim.slideDown),
          (TextAnim.typewriter, TextAnim.typewriter),
        ]) {
          project = project.addText(
            Clip.text(
              TextSpec(text: 'ab', animIn: anIn, animOut: anOut),
              startUs: 200000,
              durationUs: 2000000,
            ),
          );
          final id = project.textTracks.expand((t) => t.clips).last.id;
          images[id] = TextImages(
            fullPath: png,
            width: 120,
            height: 40,
            typewriterPaths: [png, png, png],
          );
        }
        final out = '${dir.path}/anim.mp4';
        final plan = buildExportPlan(
          project: project,
          settings: const ExportSettings(resolution: ExportResolution.p720)
              .copyWith(
                dynamicRange: DynamicRange.sdr,
                codec: VideoCodec.h264,
                frameRate: 30,
              ),
          encoder: VideoEncoder.h264Candidates.firstWhere(
            (e) => e.name == 'libx264',
          ),
          outputPath: out,
          textImages: images,
          workDir: dir.path,
        );
        for (final f in plan.sideFiles.entries) {
          await File(f.key).writeAsString(f.value);
        }
        final r = await Process.run('ffmpeg', plan.args);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final v = await Process.run('ffprobe', verifyArgs(out));
        expect(
          parseVerification(
            '${v.stdout}',
            plan.expectedFrames,
            plan.durationUs,
          ).actualFrames,
          90,
        );
      });

      test(
        'transitions overlap clips, blend, and keep sound in step',
        () async {
          Future<String> solid(
            String name,
            String color, {
            int tone = 440,
          }) async {
            final path = '${dir.path}/$name.mp4';
            await _run([
              '-f',
              'lavfi',
              '-i',
              'color=c=$color:s=640x360:r=30:d=2',
              '-f',
              'lavfi',
              '-i',
              'sine=f=$tone:d=2:r=48000',
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
              '-c:a',
              'aac',
              '-shortest',
              path,
            ]);
            return path;
          }

          final red = await solid('red', 'red');
          final blue = await solid('blue', 'blue', tone: 880);
          final ri = await _probe(red), bi = await _probe(blue);

          Future<(String, ExportVerification)> run(
            TransitionKind kind,
            String name,
          ) async {
            var project = Project.empty(
              id: 't',
              frameRate: 30,
            ).insertMedia([clipFor(red, ri), clipFor(blue, bi)]);
            project = project.setTransition(
              0,
              TransitionSpec(kind, durationUs: 1000000),
            );
            expect(project.durationUs, 3000000); // 2 s + 2 s - 1 s overlap
            final out = '${dir.path}/$name.mp4';
            final plan = buildExportPlan(
              project: project,
              settings: const ExportSettings(resolution: ExportResolution.p720)
                  .copyWith(
                    dynamicRange: DynamicRange.sdr,
                    codec: VideoCodec.h264,
                    frameRate: 30,
                  ),
              encoder: VideoEncoder.h264Candidates.firstWhere(
                (e) => e.name == 'libx264',
              ),
              outputPath: out,
            );
            final r = await Process.run('ffmpeg', plan.args);
            expect(r.exitCode, 0, reason: '${r.stderr}');
            final v = await Process.run('ffprobe', verifyArgs(out));
            return (
              out,
              parseVerification(
                '${v.stdout}',
                plan.expectedFrames,
                plan.durationUs,
              ),
            );
          }

          Future<List<double>> rgbAt(String path, double t) async {
            final r = await Process.run('ffmpeg', [
              '-hide_banner',
              '-v',
              'error',
              '-ss',
              '$t',
              '-i',
              path,
              '-frames:v',
              '1',
              '-vf',
              'scale=1:1,format=rgb24',
              '-f',
              'rawvideo',
              '-',
            ], stdoutEncoding: null);
            return [
              for (final b in (r.stdout as List<int>).take(3)) b.toDouble(),
            ];
          }

          final (fade, check) = await run(TransitionKind.fade, 'tr_fade');
          expect(check.actualFrames, 90);
          expect(check.ok, isTrue);
          final start = await rgbAt(fade, 0.3);
          final middle = await rgbAt(fade, 1.5);
          final end = await rgbAt(fade, 2.7);
          expect(start[0], greaterThan(200)); // red
          expect(end[2], greaterThan(200)); // blue
          expect(middle[0], inInclusiveRange(70, 190)); // a mix of both
          expect(middle[2], inInclusiveRange(70, 190));

          // Sound lasts exactly as long as the picture.
          final a = await Process.run('ffprobe', [
            '-v',
            'error',
            '-select_streams',
            'a:0',
            '-show_entries',
            'stream=duration',
            '-of',
            'csv=p=0',
            fade,
          ]);
          expect(double.parse('${a.stdout}'.trim()), closeTo(3.0, 0.03));

          final (black, _) = await run(TransitionKind.fadeBlack, 'tr_black');
          final dip = await rgbAt(black, 1.5);
          expect(
            dip.reduce((x, y) => x + y),
            lessThan(40),
          ); // black in the middle

          // The preview copy of a transition: last 2d of A + first 2d of B.
          final both = Project.empty(id: 't', frameRate: 30)
              .insertMedia([clipFor(red, ri), clipFor(blue, bi)])
              .setTransition(
                0,
                const TransitionSpec(
                  TransitionKind.slideLeft,
                  durationUs: 500000,
                ),
              );
          final mini = both.transitionPreviewProject(0)!;
          final miniOut = '${dir.path}/tr_preview.mp4';
          final miniPlan = buildExportPlan(
            project: mini,
            settings: const ExportSettings(resolution: ExportResolution.p720)
                .copyWith(
                  dynamicRange: DynamicRange.sdr,
                  codec: VideoCodec.h264,
                  frameRate: 30,
                ),
            encoder: VideoEncoder.h264Candidates.firstWhere(
              (e) => e.name == 'libx264',
            ),
            outputPath: miniOut,
          );
          final mr = await Process.run('ffmpeg', miniPlan.args);
          expect(mr.exitCode, 0, reason: '${mr.stderr}');
          expect(miniPlan.expectedFrames, 45); // 1.5 s at 30 fps

          for (final k in [
            TransitionKind.slideLeft,
            TransitionKind.slideUp,
            TransitionKind.zoom,
          ]) {
            final (_, c) = await run(k, 'tr_${k.name}');
            expect(c.actualFrames, 90, reason: k.name);
          }
        },
      );

      test('typewriter picture list', () {
        const spec = TextSpec(
          text: 'abc',
          animIn: TextAnim.typewriter,
          animInUs: 600000,
          animOut: TextAnim.none,
        );
        const images = TextImages(
          fullPath: '/f.png',
          width: 10,
          height: 10,
          typewriterPaths: ['/0.png', '/1.png', '/2.png', '/3.png'],
        );
        final list = textPictureList(spec, images, 2.0);
        expect(list.trim().split('\n'), [
          'ffconcat version 1.0',
          "file '/1.png'",
          'duration 0.200000',
          "file '/2.png'",
          'duration 0.200000',
          "file '/3.png'",
          'duration 0.200000',
          "file '/f.png'",
          'duration 1.400000',
          "file '/f.png'",
        ]);
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
