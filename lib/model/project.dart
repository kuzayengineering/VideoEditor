import 'dart:math' as math;

import 'clip.dart';
import 'timecode.dart';

export 'clip.dart';

/// The shape of the video frame (the "canvas").
class CanvasRatio {
  const CanvasRatio(this.label, this.width, this.height, {this.hint});

  final String label;
  final int width;
  final int height;

  /// Where this shape is typically used, e.g. "YouTube".
  final String? hint;

  double get value => width / height;

  bool sameShapeAs(CanvasRatio other) =>
      width * other.height == height * other.width;

  static const landscape16x9 = CanvasRatio('16:9', 16, 9, hint: 'YouTube, TV');
  static const portrait9x16 = CanvasRatio(
    '9:16',
    9,
    16,
    hint: 'Shorts, Reels, TikTok',
  );
  static const square = CanvasRatio('1:1', 1, 1, hint: 'Square posts');
  static const portrait4x5 = CanvasRatio('4:5', 4, 5, hint: 'Instagram feed');
  static const landscape4x3 = CanvasRatio('4:3', 4, 3, hint: 'Classic');
  static const portrait3x4 = CanvasRatio('3:4', 3, 4, hint: 'Classic tall');
  static const cinema21x9 = CanvasRatio('21:9', 21, 9, hint: 'Cinematic');

  static const presets = [
    landscape16x9,
    portrait9x16,
    square,
    portrait4x5,
    landscape4x3,
    portrait3x4,
    cinema21x9,
  ];

  /// A custom shape. Values are reduced, so 1920:1080 becomes 16:9.
  factory CanvasRatio.custom(int width, int height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Width and height must be positive');
    }
    final g = _gcd(width, height);
    final w = width ~/ g;
    final h = height ~/ g;
    for (final preset in presets) {
      if (preset.width == w && preset.height == h) return preset;
    }
    return CanvasRatio('$w:$h', w, h, hint: 'Custom');
  }

  Map<String, Object?> toJson() => {'width': width, 'height': height};

  factory CanvasRatio.fromJson(Map<String, Object?> json) => CanvasRatio.custom(
    (json['width'] as num).toInt(),
    (json['height'] as num).toInt(),
  );

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
}

/// What a track holds.
enum TrackKind {
  /// The main video track. Clips sit end-to-end with no gaps, like YouCut.
  main,

  /// An audio track. Clips can be placed anywhere, with gaps between them.
  audio,
}

class Track {
  const Track({required this.id, required this.kind, this.clips = const []});

  final int id;
  final TrackKind kind;
  final List<Clip> clips;

  Track withClips(List<Clip> clips) =>
      Track(id: id, kind: kind, clips: List.unmodifiable(clips));

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'clips': [for (final c in clips) c.toJson()],
  };

  factory Track.fromJson(Map<String, Object?> json) => Track(
    id: (json['id'] as num).toInt(),
    kind: TrackKind.values.byName(json['kind'] as String),
    clips: List.unmodifiable([
      for (final c in json['clips'] as List)
        Clip.fromJson((c as Map).cast<String, Object?>()),
    ]),
  );
}

/// Where a clip actually sits on the timeline.
class ClipPlacement {
  const ClipPlacement(this.clip, this.track, this.index, this.startUs);

  final Clip clip;
  final Track track;

  /// Position of the clip within its track.
  final int index;
  final int startUs;

  int get endUs => startUs + clip.durationUs;

  bool contains(int timeUs) => timeUs >= startUs && timeUs < endUs;
}

/// A whole edit: the "recipe" that turns original files into a finished video.
///
/// Projects are never modified in place. Every edit returns a new [Project],
/// which is what makes unlimited undo/redo simple and reliable. An edit that
/// changes nothing returns the same object, so callers can check with
/// [identical].
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.frameRate,
    required this.canvas,
    required this.mainTrack,
    required this.nextId,
    this.audioTracks = const [],
  });

  /// Creates an empty project.
  factory Project.empty({
    required String id,
    String name = 'Untitled project',
    double frameRate = 60,
    CanvasRatio canvas = CanvasRatio.landscape16x9,
  }) => Project(
    id: id,
    name: name,
    frameRate: frameRate,
    canvas: canvas,
    mainTrack: const Track(id: 1, kind: TrackKind.main),
    nextId: 2,
  );

  static const int formatVersion = 1;

  final String id;
  final String name;

  /// Frames per second of the timeline. Frame-step buttons and cuts snap to
  /// this.
  final double frameRate;
  final CanvasRatio canvas;
  final Track mainTrack;
  final List<Track> audioTracks;

  /// Next unused id for clips and tracks.
  final int nextId;

  List<Track> get tracks => [mainTrack, ...audioTracks];

  /// The shortest a clip is allowed to be: one frame.
  int get minClipUs => frameDurationUs(frameRate);

  int get frameUs => frameDurationUs(frameRate);

  // ---------------------------------------------------------------------------
  // Reading the timeline
  // ---------------------------------------------------------------------------

  List<ClipPlacement> placementsOn(Track track) {
    final result = <ClipPlacement>[];
    var cursor = 0;
    for (var i = 0; i < track.clips.length; i++) {
      final clip = track.clips[i];
      final start = track.kind == TrackKind.main ? cursor : clip.startUs;
      result.add(ClipPlacement(clip, track, i, start));
      cursor = start + clip.durationUs;
    }
    return result;
  }

  Iterable<ClipPlacement> get allPlacements sync* {
    for (final track in tracks) {
      yield* placementsOn(track);
    }
  }

  /// Total length of the edit.
  int get durationUs {
    var end = 0;
    for (final p in allPlacements) {
      end = math.max(end, p.endUs);
    }
    return end;
  }

  ClipPlacement? placementOf(int clipId) {
    for (final p in allPlacements) {
      if (p.clip.id == clipId) return p;
    }
    return null;
  }

  /// The main-track clip that is showing at [timeUs], if any.
  ClipPlacement? mainClipAt(int timeUs) {
    for (final p in placementsOn(mainTrack)) {
      if (p.contains(timeUs)) return p;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------------

  Project copyWith({
    String? name,
    double? frameRate,
    CanvasRatio? canvas,
    Track? mainTrack,
    List<Track>? audioTracks,
    int? nextId,
  }) => Project(
    id: id,
    name: name ?? this.name,
    frameRate: frameRate ?? this.frameRate,
    canvas: canvas ?? this.canvas,
    mainTrack: mainTrack ?? this.mainTrack,
    audioTracks: audioTracks ?? this.audioTracks,
    nextId: nextId ?? this.nextId,
  );

  Project withCanvas(CanvasRatio canvas) =>
      this.canvas.sameShapeAs(canvas) ? this : copyWith(canvas: canvas);

  Project renamed(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty || trimmed == this.name
        ? this
        : copyWith(name: trimmed);
  }

  Project _withTrack(Track track) {
    if (track.id == mainTrack.id) return copyWith(mainTrack: track);
    return copyWith(
      audioTracks: [for (final t in audioTracks) t.id == track.id ? track : t],
    );
  }

  /// Adds a video clip to the end of the main track.
  Project appendVideo(Clip clip) {
    final placed = clip.copyWith(id: nextId);
    return copyWith(
      mainTrack: mainTrack.withClips([...mainTrack.clips, placed]),
      nextId: nextId + 1,
    );
  }

  /// Adds an audio clip at its [Clip.startUs], on the first audio track with
  /// room for it. A new track is created if none has room.
  Project addAudio(Clip clip) {
    var project = this;
    final placed = clip.copyWith(id: project.nextId);
    project = project.copyWith(nextId: project.nextId + 1);
    return project._placeOnFreeAudioTrack(placed);
  }

  Project _placeOnFreeAudioTrack(Clip clip) {
    for (final track in audioTracks) {
      final fits = track.clips.every(
        (c) => clip.endUs <= c.startUs || clip.startUs >= c.endUs,
      );
      if (fits) {
        final clips = [...track.clips, clip]
          ..sort((a, b) => a.startUs.compareTo(b.startUs));
        return _withTrack(track.withClips(clips));
      }
    }
    final track = Track(
      id: nextId,
      kind: TrackKind.audio,
      clips: List.unmodifiable([clip]),
    );
    return copyWith(audioTracks: [...audioTracks, track], nextId: nextId + 1);
  }

  /// Cuts a clip in two at [timeUs].
  ///
  /// Splits the clip with [clipId] if given, otherwise the main-track clip
  /// under [timeUs]. Nothing happens if the cut would leave a piece shorter
  /// than one frame.
  Project splitAt(int timeUs, {int? clipId}) {
    final p = clipId != null ? placementOf(clipId) : mainClipAt(timeUs);
    if (p == null) return this;
    if (timeUs - p.startUs < minClipUs || p.endUs - timeUs < minClipUs) {
      return this;
    }
    final clip = p.clip;
    final cutSourceUs =
        clip.sourceInUs + ((timeUs - p.startUs) * clip.speed).round();
    final left = clip.copyWith(sourceOutUs: cutSourceUs);
    final right = clip.copyWith(
      id: nextId,
      sourceInUs: cutSourceUs,
      startUs: timeUs,
    );
    final clips = [...p.track.clips]
      ..replaceRange(p.index, p.index + 1, [left, right]);
    return _withTrack(p.track.withClips(clips)).copyWith(nextId: nextId + 1);
  }

  /// Makes a copy of a clip and places it right after the original.
  Project duplicateClip(int clipId) {
    final p = placementOf(clipId);
    if (p == null) return this;
    final copy = p.clip.copyWith(id: nextId, startUs: p.endUs);
    if (p.track.kind == TrackKind.main) {
      final clips = [...p.track.clips]..insert(p.index + 1, copy);
      return _withTrack(p.track.withClips(clips)).copyWith(nextId: nextId + 1);
    }
    return copyWith(nextId: nextId + 1)._placeOnFreeAudioTrack(copy);
  }

  /// Removes a clip. Empty audio tracks are removed too.
  Project deleteClip(int clipId) {
    final p = placementOf(clipId);
    if (p == null) return this;
    final clips = [...p.track.clips]..removeAt(p.index);
    if (p.track.kind == TrackKind.audio && clips.isEmpty) {
      return copyWith(
        audioTracks: [
          for (final t in audioTracks)
            if (t.id != p.track.id) t,
        ],
      );
    }
    return _withTrack(p.track.withClips(clips));
  }

  /// Moves the start of a clip by [deltaUs] of timeline time.
  ///
  /// A positive value cuts away the beginning; a negative value brings back
  /// footage that was trimmed earlier. The result is limited by the original
  /// file's length, a one-frame minimum, and (on audio tracks) the clip in
  /// front.
  Project trimStart(int clipId, int deltaUs) {
    final p = placementOf(clipId);
    if (p == null) return this;
    final clip = p.clip;
    var minDelta = -(clip.sourceInUs / clip.speed).floor();
    if (p.track.kind == TrackKind.audio) {
      final previousEnd = p.index > 0 ? p.track.clips[p.index - 1].endUs : 0;
      minDelta = math.max(minDelta, previousEnd - p.startUs);
    }
    final maxDelta = clip.durationUs - minClipUs;
    final delta = deltaUs
        .clamp(math.min(minDelta, 0), math.max(maxDelta, 0))
        .toInt();
    if (delta == 0) return this;
    final trimmed = clip.copyWith(
      sourceInUs: (clip.sourceInUs + (delta * clip.speed).round()).clamp(
        0,
        clip.sourceOutUs - 1,
      ),
      startUs: p.startUs + delta,
    );
    final clips = [...p.track.clips]..[p.index] = trimmed;
    return _withTrack(p.track.withClips(clips));
  }

  /// Moves the end of a clip by [deltaUs] of timeline time.
  ///
  /// A negative value cuts away the ending; a positive value brings back
  /// footage that was trimmed earlier.
  Project trimEnd(int clipId, int deltaUs) {
    final p = placementOf(clipId);
    if (p == null) return this;
    final clip = p.clip;
    var maxDelta = ((clip.sourceDurationUs - clip.sourceOutUs) / clip.speed)
        .floor();
    if (p.track.kind == TrackKind.audio && p.index < p.track.clips.length - 1) {
      maxDelta = math.min(
        maxDelta,
        p.track.clips[p.index + 1].startUs - p.endUs,
      );
    }
    final minDelta = -(clip.durationUs - minClipUs);
    final delta = deltaUs
        .clamp(math.min(minDelta, 0), math.max(maxDelta, 0))
        .toInt();
    if (delta == 0) return this;
    final trimmed = clip.copyWith(
      sourceOutUs: (clip.sourceOutUs + (delta * clip.speed).round()).clamp(
        clip.sourceInUs + 1,
        clip.sourceDurationUs,
      ),
    );
    final clips = [...p.track.clips]..[p.index] = trimmed;
    return _withTrack(p.track.withClips(clips));
  }

  // ---------------------------------------------------------------------------
  // Saving and loading
  // ---------------------------------------------------------------------------

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'id': id,
    'name': name,
    'frameRate': frameRate,
    'canvas': canvas.toJson(),
    'nextId': nextId,
    'mainTrack': mainTrack.toJson(),
    'audioTracks': [for (final t in audioTracks) t.toJson()],
  };

  factory Project.fromJson(Map<String, Object?> json) {
    final version = (json['formatVersion'] as num?)?.toInt() ?? 1;
    if (version > formatVersion) {
      throw FormatException(
        'This project was saved by a newer version of the app '
        '(format $version). Please update the app to open it.',
      );
    }
    return Project(
      id: json['id'] as String,
      name: json['name'] as String,
      frameRate: (json['frameRate'] as num).toDouble(),
      canvas: CanvasRatio.fromJson(
        (json['canvas'] as Map).cast<String, Object?>(),
      ),
      nextId: (json['nextId'] as num).toInt(),
      mainTrack: Track.fromJson(
        (json['mainTrack'] as Map).cast<String, Object?>(),
      ),
      audioTracks: List.unmodifiable([
        for (final t in json['audioTracks'] as List? ?? const [])
          Track.fromJson((t as Map).cast<String, Object?>()),
      ]),
    );
  }
}
