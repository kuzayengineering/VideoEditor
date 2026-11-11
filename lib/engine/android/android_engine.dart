import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../model/export_settings.dart';
import '../../model/project.dart';
import '../media_engine.dart';

const _channel = MethodChannel('ve/engine');

/// The Android video engine, built on Google's Media3 (ExoPlayer for preview,
/// Transformer for export). The heavy lifting happens in Kotlin; see
/// android/app/src/main/kotlin/.../ExportService.kt.
class AndroidMediaEngine implements MediaEngine {
  @override
  bool get supportsMedia => true;

  @override
  Future<List<PickedMedia>> pickVideos() async {
    final list = await _channel.invokeListMethod<Map>('pickVideos') ?? const [];
    return [
      for (final m in list)
        PickedMedia(m['source'] as String, m['name'] as String),
    ];
  }

  @override
  Future<MediaInfo> probe(String source) async {
    final map = await _channel.invokeMapMethod<String, Object?>('probe', {
      'source': source,
    });
    return MediaInfo.fromJson(map!);
  }

  @override
  Future<List<PickedMedia>> pickAudio() async {
    final list = await _channel.invokeListMethod<Map>('pickAudio') ?? const [];
    return [
      for (final m in list)
        PickedMedia(m['source'] as String, m['name'] as String),
    ];
  }

  @override
  Future<Uint8List> waveform(String source) async =>
      await _channel.invokeMethod<Uint8List>('waveform', {'source': source}) ??
      Uint8List(0);

  int _nextAudioId = 1;

  @override
  ClipAudioPlayer createAudioPlayer() => _AndroidClipAudio(_nextAudioId++);

  @override
  Future<List<String?>> thumbnails(
    String source,
    MediaInfo info,
    List<int> timesUs, {
    int height = 120,
  }) async {
    final list = await _channel.invokeListMethod<String?>('thumbnails', {
      'source': source,
      'timesUs': timesUs,
      'height': height,
    });
    return list ?? List.filled(timesUs.length, null);
  }

  @override
  bool get supportsBackgrounds => false;

  @override
  bool get supportsAllTransitions => true;

  /// Makes the transition's little video for the preview (in the
  /// background, with the same blending as the export), in HDR if the clips
  /// are HDR. The preview then plays it in place of the cut.
  @override
  Future<String?> renderPreviewClip(Project project, String key) async {
    final dir = await Directory(
      '${(await getApplicationCacheDirectory()).path}/transitions',
    ).create(recursive: true);
    final out = File('${dir.path}/$key.mp4');
    if (await out.exists()) return out.path;
    // Same size as the preview player's picture.
    final ratio = project.canvas.value;
    final w = ratio >= 1 ? 1920.0 : 1920 * ratio;
    final h = ratio >= 1 ? 1920 / ratio : 1920.0;
    final result = await _channel.invokeMethod<Map>('renderTransition', {
      'segments': [
        for (final seg in segmentsOf(project, blend: true)) seg.toMap(),
      ],
      ..._blendArgs(blendLayersOf(project)),
      'dips': [
        for (final d in dipsOf(project, blend: true))
          {'startUs': d.startUs, 'durationUs': d.durationUs, 'color': d.color},
      ],
      'width': (w / 2).round() * 2,
      'height': (h / 2).round() * 2,
      'frameRate': project.frameRate.round(),
      'path': '${out.path}.part.mp4',
    });
    if (result?['ok'] != true) {
      throw Exception(result?['error'] ?? 'unknown problem');
    }
    await File('${out.path}.part.mp4').rename(out.path);
    return out.path;
  }

  @override
  Future<ReverseProxy> prepareReverse(
    Clip clip, {
    void Function(double fraction)? onProgress,
  }) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/reversed');
    await dir.create(recursive: true);
    final key =
        '${clip.sourcePath.hashCode.toUnsigned(32).toRadixString(16)}_'
        '${clip.sourceInUs}_${clip.sourceOutUs}';
    final out = File('${dir.path}/$key.mp4');
    if (!await out.exists()) {
      // Ask for progress while the phone works on it.
      final timer = Timer.periodic(const Duration(milliseconds: 300), (
        _,
      ) async {
        final p = await _channel.invokeMethod<double>('reverseProgress');
        if (p != null) onProgress?.call(p);
      });
      try {
        await _channel.invokeMethod<String>('reverse', {
          'source': clip.sourcePath,
          'inUs': clip.sourceInUs,
          'outUs': clip.sourceOutUs,
          'output': out.path,
        });
      } on PlatformException catch (e) {
        throw Exception(e.message ?? 'Reversing failed.');
      } finally {
        timer.cancel();
      }
    }
    onProgress?.call(1);
    return ReverseProxy(out.path, clip.sourceInUs, clip.sourceOutUs);
  }

  @override
  Future<String?> pickOutputFolder() =>
      _channel.invokeMethod<String>('pickFolder');

  @override
  String describeFolder(String? folder) {
    if (folder == null) return 'Movies / Video Editor';
    // content://…/tree/primary%3AMovies%2FTrips → "Movies/Trips"
    final tree = Uri.decodeComponent(folder.split('/tree/').last);
    final path = tree.contains(':')
        ? tree.substring(tree.indexOf(':') + 1)
        : tree;
    return path.isEmpty ? 'Phone storage' : path;
  }

  @override
  Future<String?> checkExport(Project project, ExportSettings settings) async {
    final clips = [
      for (final c in project.mainTrack.clips)
        if (c.isMedia) c,
    ];
    if (clips.isEmpty) return 'Add a video first.';
    if (!project.background.isPlainBlack) {
      return 'Colored and blurred backgrounds can\'t be exported on Android '
          'yet. Set the background back to black.';
    }
    final transfers = {for (final c in clips) c.media!.transfer};
    final range = settings.dynamicRange;
    if (range.isHdr) {
      if (transfers.length == 1 && transfers.single == ColorTransfer.sdr) {
        return 'All your clips are SDR, so there is no HDR to keep. Choose SDR.';
      }
      if (transfers.contains(ColorTransfer.sdr)) {
        return 'On Android, an HDR export can\'t mix HDR and SDR clips yet. '
            'Choose SDR, or use only HDR clips. (Mixing arrives in a later '
            'update; the Windows version can already do it.)';
      }
      final wanted = range == DynamicRange.hlg
          ? ColorTransfer.hlg
          : ColorTransfer.pq;
      if (transfers.any((t) => t != wanted)) {
        final have = transfers.first == ColorTransfer.hlg
            ? 'HDR · HLG'
            : 'HDR · HDR10';
        return 'On Android, HDR exports keep your clips\' own HDR format. '
            'Your clips are $have, so choose "$have".';
      }
    }
    return null;
  }

  @override
  PreviewPlayer createPreview() => AndroidPreviewPlayer();

  AndroidExportJob? _job;

  @override
  Future<ExportJob> startExport(ExportRequest request) async {
    final problem = await checkExport(request.project, request.settings);
    if (problem != null) throw Exception(problem);
    final s = request.settings;
    final project = request.project;
    final clips = [
      for (final c in project.mainTrack.clips)
        if (c.isMedia) c,
    ];
    final dims = s.dimensionsFor(project.canvas);
    // Transitions: mixing ones use a second picture layer; "through
    // black/white" trim the clips and dip (see segmentsOf / blendLayersOf).
    final segments = segmentsOf(project, blend: true);
    final blends = blendLayersOf(project);
    // Media3 keeps the source frame rate when it is lower than the target
    // (it never invents frames), so the expected count follows suit.
    var frames = 0;
    var durationUs = 0;
    for (final seg in segments) {
      final fps = seg.clip!.media!.frameRate < s.frameRate
          ? seg.clip!.media!.frameRate
          : s.frameRate;
      frames += (seg.timelineUs * fps / 1000000).round();
      durationUs += seg.timelineUs;
    }
    await _channel.invokeMethod('startExport', {
      'segments': [for (final seg in segments) seg.toMap()],
      ..._blendArgs(blends),
      // If mixing fails on the phone: every transition as a dip instead.
      if (blends != null) ...{
        'fallbackSegments': [
          for (final seg in segmentsOf(project)) seg.toMap(),
        ],
        'fallbackDips': [
          for (final d in dipsOf(project))
            {
              'startUs': d.startUs,
              'durationUs': d.durationUs,
              'color': d.color,
            },
        ],
      },
      'dips': [
        for (final d in dipsOf(project, blend: true))
          {'startUs': d.startUs, 'durationUs': d.durationUs, 'color': d.color},
      ],
      'texts': textLayersFor(project, request.textImages),
      'audioTracks': [
        for (final t in project.audioTracks)
          [
            for (final a in t.clips)
              if (a.isMedia && !a.reversed)
                {
                  ...PreviewSegment.of(a).toMap(),
                  'startUs': a.startUs,
                  'hasVideo': a.media?.hasVideo ?? false,
                },
          ],
      ],
      'width': dims.width,
      'height': dims.height,
      'frameRate': s.frameRate,
      'bitrate': s.videoBitrateFor(project.canvas),
      'codec': s.codec.name,
      'range': s.dynamicRange.name,
      'folder': s.outputFolder,
      'fileName': request.fileName,
      if (s.creationTime != null)
        'createdAtMs': s.creationTime!.millisecondsSinceEpoch,
      'expectedFrames': frames,
      'expectedDurationUs': durationUs,
    });
    final job = AndroidExportJob._(clips.length);
    _job = job;
    job._startPolling();
    return job;
  }

  @override
  Future<ExportJob?> runningExport() async {
    final existing = _job;
    if (existing != null && !existing.latest.finished) return existing;
    final status = await _channel.invokeMapMethod<String, Object?>(
      'exportStatus',
    );
    final state = status?['state'];
    if (state == 'preparing' || state == 'running' || state == 'finishing') {
      final job = AndroidExportJob._(1);
      _job = job;
      job._startPolling();
      return job;
    }
    return null;
  }
}

class AndroidExportJob implements ExportJob {
  AndroidExportJob._(this._clipCount);

  final int _clipCount;
  final _controller = StreamController<ExportProgress>.broadcast();
  Timer? _timer;
  ExportProgress _latest = const ExportProgress(ExportState.preparing);

  @override
  ExportProgress get latest => _latest;

  @override
  Stream<ExportProgress> get progress => _controller.stream;

  void _startPolling() {
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  Future<void> _poll() async {
    final Map<String, Object?>? s;
    try {
      s = await _channel.invokeMapMethod<String, Object?>('exportStatus');
    } catch (_) {
      return;
    }
    if (s == null) return;
    final state = switch (s['state']) {
      'preparing' => ExportState.preparing,
      'running' => ExportState.running,
      'finishing' => ExportState.finishing,
      'done' => ExportState.done,
      'cancelled' => ExportState.cancelled,
      'failed' => ExportState.failed,
      _ => ExportState.preparing,
    };
    final v = (s['verification'] as Map?)?.cast<String, Object?>();
    final verification = v == null
        ? null
        : ExportVerification(
            expectedFrames: (v['expectedFrames'] as num).toInt(),
            actualFrames: (v['actualFrames'] as num).toInt(),
            expectedDurationUs: (v['expectedDurationUs'] as num).toInt(),
            actualDurationUs: (v['actualDurationUs'] as num).toInt(),
            isHdr: v['isHdr'] as bool?,
            // Each clip boundary may round by a frame on Android.
            toleranceFrames: _clipCount + 1,
          );
    final p = ExportProgress(
      state,
      fraction: (s['fraction'] as num?)?.toDouble() ?? 0,
      message: state == ExportState.done && verification != null
          ? verification.describe()
          : s['message'] as String?,
      outputLocation: s['location'] as String?,
      verification: verification,
    );
    _latest = p;
    if (!_controller.isClosed) _controller.add(p);
    if (p.finished) {
      _timer?.cancel();
      await _controller.close();
    }
  }

  @override
  Future<void> cancel() => _channel.invokeMethod('cancelExport');
}

/// Preview on Android: Media3's ExoPlayer drawing into a native SurfaceView,
/// which shows real HDR on the Pixel's HDR screen.
/// The second layer and transition windows, for the method channel.
Map<String, Object?> _blendArgs(BlendLayers? b) => b == null
    ? const {}
    : {
        'layerB': [for (final s in b.layerB) s.toMap()],
        'blends': [for (final w in b.windows) w.toMap()],
        'blendAudio': b.audio,
      };

class AndroidPreviewPlayer implements PreviewPlayer {
  @override
  Widget buildView(BuildContext context) => PlatformViewLink(
    viewType: 've/preview',
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) =>
        PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 've/preview',
            layoutDirection: TextDirection.ltr,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create(),
  );

  @override
  Future<void> setTimeline(
    List<PreviewSegment> segments, {
    int canvasWidth = 1920,
    int canvasHeight = 1080,
    BlendLayers? blends,
  }) => _channel.invokeMethod('previewSetTimeline', {
    'segments': [for (final s in segments) s.toMap()],
    ..._blendArgs(blends),
    'canvasWidth': canvasWidth,
    'canvasHeight': canvasHeight,
  });

  /// Transitions play from little pre-made videos (see renderPreviewClip):
  /// Media3's two-layer player can't jump around reliably.
  @override
  bool get blendsTransitions => false;

  @override
  bool drawsEffects(List<PreviewSegment> segments) =>
      segments.any((s) => s.hasEffects);

  @override
  Future<void> play() => _channel.invokeMethod('previewPlay');

  @override
  Future<void> pause() => _channel.invokeMethod('previewPause');

  @override
  Future<void> setScrubbing(bool on) =>
      _channel.invokeMethod('previewScrubbing', {'on': on});

  @override
  Future<void> seek(int timeUs, {bool exact = true}) =>
      _channel.invokeMethod('previewSeek', {'timeUs': timeUs, 'exact': exact});

  @override
  Future<void> setVolume(double volume) =>
      _channel.invokeMethod('previewVolume', {'volume': volume});

  @override
  Future<int> position() async =>
      (await _channel.invokeMethod<num>('previewPosition'))?.toInt() ?? 0;

  @override
  Future<void> dispose() =>
      _channel.invokeMethod('previewSetTimeline', {'segments': <Object>[]});
}

class _AndroidClipAudio implements ClipAudioPlayer {
  _AndroidClipAudio(this.id);

  final int id;

  @override
  Future<void> open(String source) =>
      _channel.invokeMethod('audioOpen', {'id': id, 'source': source});

  @override
  Future<void> seek(int sourceUs) =>
      _channel.invokeMethod('audioSeek', {'id': id, 'sourceUs': sourceUs});

  @override
  Future<void> play() => _channel.invokeMethod('audioPlay', {'id': id});

  @override
  Future<void> pause() => _channel.invokeMethod('audioPause', {'id': id});

  @override
  Future<void> setVolume(double volume) =>
      _channel.invokeMethod('audioVolume', {'id': id, 'volume': volume});

  @override
  Future<void> setRate(double rate) =>
      _channel.invokeMethod('audioRate', {'id': id, 'rate': rate});

  @override
  Future<void> dispose() => _channel.invokeMethod('audioRelease', {'id': id});
}
