import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../model/export_settings.dart';
import '../model/project.dart';

/// A video file chosen by the user, before it has been examined.
class PickedMedia {
  const PickedMedia(this.source, this.displayName);

  /// File path (Windows) or content:// address (Android).
  final String source;
  final String displayName;
}

/// One stretch of the main track, as the preview player needs it.
class PreviewSegment {
  const PreviewSegment(
    this.source,
    this.inUs,
    this.outUs, {
    this.speed = 1.0,
    this.clip,
    this.dipInUs = 0,
    this.dipOutUs = 0,
    this.blendOutUs = 0,
  });

  /// Fade-through-black at the start / end (sound fades with it).
  final int dipInUs;
  final int dipOutUs;

  /// The end overlaps a mixing transition: the sound fades out over this
  /// long while the next clip's fades in.
  final int blendOutUs;

  /// From a clip: backwards clips use their reversed copy.
  factory PreviewSegment.of(
    Clip c, {
    int dipInUs = 0,
    int dipOutUs = 0,
    int blendOutUs = 0,
  }) {
    final proxy = c.reverseProxy;
    if (c.reversed &&
        proxy != null &&
        proxy.covers(c.sourceInUs, c.sourceOutUs)) {
      return PreviewSegment(
        proxy.path,
        proxy.proxyTimeOf(c.sourceOutUs),
        proxy.proxyTimeOf(c.sourceInUs),
        speed: c.speed,
        clip: c,
        dipInUs: dipInUs,
        dipOutUs: dipOutUs,
        blendOutUs: blendOutUs,
      );
    }
    return PreviewSegment(
      c.sourcePath!,
      c.sourceInUs,
      c.sourceOutUs,
      speed: c.speed,
      clip: c,
      dipInUs: dipInUs,
      dipOutUs: dipOutUs,
      blendOutUs: blendOutUs,
    );
  }

  final String source;
  final int inUs;
  final int outUs;
  final double speed;

  /// The clip this came from (for rotation, crop and so on).
  final Clip? clip;

  int get lengthUs => outUs - inUs;

  /// Length on the timeline (after speed).
  int get timelineUs => (lengthUs / speed).round();

  bool get hasEffects => (clip?.hasLook ?? false) || (speed - 1).abs() > 0.0001;

  Map<String, Object?> toMap() {
    final c = clip;
    return {
      'source': source,
      'inUs': inUs,
      'outUs': outUs,
      'speed': speed,
      if (c != null) ...{
        'hasAudio': c.media?.hasAudio ?? true,
        'frameRate': c.media?.frameRate ?? 30,
        // Reversed copies are only as long as the range they cover.
        'sourceDurationUs': c.reverseReady
            ? c.reverseProxy!.sourceOutUs - c.reverseProxy!.sourceInUs
            : c.sourceDurationUs,
        'rotation': c.rotation,
        'flipH': c.flipH,
        'flipV': c.flipV,
        'crop': c.crop.toJson(),
        'opacity': c.opacity,
        'volume': c.volume,
        'fadeInUs': c.effectiveFades.fadeIn > dipInUs
            ? c.effectiveFades.fadeIn
            : dipInUs,
        'fadeOutUs': c.effectiveFades.fadeOut > dipOutUs
            ? c.effectiveFades.fadeOut
            : dipOutUs,
        if (blendOutUs > 0) 'blendOutUs': blendOutUs,
      },
    };
  }

  @override
  bool operator ==(Object other) =>
      other is PreviewSegment &&
      other.source == source &&
      other.inUs == inUs &&
      other.outUs == outUs &&
      other.speed == speed &&
      other.dipInUs == dipInUs &&
      other.dipOutUs == dipOutUs &&
      other.blendOutUs == blendOutUs &&
      other.clip?.rotation == clip?.rotation &&
      other.clip?.flipH == clip?.flipH &&
      other.clip?.flipV == clip?.flipV &&
      other.clip?.crop == clip?.crop &&
      other.clip?.opacity == clip?.opacity;

  @override
  int get hashCode => Object.hash(source, inUs, outUs, speed);
}

/// Main-track clips that can be previewed / exported, in order.
///
/// Transitions overlap neighbouring clips. With a pre-rendered transition
/// (in [transitionFiles], by [Project.transitionKey]) the clips are cut
/// short by its full length and the rendered piece plays in between.
/// "Through black/white" (and, unless [blend], every other kind as a
/// stand-in) take half the transition off each clip and dip through the
/// colour. With [blend] (Android), mixing transitions keep the outgoing
/// clip whole and start the next clip after the overlap; the incoming part
/// comes from a second layer (see [blendLayersOf]).
List<PreviewSegment> segmentsOf(
  Project project, {
  Map<String, String> transitionFiles = const {},
  bool blend = false,
}) {
  final clips = project.mainTrack.clips;
  final n = clips.length;
  final head = List.filled(n, 0), tail = List.filled(n, 0);
  final dipHead = List.filled(n, 0), dipTail = List.filled(n, 0);
  final blendOut = List.filled(n, 0);
  final rendered = <int, (String, int)>{};
  for (var i = 0; i + 1 < n; i++) {
    final d = project.transitionUsAfter(i);
    if (d <= 0) continue;
    final file = transitionFiles[project.transitionKey(i)];
    if (file != null) {
      tail[i] = d;
      head[i + 1] = d;
      rendered[i] = (file, d);
    } else if (blend && !clips[i].transition!.kind.isDip) {
      head[i + 1] = d;
      blendOut[i] = d;
    } else {
      tail[i] = d ~/ 2;
      head[i + 1] = d - d ~/ 2;
      dipTail[i] = tail[i];
      dipHead[i + 1] = head[i + 1];
    }
  }
  final out = <PreviewSegment>[];
  for (var i = 0; i < n; i++) {
    final c = clips[i];
    if (!c.isMedia) continue;
    out.add(
      PreviewSegment.of(
        c.trimmedBy(headUs: head[i], tailUs: tail[i]),
        dipInUs: dipHead[i],
        dipOutUs: dipTail[i],
        blendOutUs: blendOut[i],
      ),
    );
    final r = rendered[i];
    if (r != null) out.add(PreviewSegment(r.$1, r.$2, 2 * r.$2));
  }
  return out;
}

/// One transition that mixes two clips, as Android draws it.
class BlendWindow {
  const BlendWindow(this.startUs, this.durationUs, this.code);

  final int startUs;
  final int durationUs;

  /// Which picture ([TransitionKind.code]).
  final int code;

  Map<String, Object?> toMap() => {
    'startUs': startUs,
    'durationUs': durationUs,
    'code': code,
  };

  @override
  bool operator ==(Object other) =>
      other is BlendWindow &&
      other.startUs == startUs &&
      other.durationUs == durationUs &&
      other.code == code;

  @override
  int get hashCode => Object.hash(startUs, durationUs, code);
}

/// What Android needs to mix clips during transitions: a second picture
/// layer, lined up with [segmentsOf] (`blend: true`), that holds each
/// incoming clip's start while the first layer still shows the outgoing
/// clip's end, plus the sound of those starts.
class BlendLayers {
  const BlendLayers(this.layerB, this.windows, this.audio);

  /// Same length as the main layer; outside transitions it shows the same
  /// clips (it is silent).
  final List<PreviewSegment> layerB;
  final List<BlendWindow> windows;

  /// The incoming clips' sound during each transition (fades in), as
  /// audio-track entries with `startUs`.
  final List<Map<String, Object?>> audio;

  @override
  bool operator ==(Object other) =>
      other is BlendLayers &&
      listEquals(other.layerB, layerB) &&
      listEquals(other.windows, windows) &&
      other.audio.length == audio.length;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(layerB), Object.hashAll(windows));
}

/// The second layer for mixing transitions, or null if there are none.
BlendLayers? blendLayersOf(Project project) {
  final clips = project.mainTrack.clips;
  final n = clips.length;
  final placements = project.placementsOn(project.mainTrack);
  final head = List.filled(n, 0), tail = List.filled(n, 0);
  final windows = <BlendWindow>[];
  final audio = <Map<String, Object?>>[];
  for (var i = 0; i + 1 < n; i++) {
    final d = project.transitionUsAfter(i);
    if (d <= 0) continue;
    final kind = clips[i].transition!.kind;
    if (kind.isDip) {
      tail[i] = d ~/ 2;
      head[i + 1] = d - d ~/ 2;
      continue;
    }
    tail[i] = d;
    final start = placements[i + 1].startUs;
    windows.add(BlendWindow(start, d, kind.code));
    final next = clips[i + 1];
    if (next.isMedia && (next.media?.hasAudio ?? false)) {
      audio.add({
        ...PreviewSegment.of(next.trimmedBy(tailUs: next.durationUs - d))
            .toMap(),
        'fadeInUs': d,
        'fadeOutUs': 0,
        'startUs': start,
        'hasVideo': true,
      });
    }
  }
  if (windows.isEmpty) return null;
  return BlendLayers(
    [
      for (var i = 0; i < n; i++)
        if (clips[i].isMedia)
          PreviewSegment.of(
            clips[i].trimmedBy(headUs: head[i], tailUs: tail[i]),
          ),
    ],
    windows,
    audio,
  );
}

/// One dip through a colour on the timeline.
typedef Dip = ({int startUs, int durationUs, int color});

/// Where the dips through black/white happen on the timeline: every
/// transition without a pre-rendered copy, or with [blend] only the
/// "through black/white" ones. Mixing kinds dip through black as a
/// stand-in.
List<Dip> dipsOf(
  Project project, {
  Map<String, String> transitionFiles = const {},
  bool blend = false,
}) {
  final ps = project.placementsOn(project.mainTrack);
  final clips = project.mainTrack.clips;
  return [
    for (var i = 0; i + 1 < ps.length; i++)
      if (project.transitionUsAfter(i) > 0 &&
          transitionFiles[project.transitionKey(i)] == null &&
          (!blend || clips[i].transition!.kind.isDip))
        (
          startUs: ps[i + 1].startUs,
          durationUs: project.transitionUsAfter(i),
          color: clips[i].transition!.kind.dipColor,
        ),
  ];
}

/// Plays one audio-track clip during preview.
abstract class ClipAudioPlayer {
  Future<void> open(String source);

  /// Jumps to [sourceUs] in the file.
  Future<void> seek(int sourceUs);
  Future<void> play();
  Future<void> pause();

  /// 0.0–1.0 (preview can't go louder than the file).
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
  Future<void> dispose();
}

/// Shows the edit while editing.
abstract class PreviewPlayer {
  /// The video picture.
  Widget buildView(BuildContext context);

  /// Replaces what is being previewed. The playhead position is kept.
  /// [canvasWidth]/[canvasHeight] give the output shape.
  Future<void> setTimeline(
    List<PreviewSegment> segments, {
    int canvasWidth = 1920,
    int canvasHeight = 1080,
    BlendLayers? blends,
  });

  /// True if this player mixes clips during transitions itself (it then
  /// gets [segmentsOf] with `blend: true` plus [blendLayersOf]).
  bool get blendsTransitions;

  /// True if the player itself draws turn/mirror/crop/opacity and the black
  /// bars for these segments (the picture then fills the whole canvas).
  /// False means the screen applies them around the plain video.
  bool drawsEffects(List<PreviewSegment> segments);

  Future<void> play();
  Future<void> pause();

  /// Jumps to a timeline position. [exact] lands on the exact frame (slower);
  /// otherwise the nearest quick-to-reach frame is shown (for scrubbing).
  Future<void> seek(int timeUs, {bool exact = true});

  /// Current timeline position.
  Future<int> position();

  /// Loudness of the video's own sound (0.0–1.0).
  Future<void> setVolume(double volume);

  Future<void> dispose();
}

enum ExportState { preparing, running, finishing, done, failed, cancelled }

class ExportProgress {
  const ExportProgress(
    this.state, {
    this.fraction = 0,
    this.message,
    this.outputLocation,
    this.verification,
  });

  final ExportState state;

  /// 0.0 to 1.0.
  final double fraction;

  /// Error or status text.
  final String? message;

  /// Where the finished file was saved (shown to the user).
  final String? outputLocation;

  /// Result of checking the finished file. `null` until done.
  final ExportVerification? verification;

  bool get finished =>
      state == ExportState.done ||
      state == ExportState.failed ||
      state == ExportState.cancelled;
}

/// Checks a finished export against what was expected, so a broken file
/// (missing or frozen frames) is caught before it gets shared.
class ExportVerification {
  const ExportVerification({
    required this.expectedFrames,
    required this.actualFrames,
    required this.expectedDurationUs,
    required this.actualDurationUs,
    this.isHdr,
    this.toleranceFrames,
  });

  /// How many frames the count may differ by (rounding at cuts). Defaults to
  /// a small allowance based on length.
  final int? toleranceFrames;

  final int expectedFrames;
  final int actualFrames;
  final int expectedDurationUs;
  final int actualDurationUs;

  /// HDR signalling found in the file (null if it couldn't be read).
  final bool? isHdr;

  /// True when the frame count matches (within [toleranceFrames]).
  bool get ok {
    final tolerance =
        toleranceFrames ?? (expectedFrames / 600).ceil().clamp(1, 3);
    return (actualFrames - expectedFrames).abs() <= tolerance;
  }

  String describe() => ok
      ? 'Checked: $actualFrames frames, as expected.'
      : 'Warning: expected $expectedFrames frames but the file has '
            '$actualFrames. Please check the video before sharing it.';
}

/// The pictures of one text overlay, drawn by the app for the exporters.
class TextImages {
  const TextImages({
    required this.fullPath,
    required this.width,
    required this.height,
    this.typewriterPaths = const [],
  });

  /// The whole text (transparent PNG).
  final String fullPath;
  final int width;
  final int height;

  /// For typewriter animations: the picture with i letters at index i (all
  /// the same size as the full one). Empty otherwise.
  final List<String> typewriterPaths;

  Map<String, Object?> toMap() => {
    'full': fullPath,
    'width': width,
    'height': height,
    'typewriter': typewriterPaths,
  };
}

class ExportRequest {
  const ExportRequest({
    required this.project,
    required this.settings,
    required this.fileName,
    this.textImages = const {},
  });

  /// Pictures of the text overlays, by clip id.
  final Map<int, TextImages> textImages;

  final Project project;
  final ExportSettings settings;

  /// File name without folder, e.g. "My trip 2026-11-09 1530.mp4".
  final String fileName;
}

/// A running export.
abstract class ExportJob {
  Stream<ExportProgress> get progress;
  ExportProgress get latest;
  Future<void> cancel();
}

/// What a platform can do: import, examine, preview and export media.
abstract class MediaEngine {
  /// False on platforms without a video engine (e.g. tests): the app then
  /// only offers the demo project.
  bool get supportsMedia;

  /// Asks the user to choose videos.
  Future<List<PickedMedia>> pickVideos();

  /// Asks the user to choose music, sounds, or videos whose sound to use.
  Future<List<PickedMedia>> pickAudio();

  /// Reads size, frame rate, HDR type and so on (works for sound-only
  /// files too: then [MediaInfo.hasVideo] is false).
  Future<MediaInfo> probe(String source);

  /// The loudness outline of a file's sound: 100 values per second, each
  /// 0–255. Empty if the file has no sound.
  Future<Uint8List> waveform(String source);

  ClipAudioPlayer createAudioPlayer();

  /// Small preview images at the given source times. Returns one file path
  /// per requested time (null where a frame couldn't be made).
  Future<List<String?>> thumbnails(
    String source,
    MediaInfo info,
    List<int> timesUs, {
    int height = 120,
  });

  /// Prepares a backwards copy of [clip]'s range (see [ReverseProxy]).
  /// [onProgress] receives 0.0–1.0. Throws if this platform can't do it.
  Future<ReverseProxy> prepareReverse(
    Clip clip, {
    void Function(double fraction)? onProgress,
  });

  /// Whether colored or blurred backgrounds can be exported here.
  bool get supportsBackgrounds;

  /// Whether every transition type can be exported here (Android shows them
  /// all as fade-through-black for now).
  bool get supportsAllTransitions;

  /// Renders a small project (a transition with a little either side) to a
  /// preview-quality video file, or returns null if this platform doesn't.
  Future<String?> renderPreviewClip(Project project, String key);

  /// Asks the user to choose a folder to save exports to.
  /// Returns an opaque folder reference, or null if cancelled.
  Future<String?> pickOutputFolder();

  /// Human-readable name for a folder reference (null = default folder).
  String describeFolder(String? folder);

  /// Explains export limits on this platform for the given settings, or
  /// returns null if they are fine.
  Future<String?> checkExport(Project project, ExportSettings settings);

  PreviewPlayer createPreview();

  Future<ExportJob> startExport(ExportRequest request);

  /// An export that is still running (e.g. after the app was reopened).
  Future<ExportJob?> runningExport();
}

/// Used where no engine exists (tests, unsupported platforms).
class NoMediaEngine implements MediaEngine {
  const NoMediaEngine();

  @override
  bool get supportsMedia => false;

  @override
  Future<List<PickedMedia>> pickVideos() async => const [];

  @override
  Future<MediaInfo> probe(String source) =>
      Future.error(UnsupportedError('No video engine on this platform'));

  @override
  Future<List<PickedMedia>> pickAudio() async => const [];

  @override
  Future<Uint8List> waveform(String source) async => Uint8List(0);

  @override
  ClipAudioPlayer createAudioPlayer() =>
      throw UnsupportedError('No video engine on this platform');

  @override
  Future<List<String?>> thumbnails(
    String source,
    MediaInfo info,
    List<int> timesUs, {
    int height = 120,
  }) async => List.filled(timesUs.length, null);

  @override
  Future<String?> pickOutputFolder() async => null;

  @override
  Future<ReverseProxy> prepareReverse(
    Clip clip, {
    void Function(double fraction)? onProgress,
  }) => Future.error(UnsupportedError('No video engine on this platform'));

  @override
  bool get supportsBackgrounds => true;

  @override
  bool get supportsAllTransitions => true;

  @override
  Future<String?> renderPreviewClip(Project project, String key) async => null;

  @override
  String describeFolder(String? folder) => folder ?? 'Default folder';

  @override
  Future<String?> checkExport(Project project, ExportSettings settings) async =>
      'Exporting is not available on this platform.';

  @override
  PreviewPlayer createPreview() =>
      throw UnsupportedError('No video engine on this platform');

  @override
  Future<ExportJob> startExport(ExportRequest request) =>
      Future.error(UnsupportedError('No video engine on this platform'));

  @override
  Future<ExportJob?> runningExport() async => null;
}

/// Text overlays as the Android exporter needs them: timing (cut to the
/// video's length), position, animations and pictures.
List<Map<String, Object?>> textLayersFor(
  Project project,
  Map<int, TextImages> images,
) {
  // The video's length (transitions make it shorter than the clips added up).
  final ps = project.placementsOn(project.mainTrack);
  final videoUs = ps.isEmpty ? 0 : ps.last.endUs;
  return [
    for (final t in project.textTracks)
      for (final c in t.clips)
        if (c.text != null && images[c.id] != null && c.startUs < videoUs)
          {
            ...images[c.id]!.toMap(),
            'startUs': c.startUs,
            'durationUs': (c.durationUs < videoUs - c.startUs)
                ? c.durationUs
                : videoUs - c.startUs,
            'x': c.text!.x,
            'y': c.text!.y,
            'animIn': c.text!.animIn.name,
            'animInUs': c.text!.animInUs,
            'animOut': c.text!.animOut.name,
            'animOutUs': c.text!.animOutUs,
            'charCount': c.text!.text.runes.length,
          },
  ];
}
