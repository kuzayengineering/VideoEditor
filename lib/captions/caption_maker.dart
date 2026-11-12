import 'dart:io';

import '../engine/media_engine.dart';
import '../model/project.dart';
import 'speech_models.dart';
import 'whisper.dart';

/// Makes auto captions for a project: downloads the speech model once,
/// takes the sound of each clip, recognises the words and groups them into
/// caption lines on the timeline.
class CaptionMaker {
  CaptionMaker(this.engine, {SpeechModelStore? store, Whisper? whisper})
    : store = store ?? SpeechModelStore(),
      whisper = whisper ?? Whisper.instance;

  final MediaEngine engine;
  final SpeechModelStore store;
  final Whisper whisper;

  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    whisper.cancel();
  }

  /// The clips whose speech is captioned: [clipId] alone, or all the main
  /// video clips with sound plus voice-overs.
  static List<ClipPlacement> sourcesOf(Project project, {int? clipId}) {
    bool speaks(Clip c) =>
        c.isMedia &&
        (c.media!.hasAudio) &&
        c.volume > 0.001 &&
        !c.reversed &&
        c.durationUs >= 300000;
    if (clipId != null) {
      final p = project.placementOf(clipId);
      return p != null && speaks(p.clip) ? [p] : const [];
    }
    return [
      for (final p in project.placementsOn(project.mainTrack))
        if (speaks(p.clip)) p,
      for (final t in project.audioTracks)
        for (final p in project.placementsOn(t))
          if (speaks(p.clip) && p.clip.name.startsWith('Voice-over')) p,
    ];
  }

  /// Moves words heard in [p]'s clip (times from the start of its part of
  /// the file) onto the timeline, dropping any outside the clip.
  static List<SpokenWord> placeWords(ClipPlacement p, List<SpokenWord> words) {
    final c = p.clip;
    return [
      for (final w in words)
        if (w.startUs / c.speed < c.durationUs)
          SpokenWord(
            p.startUs + (w.startUs / c.speed).round(),
            p.startUs +
                (w.endUs / c.speed).round().clamp(0, c.durationUs).toInt(),
            w.text,
          ),
    ];
  }

  /// Returns the caption lines, or throws [CaptionsCancelled].
  /// [onStatus] gets a message and the fraction done (null while unknown).
  Future<List<CaptionLine>> make(
    Project project, {
    int? clipId,
    required CaptionAccuracy accuracy,
    required bool english,
    required void Function(String message, double? fraction) onStatus,
  }) async {
    _cancelled = false;
    final sources = sourcesOf(project, clipId: clipId);
    if (sources.isEmpty) return const [];

    final model = SpeechModel.of(accuracy, english: english);
    if (await store.pathIfPresent(model) == null) {
      onStatus('Downloading the speech model (${model.sizeLabel}, once)…', 0);
    }
    final modelPath = await store.ensure(
      model,
      onProgress: (f) => onStatus(
        'Downloading the speech model (${model.sizeLabel}, once)…',
        f,
      ),
      cancelled: () => _cancelled,
    );

    final total = sources.fold<int>(0, (t, p) => t + p.clip.durationUs);
    var done = 0;
    final words = <SpokenWord>[];
    final temp = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'vc_speech_${DateTime.now().microsecondsSinceEpoch}.f32',
    );
    try {
      for (final p in sources) {
        if (_cancelled) throw const CaptionsCancelled();
        final c = p.clip;
        void report(double within) => onStatus(
          'Listening to the speech…',
          (done + within * c.durationUs) / total,
        );
        report(0);
        await engine.speechAudio(
          c.sourcePath!,
          c.sourceInUs,
          c.sourceOutUs,
          temp.path,
        );
        final samples = await readSpeechSamples(temp.path);
        if (samples.length > 16000 ~/ 4) {
          final heard = await whisper.transcribe(
            modelPath,
            samples,
            language: english ? 'en' : 'auto',
            onProgress: (pct) => report(pct / 100),
          );
          if (heard == null) throw const CaptionsCancelled();
          words.addAll(placeWords(p, heard.words));
        }
        done += c.durationUs;
      }
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    words.sort((a, b) => a.startUs.compareTo(b.startUs));
    // Never past the end of the video.
    final end = project.durationUs;
    return [
      for (final l in groupCaptions(words))
        if (l.startUs < end - 100000)
          l.endUs <= end ? l : CaptionLine(l.startUs, end, l.text),
    ];
  }
}
