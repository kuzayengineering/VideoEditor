import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';
import '../model/timecode.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// Records narration from the microphone while the video plays, then puts
/// it on an audio track starting where recording began.
Future<void> showVoiceOverSheet(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
) {
  c.pause();
  return showToolPanel(
    context,
    title: 'Voice-over',
    builder: (context) => _VoiceOverSheet(controller: c, engine: engine),
  );
}

class _VoiceOverSheet extends StatefulWidget {
  const _VoiceOverSheet({required this.controller, required this.engine});

  final EditorController controller;
  final MediaEngine engine;

  @override
  State<_VoiceOverSheet> createState() => _VoiceOverSheetState();
}

class _VoiceOverSheetState extends State<_VoiceOverSheet> {
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _saving = false;
  int _startUs = 0;
  final _clock = Stopwatch();
  Timer? _tick;
  StreamSubscription<Amplitude>? _levels;
  double _level = 0; // 0–1
  String? _error;

  EditorController get c => widget.controller;

  @override
  void dispose() {
    _tick?.cancel();
    _levels?.cancel();
    // Closed while recording: stop the video too (the take is dropped).
    if (_recording) c.pause();
    _recorder.dispose();
    c.previewMuted = false;
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    if (!await _recorder.hasPermission()) {
      setState(
        () => _error =
            'Microphone access was not allowed. You can allow it in the '
            'phone or PC settings for Video Editor.',
      );
      return;
    }
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/voiceovers',
    );
    await dir.create(recursive: true);
    final path =
        '${dir.path}/voiceover_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 48000,
          numChannels: 1,
          bitRate: 192000,
        ),
        path: path,
      );
    } catch (e) {
      setState(() => _error = 'Could not start recording: $e');
      return;
    }
    _levels = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((a) {
          // dBFS: -60 (quiet) … 0 (loudest).
          if (mounted) {
            setState(() => _level = ((a.current + 60) / 60).clamp(0.0, 1.0));
          }
        });
    _clock
      ..reset()
      ..start();
    _tick = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => mounted ? setState(() {}) : null,
    );
    // Play the video (silently) so you can talk along with the picture.
    c.previewMuted = true;
    c.play();
    // (Playing from the very end jumps back to the start first.)
    _startUs = c.playheadUs;
    setState(() => _recording = true);
  }

  Future<void> _stop({bool keep = true}) async {
    _tick?.cancel();
    _levels?.cancel();
    _clock.stop();
    c.pause();
    c.previewMuted = false;
    setState(() {
      _recording = false;
      _saving = keep;
    });
    final path = await _recorder.stop();
    if (!keep || path == null) {
      if (path != null) {
        unawaited(File(path).delete().then((_) {}, onError: (Object _) {}));
      }
      if (mounted) closeToolPanel(context);
      return;
    }
    try {
      final info = await widget.engine.probe(path);
      final count =
          c.project.audioTracks
              .expand((t) => t.clips)
              .where((x) => x.name.startsWith('Voice-over'))
              .length +
          1;
      final clip = Clip(
        id: 0,
        kind: ClipKind.audio,
        name: 'Voice-over $count',
        sourcePath: path,
        media: info,
        sourceDurationUs: info.durationUs,
        sourceInUs: 0,
        sourceOutUs: info.durationUs,
        startUs: _startUs,
        colorValue: 0xFF1565C0,
      );
      c.apply(c.project.addAudio(clip));
      c.seek(_startUs, exact: true);
      if (mounted) closeToolPanel(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'The recording could not be added: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = _clock.elapsedMicroseconds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _recording
              ? 'Recording… talk along with the video.'
              : 'Recording starts at the playhead '
                    '(${formatTimecode(c.playheadUs, c.project.frameRate)}). '
                    'The video plays silently while you talk.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        Text(
          formatShortDuration(_recording ? elapsed : 0),
          style: theme.textTheme.displaySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _recording ? _level : 0,
            minHeight: 8,
            color: _level > 0.92 ? Colors.redAccent : Colors.greenAccent,
          ),
        ),
        const SizedBox(height: 20),
        if (_saving)
          const CircularProgressIndicator()
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_recording)
                TextButton(
                  onPressed: () => _stop(keep: false),
                  child: const Text('Discard'),
                )
              else
                TextButton(
                  onPressed: () => closeToolPanel(context),
                  child: const Text('Close'),
                ),
              const SizedBox(width: 24),
              SizedBox(
                width: 76,
                height: 76,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    backgroundColor: Colors.redAccent,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: _recording ? _stop : _start,
                  child: Icon(
                    _recording ? Icons.stop_rounded : Icons.mic,
                    size: 38,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 24 + 64),
            ],
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
