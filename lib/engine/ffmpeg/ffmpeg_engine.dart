import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../../model/export_settings.dart';
import '../../model/project.dart';
import '../media_engine.dart';
import 'ffmpeg_commands.dart';
import 'mpv_preview.dart';

/// The Windows video engine: FFmpeg (bundled next to the app) does the
/// examining, thumbnails and exporting; mpv (via media_kit) does the preview.
class FfmpegEngine implements MediaEngine {
  FfmpegEngine({String? ffmpegPath, String? ffprobePath})
    : ffmpeg = ffmpegPath ?? _bundled('ffmpeg'),
      ffprobe = ffprobePath ?? _bundled('ffprobe');

  final String ffmpeg;
  final String ffprobe;

  /// FFmpeg ships in an `ffmpeg` folder beside the app's .exe. If it isn't
  /// there (e.g. a developer build), the one on the system PATH is used.
  static String _bundled(String tool) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final ext = Platform.isWindows ? '.exe' : '';
    final candidate =
        '$exeDir${Platform.pathSeparator}ffmpeg'
        '${Platform.pathSeparator}$tool$ext';
    return File(candidate).existsSync() ? candidate : tool;
  }

  @override
  bool get supportsMedia => true;

  static const _videoTypes = XTypeGroup(
    label: 'Videos',
    extensions: [
      'mp4',
      'mov',
      'm4v',
      'mkv',
      'webm',
      'avi',
      'mts',
      'm2ts',
      'ts',
      '3gp',
    ],
  );

  @override
  Future<List<PickedMedia>> pickVideos() async {
    final files = await openFiles(acceptedTypeGroups: [_videoTypes]);
    return [for (final f in files) PickedMedia(f.path, f.name)];
  }

  static const missingMessage =
      'The video engine (FFmpeg) was not found on this computer, so videos '
      'can\'t be read or exported yet. See "Windows" in docs/UPDATES.md for '
      'the one-line install.';

  @override
  Future<MediaInfo> probe(String source) async {
    final ProcessResult r;
    try {
      r = await Process.run(ffprobe, [
        ...probeArgsPrefix,
        source,
      ], stdoutEncoding: utf8);
    } on ProcessException {
      throw MediaException(missingMessage);
    }
    if (r.exitCode != 0) {
      throw MediaException('Could not read "$source": ${r.stderr}'.trim());
    }
    return parseProbeJson('${r.stdout}');
  }

  static const _audioTypes = XTypeGroup(
    label: 'Audio and video',
    extensions: [
      'mp3',
      'wav',
      'm4a',
      'aac',
      'flac',
      'ogg',
      'opus',
      'wma',
      'aiff',
      'mp4',
      'mov',
      'm4v',
      'mkv',
      'webm',
      'avi',
    ],
  );

  @override
  Future<List<PickedMedia>> pickAudio() async {
    final files = await openFiles(acceptedTypeGroups: [_audioTypes]);
    return [for (final f in files) PickedMedia(f.path, f.name)];
  }

  @override
  Future<Uint8List> waveform(String source) async {
    // Sound only, mixed to mono at 4,000 samples a second: plenty for an
    // outline and small even for long files.
    final r = await Process.run(ffmpeg, [
      '-v',
      'error',
      '-i',
      source,
      '-vn',
      '-ac',
      '1',
      '-ar',
      '4000',
      '-f',
      's16le',
      '-',
    ], stdoutEncoding: null);
    if (r.exitCode != 0) return Uint8List(0);
    final bytes = Uint8List.fromList(r.stdout as List<int>);
    final samples = bytes.buffer.asInt16List(0, bytes.lengthInBytes ~/ 2);
    return peaksFromSamples(samples, 40);
  }

  @override
  Future<void> speechAudio(
    String source,
    int inUs,
    int outUs,
    String output,
  ) async {
    final r = await Process.run(ffmpeg, [
      '-v',
      'error',
      '-y',
      '-ss',
      '${inUs / 1e6}',
      '-t',
      '${(outUs - inUs) / 1e6}',
      '-i',
      source,
      '-vn',
      '-ac',
      '1',
      '-ar',
      '16000',
      '-f',
      'f32le',
      output,
    ]);
    if (r.exitCode != 0) {
      throw Exception('Could not read the sound: ${r.stderr}');
    }
  }

  @override
  ClipAudioPlayer createAudioPlayer() => MpvAudioPlayer();

  Directory? _thumbDir;
  Future<Directory> _thumbnailDirectory() async {
    final existing = _thumbDir;
    if (existing != null) return existing;
    final base = await getApplicationCacheDirectory();
    return _thumbDir = await Directory('${base.path}/thumbnails')
        .create(recursive: true);
  }

  @override
  Future<List<String?>> thumbnails(
    String source,
    MediaInfo info,
    List<int> timesUs, {
    int height = 120,
  }) async {
    final dir = await _thumbnailDirectory();
    final key = source.hashCode.toUnsigned(32).toRadixString(16);
    final results = List<String?>.filled(timesUs.length, null);
    // A few at a time: fast, without flooding the computer with processes.
    var next = 0;
    Future<void> worker() async {
      while (next < timesUs.length) {
        final i = next++;
        final path = '${dir.path}/${key}_${timesUs[i]}_$height.jpg';
        if (await File(path).exists()) {
          results[i] = path;
          continue;
        }
        final r = await Process.run(
          ffmpeg,
          thumbnailArgs(source, info, timesUs[i], height, path),
        );
        if (r.exitCode == 0 && await File(path).exists()) results[i] = path;
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    return results;
  }

  @override
  bool get supportsBackgrounds => true;

  @override
  bool get supportsAllTransitions => true;

  @override
  Future<String?> renderPreviewClip(Project project, String key) async {
    final dir = await Directory(
      '${(await getApplicationCacheDirectory()).path}/transitions',
    ).create(recursive: true);
    final out = File('${dir.path}/$key.mp4');
    if (await out.exists()) return out.path;
    final encoder = await encoderFor(VideoCodec.h264, tenBit: false);
    if (encoder == null) return null;
    final work = await Directory('${dir.path}/work').create(recursive: true);
    final fps = ExportSettings.frameRates.reduce(
      (a, b) => (a - project.frameRate).abs() <= (b - project.frameRate).abs()
          ? a
          : b,
    );
    final plan = buildExportPlan(
      project: project,
      // Preview quality: 720p SDR is quick to make and plenty for the screen.
      settings:
          const ExportSettings(
            resolution: ExportResolution.p720,
            quality: ExportQuality.standard,
          ).copyWith(
            dynamicRange: DynamicRange.sdr,
            codec: VideoCodec.h264,
            frameRate: fps,
          ),
      encoder: encoder,
      outputPath: '${out.path}.part.mp4',
      workDir: work.path,
    );
    for (final f in plan.sideFiles.entries) {
      await File(f.key).writeAsString(f.value);
    }
    final r = await Process.run(
      ffmpeg,
      plan.args,
      workingDirectory: plan.workingDirectory,
    );
    if (r.exitCode != 0) {
      final lines = '${r.stderr}'.trim().split('\n');
      throw Exception(lines.isEmpty ? 'FFmpeg failed' : lines.last);
    }
    await File('${out.path}.part.mp4').rename(out.path);
    return out.path;
  }

  @override
  Future<ReverseProxy> prepareReverse(
    Clip clip, {
    void Function(double fraction)? onProgress,
  }) async {
    final info = clip.media!;
    final source = clip.sourcePath!;
    final encoder = await encoderFor(
      info.isHdr || info.bitDepth > 8 ? VideoCodec.hevc : VideoCodec.h264,
      tenBit: info.isHdr || info.bitDepth > 8,
    );
    if (encoder == null) {
      throw MediaException(
        'No video encoder available to prepare the reversed copy.',
      );
    }
    final base = await getApplicationSupportDirectory();
    final key =
        '${source.hashCode.toUnsigned(32).toRadixString(16)}_'
        '${clip.sourceInUs}_${clip.sourceOutUs}';
    final out = File('${base.path}/reversed/$key.mp4');
    if (await out.exists()) {
      return ReverseProxy(out.path, clip.sourceInUs, clip.sourceOutUs);
    }
    await out.parent.create(recursive: true);
    final work = await Directory(
      '${(await getApplicationCacheDirectory()).path}/reverse_$key',
    ).create(recursive: true);
    try {
      final plan = buildReversePlan(
        source: source,
        info: info,
        inUs: clip.sourceInUs,
        outUs: clip.sourceOutUs,
        encoder: encoder,
        workDir: work.path,
        outputPath: '${out.path}.part.mp4',
      );
      for (var i = 0; i < plan.chunkArgs.length; i++) {
        final r = await Process.run(ffmpeg, plan.chunkArgs[i]);
        if (r.exitCode != 0) {
          throw MediaException('Reversing failed: ${r.stderr}'.trim());
        }
        onProgress?.call((i + 1) / (plan.chunkArgs.length + 1));
      }
      await File(plan.concatListPath).writeAsString(plan.concatList);
      final r = await Process.run(ffmpeg, plan.concatArgs);
      if (r.exitCode != 0) {
        throw MediaException('Reversing failed: ${r.stderr}'.trim());
      }
      await File('${out.path}.part.mp4').rename(out.path);
      onProgress?.call(1);
      return ReverseProxy(out.path, clip.sourceInUs, clip.sourceOutUs);
    } finally {
      await work.delete(recursive: true);
    }
  }

  @override
  Future<String?> pickOutputFolder() =>
      getDirectoryPath(confirmButtonText: 'Save here');

  @override
  Future<Set<String>> missingSources(Iterable<String> sources) async => {
    for (final s in sources)
      if (!await File(s).exists()) s,
  };

  @override
  Future<String?> pickSearchFolder() =>
      getDirectoryPath(confirmButtonText: 'Look here');

  @override
  Future<List<PickedMedia>> mediaFilesIn(String folder) async {
    final kinds = {
      ...?_videoTypes.extensions,
      ...?_audioTypes.extensions,
    }.map((e) => e.toLowerCase()).toSet();
    final out = <PickedMedia>[];
    try {
      await for (final e in Directory(folder).list(recursive: true)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final dot = name.lastIndexOf('.');
        if (dot < 0 || !kinds.contains(name.substring(dot + 1).toLowerCase())) {
          continue;
        }
        out.add(PickedMedia(e.path, name));
        if (out.length >= 5000) break;
      }
    } on FileSystemException {
      // Unreadable subfolders: keep what was found.
    }
    return out;
  }

  String get _defaultFolder {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$home${Platform.pathSeparator}Videos';
  }

  @override
  String describeFolder(String? folder) => folder ?? _defaultFolder;

  // ---------------------------------------------------------------------------
  // Encoders
  // ---------------------------------------------------------------------------

  final Map<String, Future<VideoEncoder?>> _encoderCache = {};

  /// The best encoder that actually works on this computer.
  Future<VideoEncoder?> encoderFor(VideoCodec codec, {required bool tenBit}) {
    return _encoderCache['${codec.name}-$tenBit'] ??= () async {
      final candidates = codec == VideoCodec.hevc
          ? VideoEncoder.hevcCandidates
          : VideoEncoder.h264Candidates;
      for (final e in candidates) {
        try {
          final r = await Process.run(ffmpeg, e.probeArgs(tenBit: tenBit));
          if (r.exitCode == 0) return e;
        } catch (_) {
          // FFmpeg missing entirely; reported by checkExport.
        }
      }
      return null;
    }();
  }

  @override
  Future<String?> checkExport(Project project, ExportSettings settings) async {
    if (!project.hasMedia) return 'Add a video first.';
    try {
      await Process.run(ffmpeg, ['-version']);
    } catch (_) {
      return missingMessage;
    }
    final enc = await encoderFor(
      settings.codec,
      tenBit: settings.dynamicRange.isHdr,
    );
    if (enc == null) {
      return settings.dynamicRange.isHdr
          ? 'This computer has no graphics hardware that can encode 10-bit '
                'HEVC, which HDR needs. Choose SDR, or try again after a '
                'graphics card or driver update.'
          : 'No ${settings.codec.label} encoder is available on this computer.';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Preview and export
  // ---------------------------------------------------------------------------

  @override
  PreviewPlayer createPreview() => MpvPreviewPlayer();

  @override
  OverlayPlayer? createOverlayPlayer() => MpvOverlayPlayer();

  FfmpegExportJob? _running;

  @override
  Future<ExportJob?> runningExport() async {
    final job = _running;
    return job != null && !job.latest.finished ? job : null;
  }

  @override
  Future<ExportJob> startExport(ExportRequest request) async {
    final problem = await checkExport(request.project, request.settings);
    if (problem != null) throw MediaException(problem);
    final settings = request.settings;
    final encoder = (await encoderFor(
      settings.codec,
      tenBit: settings.dynamicRange.isHdr,
    ))!;
    final folder = Directory(describeFolder(settings.outputFolder));
    await folder.create(recursive: true);
    final output = await _uniquePath(folder, request.fileName);
    final work = await Directory(
      '${(await getApplicationCacheDirectory()).path}/export_work',
    ).create(recursive: true);
    final plan = buildExportPlan(
      project: request.project,
      settings: settings,
      encoder: encoder,
      outputPath: output,
      textImages: request.textImages,
      workDir: work.path,
    );
    for (final f in plan.sideFiles.entries) {
      await File(f.key).writeAsString(f.value);
    }
    final job = FfmpegExportJob._(this, plan, output, encoder);
    _running = job;
    await job._start();
    return job;
  }

  static Future<String> _uniquePath(Directory folder, String fileName) async {
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '.mp4';
    var candidate = '${folder.path}${Platform.pathSeparator}$stem$ext';
    var n = 2;
    while (await File(candidate).exists()) {
      candidate = '${folder.path}${Platform.pathSeparator}$stem ($n)$ext';
      n++;
    }
    return candidate;
  }
}

class FfmpegExportJob implements ExportJob {
  FfmpegExportJob._(this._engine, this._plan, this._output, this.encoder);

  final FfmpegEngine _engine;
  final FfmpegExportPlan _plan;
  final String _output;
  final VideoEncoder encoder;
  final _controller = StreamController<ExportProgress>.broadcast();
  Process? _process;
  bool _cancelled = false;
  final _errors = StringBuffer();

  ExportProgress _latest = const ExportProgress(ExportState.preparing);

  @override
  ExportProgress get latest => _latest;

  @override
  Stream<ExportProgress> get progress => _controller.stream;

  void _emit(ExportProgress p) {
    _latest = p;
    if (!_controller.isClosed) _controller.add(p);
  }

  Future<void> _start() async {
    _emit(
      ExportProgress(
        ExportState.running,
        message: 'Encoding with ${encoder.friendlyName}',
      ),
    );
    final process = await Process.start(
      _engine.ffmpeg,
      _plan.args,
      workingDirectory: _plan.workingDirectory,
    );
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final us = parseProgressLine(line);
          if (us != null && _plan.durationUs > 0) {
            _emit(
              ExportProgress(
                ExportState.running,
                fraction: (us / _plan.durationUs).clamp(0.0, 0.99),
                message: 'Encoding with ${encoder.friendlyName}',
              ),
            );
          }
        });
    process.stderr.transform(utf8.decoder).listen(_errors.write);
    unawaited(process.exitCode.then(_finish));
  }

  Future<void> _finish(int code) async {
    if (_cancelled) {
      await _deletePartial();
      _emit(
        const ExportProgress(
          ExportState.cancelled,
          message: 'Export cancelled.',
        ),
      );
    } else if (code != 0) {
      await _deletePartial();
      final detail = _errors.toString().trim();
      _emit(
        ExportProgress(
          ExportState.failed,
          message: 'Export failed.${detail.isEmpty ? '' : '\n\n$detail'}',
        ),
      );
    } else {
      _emit(
        const ExportProgress(
          ExportState.finishing,
          fraction: 0.99,
          message: 'Checking the finished video…',
        ),
      );
      ExportVerification? check;
      try {
        final r = await Process.run(_engine.ffprobe, verifyArgs(_output));
        check = parseVerification(
          '${r.stdout}',
          _plan.expectedFrames,
          _plan.durationUs,
        );
      } catch (_) {
        check = null;
      }
      _emit(
        ExportProgress(
          ExportState.done,
          fraction: 1,
          outputLocation: _output,
          verification: check,
          message: check?.describe(),
        ),
      );
    }
    await _controller.close();
  }

  Future<void> _deletePartial() async {
    try {
      final f = File(_output);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill();
  }
}

class MediaException implements Exception {
  MediaException(this.message);
  final String message;
  @override
  String toString() => message;
}
