import 'dart:async';

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
  });

  /// From a clip: backwards clips use their reversed copy.
  factory PreviewSegment.of(Clip c) {
    final proxy = c.reverseProxy;
    if (c.reverseReady && proxy != null) {
      return PreviewSegment(
        proxy.path,
        proxy.proxyTimeOf(c.sourceOutUs),
        proxy.proxyTimeOf(c.sourceInUs),
        speed: c.speed,
        clip: c,
      );
    }
    return PreviewSegment(
      c.sourcePath!,
      c.sourceInUs,
      c.sourceOutUs,
      speed: c.speed,
      clip: c,
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
      other.clip?.rotation == clip?.rotation &&
      other.clip?.flipH == clip?.flipH &&
      other.clip?.flipV == clip?.flipV &&
      other.clip?.crop == clip?.crop &&
      other.clip?.opacity == clip?.opacity;

  @override
  int get hashCode => Object.hash(source, inUs, outUs, speed);
}

/// Main-track clips that can be previewed / exported, in order.
List<PreviewSegment> segmentsOf(Project project) => [
  for (final c in project.mainTrack.clips)
    if (c.isMedia) PreviewSegment.of(c),
];

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
  });

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

class ExportRequest {
  const ExportRequest({
    required this.project,
    required this.settings,
    required this.fileName,
  });

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

  /// Reads size, frame rate, HDR type and so on.
  Future<MediaInfo> probe(String source);

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
