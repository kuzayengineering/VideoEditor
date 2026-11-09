import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
    final info = MediaInfo.fromJson(map!);
    if (!info.hasVideo || info.width == 0) {
      throw Exception('This file has no video picture in it.');
    }
    return info;
  }

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
    // Media3 keeps the source frame rate when it is lower than the target
    // (it never invents frames), so the expected count follows suit.
    var frames = 0;
    var durationUs = 0;
    for (final c in clips) {
      final fps = c.media!.frameRate < s.frameRate
          ? c.media!.frameRate
          : s.frameRate;
      frames += (c.durationUs * fps / 1000000).round();
      durationUs += c.durationUs;
    }
    await _channel.invokeMethod('startExport', {
      'segments': [
        for (final c in clips)
          {
            'source': c.sourcePath,
            'inUs': c.sourceInUs,
            'outUs': c.sourceOutUs,
            'hasAudio': c.media!.hasAudio,
            'frameRate': c.media!.frameRate,
          },
      ],
      'width': dims.width,
      'height': dims.height,
      'frameRate': s.frameRate,
      'bitrate': s.videoBitrateFor(project.canvas),
      'codec': s.codec.name,
      'range': s.dynamicRange.name,
      'folder': s.outputFolder,
      'fileName': request.fileName,
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
  Future<void> setTimeline(List<PreviewSegment> segments) =>
      _channel.invokeMethod('previewSetTimeline', {
        'segments': [
          for (final s in segments)
            {'source': s.source, 'inUs': s.inUs, 'outUs': s.outUs},
        ],
      });

  @override
  Future<void> play() => _channel.invokeMethod('previewPlay');

  @override
  Future<void> pause() => _channel.invokeMethod('previewPause');

  @override
  Future<void> seek(int timeUs, {bool exact = true}) =>
      _channel.invokeMethod('previewSeek', {'timeUs': timeUs, 'exact': exact});

  @override
  Future<int> position() async =>
      (await _channel.invokeMethod<num>('previewPosition'))?.toInt() ?? 0;

  @override
  Future<void> dispose() =>
      _channel.invokeMethod('previewSetTimeline', {'segments': []});
}
