import 'dart:convert';
import 'dart:math' as math;

import 'captions.dart';
import 'clip.dart';
import 'timecode.dart';

export 'captions.dart';
export 'clip.dart';
export 'file_naming.dart';
export 'layer_anchors.dart';

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

  /// The shape of a [width] × [height] picture: a standard shape when it is
  /// within half a percent of one, otherwise a custom one.
  factory CanvasRatio.near(double width, double height) {
    if (width <= 0 || height <= 0) return landscape16x9;
    final v = width / height;
    for (final preset in presets) {
      if ((preset.value / v - 1).abs() < 0.005) return preset;
    }
    // Whole even pixel sizes, reduced (e.g. 2160 × 1620 → 4:3).
    int even(double x) => math.max(2, (x / 2).round() * 2);
    return CanvasRatio.custom(even(width), even(height));
  }

  Map<String, Object?> toJson() => {'width': width, 'height': height};

  factory CanvasRatio.fromJson(Map<String, Object?> json) => CanvasRatio.custom(
    (json['width'] as num).toInt(),
    (json['height'] as num).toInt(),
  );

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
}

/// What fills the canvas where the video doesn't cover it.
class BackgroundFill {
  const BackgroundFill.color(this.colorValue) : blur = false;
  const BackgroundFill.blur() : blur = true, colorValue = 0xFF000000;

  static const black = BackgroundFill.color(0xFF000000);

  /// A blurred, enlarged copy of the video itself.
  final bool blur;

  /// Solid color (ARGB), used when [blur] is false.
  final int colorValue;

  bool get isPlainBlack => !blur && (colorValue & 0xFFFFFF) == 0;

  @override
  bool operator ==(Object other) =>
      other is BackgroundFill &&
      other.blur == blur &&
      (blur || other.colorValue == colorValue);

  @override
  int get hashCode => blur ? 1 : colorValue;

  Map<String, Object?> toJson() =>
      blur ? {'blur': true} : {'color': colorValue};

  factory BackgroundFill.fromJson(Object? json) {
    if (json is! Map) return black;
    if (json['blur'] == true) return const BackgroundFill.blur();
    return BackgroundFill.color((json['color'] as num?)?.toInt() ?? 0xFF000000);
  }
}

/// What a track holds.
enum TrackKind {
  /// The main video track. Clips sit end-to-end with no gaps, like YouCut.
  main,

  /// An audio track. Clips can be placed anywhere, with gaps between them.
  audio,

  /// A text track: titles and captions, placed freely like audio.
  text,

  /// Picture in picture: videos shown on top of the main video, placed
  /// freely in time like audio.
  overlay,
}

class Track {
  const Track({
    required this.id,
    required this.kind,
    this.clips = const [],
    this.captions = false,
  });

  final int id;
  final TrackKind kind;
  final List<Clip> clips;

  /// A text row made by Auto captions (made again when captions are redone).
  final bool captions;

  Track withClips(List<Clip> clips) => Track(
    id: id,
    kind: kind,
    clips: List.unmodifiable(clips),
    captions: captions,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    if (captions) 'captions': true,
    'clips': [for (final c in clips) c.toJson()],
  };

  factory Track.fromJson(Map<String, Object?> json) => Track(
    id: (json['id'] as num).toInt(),
    kind: TrackKind.values.byName(json['kind'] as String),
    captions: json['captions'] as bool? ?? false,
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
    this.background = BackgroundFill.black,
    this.textTracks = const [],
    this.overlayTracks = const [],
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

  /// What fills the canvas around (and behind) the video.
  final BackgroundFill background;

  /// Text overlays. Later tracks draw on top of earlier ones.
  final List<Track> textTracks;

  /// Picture-in-picture videos. Later tracks draw on top of earlier ones
  /// (and text draws on top of all of them).
  final List<Track> overlayTracks;

  List<Track> get tracks => [
    mainTrack,
    ...overlayTracks,
    ...audioTracks,
    ...textTracks,
  ];

  /// Picture-in-picture clips showing at [timeUs], bottom layer first.
  List<ClipPlacement> overlaysAt(int timeUs) => [
    for (final t in overlayTracks)
      for (final p in placementsOn(t))
        if (p.contains(timeUs)) p,
  ];

  /// Adds a picture-in-picture clip at its [Clip.startUs] (it gets a
  /// default position if it has none), on the first overlay track with room.
  Project addOverlay(Clip clip) {
    final placed = clip.copyWith(
      id: nextId,
      pip: clip.pip ?? const PipLayout(),
    );
    return copyWith(nextId: nextId + 1)._placeOnFreeTrack(placed);
  }

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
      // A transition makes the next clip start that much earlier.
      if (track.kind == TrackKind.main) cursor -= transitionUsAfter(i);
    }
    return result;
  }

  /// How long the transition after main-track clip [index] really lasts: at
  /// most half of either neighbouring clip, rounded to whole frames (0 if
  /// there's no transition or no next clip).
  int transitionUsAfter(int index) {
    final clips = mainTrack.clips;
    if (index < 0 || index >= clips.length - 1) return 0;
    final t = clips[index].transition;
    if (t == null) return 0;
    final a = clips[index].durationUs, b = clips[index + 1].durationUs;
    final limit = math.min(t.durationUs, math.min(a, b) ~/ 2);
    final frames = (limit * frameRate / usPerSecond).floor();
    return frames <= 0 ? 0 : frameStartUs(frames, frameRate);
  }

  /// The transition playing at [timeUs], if any: which clip it follows,
  /// when it starts, and how long it lasts.
  ({int index, int startUs, int durationUs, TransitionKind kind})? transitionAt(
    int timeUs,
  ) {
    final ps = placementsOn(mainTrack);
    for (var i = 0; i < ps.length - 1; i++) {
      final d = transitionUsAfter(i);
      if (d == 0) continue;
      final start = ps[i + 1].startUs;
      if (timeUs >= start && timeUs < start + d) {
        return (
          index: i,
          startUs: start,
          durationUs: d,
          kind: ps[i].clip.transition!.kind,
        );
      }
    }
    return null;
  }

  /// A tiny project holding just the transition after main clip [index]
  /// with a little of each clip around it: the last 2×d of the first clip
  /// and the first 2×d of the next, so the transition itself is the part
  /// from d to 2×d. Used to pre-render transitions for the preview.
  Project? transitionPreviewProject(int index) {
    final d = transitionUsAfter(index);
    if (d <= 0) return null;
    final a = mainTrack.clips[index], b = mainTrack.clips[index + 1];
    final a2 = a
        .trimmedBy(headUs: a.durationUs - 2 * d)
        .copyWith(transition: a.transition!.copyWith(durationUs: d), id: 1);
    final b2 = b
        .trimmedBy(tailUs: b.durationUs - 2 * d)
        .copyWith(clearTransition: true, id: 2);
    return Project(
      id: '$id-transition-$index',
      name: name,
      frameRate: frameRate,
      canvas: canvas,
      background: background,
      mainTrack: Track(
        id: 3,
        kind: TrackKind.main,
        clips: List.unmodifiable([a2, b2]),
      ),
      nextId: 4,
    );
  }

  /// A small project holding just main clip [index] with its changes, to
  /// make a ready-to-play preview copy of when it has a changed speed or is
  /// cropped, turned or mirrored: the phone's simple player then plays it
  /// with no hitch at the cuts (otherwise the whole preview needs the
  /// heavier effects player). Null for clips without those changes. Sound
  /// levels and fades stay with the preview's mixer, so the copy has them
  /// neutral.
  Project? speedPreviewProject(int index) {
    final c = mainTrack.clips[index];
    final changed =
        (c.speed - 1).abs() >= 0.0001 ||
        c.rotation % 4 != 0 ||
        c.flipH ||
        c.flipV ||
        !c.crop.isFull;
    if (!c.isMedia || !changed) return null;
    final solo = c.copyWith(
      id: 1,
      startUs: 0,
      clearTransition: true,
      // The filter goes on top while previewing (changeable live), so
      // changing it doesn't make the copy out of date.
      clearGrade: true,
      volume: 1,
      fadeInUs: 0,
      fadeOutUs: 0,
    );
    return Project(
      id: '$id-speed-$index',
      name: name,
      frameRate: frameRate,
      canvas: canvas,
      background: background,
      mainTrack: Track(
        id: 2,
        kind: TrackKind.main,
        clips: List.unmodifiable([solo]),
      ),
      nextId: 3,
    );
  }

  /// Identifies a [speedPreviewProject] copy ('' for clips without one).
  String speedKey(int index) {
    final mini = speedPreviewProject(index);
    if (mini == null) return '';
    final j = mini.toJson()
      ..remove('id')
      ..remove('name');
    return 's${jsonEncode(j).hashCode.toUnsigned(32).toRadixString(16)}';
  }

  /// Identifies a transition's look (its clips, settings and the canvas), so
  /// a pre-rendered copy is reused only while nothing about it changed.
  String transitionKey(int index) {
    final mini = transitionPreviewProject(index);
    if (mini == null) return '';
    final j = mini.toJson()
      ..remove('id')
      ..remove('name');
    return jsonEncode(j).hashCode.toUnsigned(32).toRadixString(16);
  }

  /// Sets (or removes, with null) the transition after main clip [index].
  Project setTransition(int index, TransitionSpec? spec) {
    if (index < 0 || index >= mainTrack.clips.length - 1) return this;
    final clip = mainTrack.clips[index];
    if (clip.transition == spec) return this;
    final updated = spec == null
        ? clip.copyWith(clearTransition: true)
        : clip.copyWith(transition: spec);
    final clips = [...mainTrack.clips]..[index] = updated;
    return copyWith(mainTrack: mainTrack.withClips(clips));
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
    // During a transition two clips overlap; the incoming one counts.
    for (final p in placementsOn(mainTrack).reversed) {
      if (p.contains(timeUs)) return p;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------------

  /// A copy of the whole project under a new [newId], called
  /// "(its name) (copy)" unless [name] is given.
  Project duplicated(String newId, {String? name}) => Project.fromJson({
    ...toJson(),
    'id': newId,
    'name': name ?? '${this.name} (copy)',
  });

  Project copyWith({
    String? name,
    double? frameRate,
    CanvasRatio? canvas,
    Track? mainTrack,
    List<Track>? audioTracks,
    int? nextId,
    BackgroundFill? background,
    List<Track>? textTracks,
    List<Track>? overlayTracks,
  }) => Project(
    id: id,
    name: name ?? this.name,
    frameRate: frameRate ?? this.frameRate,
    canvas: canvas ?? this.canvas,
    mainTrack: mainTrack ?? this.mainTrack,
    audioTracks: audioTracks ?? this.audioTracks,
    nextId: nextId ?? this.nextId,
    background: background ?? this.background,
    textTracks: textTracks ?? this.textTracks,
    overlayTracks: overlayTracks ?? this.overlayTracks,
  );

  /// Changes the frame's shape. Clips set to fill the frame are cut again
  /// to the new shape.
  Project withCanvas(CanvasRatio canvas) {
    if (this.canvas.sameShapeAs(canvas)) return this;
    return copyWith(
      canvas: canvas,
      mainTrack: mainTrack.withClips([
        for (final c in mainTrack.clips) c.fills ? c.filled(canvas.value) : c,
      ]),
    );
  }

  /// The frame shape that matches [clip]'s picture exactly (after its
  /// rotation and crop).
  static CanvasRatio shapeOf(Clip clip) {
    final d = clip.displaySize;
    return CanvasRatio.near(d.width, d.height);
  }

  Project renamed(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty || trimmed == this.name
        ? this
        : copyWith(name: trimmed);
  }

  Project _withTrack(Track track) {
    if (track.id == mainTrack.id) return copyWith(mainTrack: track);
    if (track.kind == TrackKind.text) {
      return copyWith(
        textTracks: [for (final t in textTracks) t.id == track.id ? track : t],
      );
    }
    if (track.kind == TrackKind.overlay) {
      return copyWith(
        overlayTracks: [
          for (final t in overlayTracks) t.id == track.id ? track : t,
        ],
      );
    }
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

  /// Adds imported videos to the main track, starting at clip position
  /// [index] (default: the end).
  ///
  /// The first video added to an empty project sets the project's frame rate
  /// and canvas shape, so a 4K 60 fps phone video "just works".
  Project insertMedia(List<Clip> clips, {int? index}) {
    if (clips.isEmpty) return this;
    var project = this;
    if (mainTrack.clips.isEmpty) {
      final info = clips.first.media;
      if (info != null && info.width > 0 && info.height > 0) {
        project = project.copyWith(
          frameRate: standardFrameRate(info.frameRate),
          canvas: CanvasRatio.custom(info.width, info.height),
        );
      }
    }
    var id = project.nextId;
    final placed = [for (final c in clips) c.copyWith(id: id++)];
    final at = (index ?? mainTrack.clips.length).clamp(
      0,
      mainTrack.clips.length,
    );
    final list = [...mainTrack.clips]..insertAll(at, placed);
    return project.copyWith(mainTrack: mainTrack.withClips(list), nextId: id);
  }

  /// Where newly imported clips go: after the clip under [timeUs], or at the
  /// end if the playhead is past everything.
  int insertIndexAt(int timeUs) {
    final p = mainClipAt(timeUs);
    if (p == null) return timeUs <= 0 ? 0 : mainTrack.clips.length;
    return p.index + 1;
  }

  /// True if the main track holds real media (not demo placeholders).
  bool get hasMedia => mainTrack.clips.any((c) => c.isMedia);

  /// Adds an audio clip at its [Clip.startUs], on the first audio track with
  /// room for it. A new track is created if none has room.
  Project addAudio(Clip clip) {
    var project = this;
    final placed = clip.copyWith(id: project.nextId);
    project = project.copyWith(nextId: project.nextId + 1);
    return project._placeOnFreeTrack(placed);
  }

  /// Adds a text clip at its [Clip.startUs], on the first text track with
  /// room (a new track is created if needed).
  Project addText(Clip clip) {
    final placed = clip.copyWith(id: nextId);
    return copyWith(nextId: nextId + 1)._placeOnFreeTrack(placed);
  }

  /// All text clips showing at [timeUs], bottom layer first.
  List<ClipPlacement> textsAt(int timeUs) => [
    for (final t in textTracks)
      for (final p in placementsOn(t))
        if (p.contains(timeUs)) p,
  ];

  /// Puts [lines] (caption texts with their timeline times) on the captions
  /// row in [style], replacing earlier captions between [fromUs] and [toUs].
  Project withCaptions(
    List<CaptionLine> lines,
    TextSpec style, {
    required int fromUs,
    required int toUs,
  }) {
    var id = nextId;
    final existing = textTracks.where((t) => t.captions).firstOrNull;
    final kept = [
      for (final c in existing?.clips ?? const <Clip>[])
        if (c.endUs <= fromUs || c.startUs >= toUs) c,
    ];
    final added = [
      for (final l in lines)
        Clip.text(
          style.copyWith(text: l.text),
          startUs: l.startUs,
          durationUs: l.endUs - l.startUs,
        ).copyWith(id: id++),
    ];
    // Never on top of each other on the row.
    final clips = <Clip>[];
    for (final c in [
      ...kept,
      ...added,
    ]..sort((a, b) => a.startUs.compareTo(b.startUs))) {
      if (clips.isNotEmpty && c.startUs < clips.last.endUs) continue;
      clips.add(c);
    }
    if (existing != null) {
      return _withTrack(existing.withClips(clips)).copyWith(nextId: id);
    }
    final track = Track(
      id: id++,
      kind: TrackKind.text,
      clips: List.unmodifiable(clips),
      captions: true,
    );
    return copyWith(textTracks: [...textTracks, track], nextId: id);
  }

  /// Puts [clip] on the first row of its kind with room (a new row if none).
  Project placeOnFreeTrack(Clip clip) => _placeOnFreeTrack(clip);

  Project _placeOnFreeTrack(Clip clip) {
    final kind = clip.kind == ClipKind.text
        ? TrackKind.text
        : (clip.pip != null ? TrackKind.overlay : TrackKind.audio);
    final existing = switch (kind) {
      TrackKind.text => textTracks,
      TrackKind.overlay => overlayTracks,
      _ => audioTracks,
    };
    for (final track in existing) {
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
      kind: kind,
      clips: List.unmodifiable([clip]),
    );
    return switch (kind) {
      TrackKind.text => copyWith(
        textTracks: [...textTracks, track],
        nextId: nextId + 1,
      ),
      TrackKind.overlay => copyWith(
        overlayTracks: [...overlayTracks, track],
        nextId: nextId + 1,
      ),
      _ => copyWith(audioTracks: [...audioTracks, track], nextId: nextId + 1),
    };
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
    final cutSourceUs = clip.sourceTimeAt(timeUs - p.startUs);
    // A backwards clip shows the end of its range first.
    final left = clip.reversed
        ? clip.copyWith(sourceInUs: cutSourceUs, clearTransition: true)
        : clip.copyWith(sourceOutUs: cutSourceUs, clearTransition: true);
    final right = clip.reversed
        ? clip.copyWith(id: nextId, sourceOutUs: cutSourceUs, startUs: timeUs)
        : clip.copyWith(id: nextId, sourceInUs: cutSourceUs, startUs: timeUs);
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
    return copyWith(nextId: nextId + 1)._placeOnFreeTrack(copy);
  }

  /// Removes a clip. Empty audio tracks are removed too.
  Project deleteClip(int clipId) {
    final p = placementOf(clipId);
    if (p == null) return this;
    if (p.track.kind == TrackKind.main) {
      // Text and picture overlays that start on this clip's frames go with
      // it (they stick to their frames). Sound stays.
      final gone = [
        for (final t in [...overlayTracks, ...textTracks])
          for (final c in t.clips)
            if (c.anchor?.clipId == clipId) c.id,
      ];
      if (gone.isNotEmpty) {
        var q = this;
        for (final id in gone) {
          q = q.deleteClip(id);
        }
        return q.deleteClip(clipId);
      }
    }
    final clips = [...p.track.clips]..removeAt(p.index);
    if (p.track.kind == TrackKind.audio && clips.isEmpty) {
      return copyWith(
        audioTracks: [
          for (final t in audioTracks)
            if (t.id != p.track.id) t,
        ],
      );
    }
    if (p.track.kind == TrackKind.overlay && clips.isEmpty) {
      return copyWith(
        overlayTracks: [
          for (final t in overlayTracks)
            if (t.id != p.track.id) t,
        ],
      );
    }
    if (p.track.kind == TrackKind.text && clips.isEmpty) {
      return copyWith(
        textTracks: [
          for (final t in textTracks)
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
    // The clip's first moment on screen is the start of the used part, or
    // its end when the clip plays backwards.
    final room = clip.reversed
        ? clip.sourceDurationUs - clip.sourceOutUs
        : clip.sourceInUs;
    var minDelta = -(room / clip.speed).floor();
    if (p.track.kind != TrackKind.main) {
      final previousEnd = p.index > 0 ? p.track.clips[p.index - 1].endUs : 0;
      minDelta = math.max(minDelta, previousEnd - p.startUs);
    }
    final maxDelta = clip.durationUs - minClipUs;
    final delta = deltaUs
        .clamp(math.min(minDelta, 0), math.max(maxDelta, 0))
        .toInt();
    if (delta == 0) return this;
    final sourceDelta = (delta * clip.speed).round();
    final trimmed = clip.reversed
        ? clip.copyWith(
            sourceOutUs: (clip.sourceOutUs - sourceDelta).clamp(
              clip.sourceInUs + 1,
              clip.sourceDurationUs,
            ),
            startUs: p.startUs + delta,
          )
        : clip.copyWith(
            sourceInUs: (clip.sourceInUs + sourceDelta).clamp(
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
    final room = clip.reversed
        ? clip.sourceInUs
        : clip.sourceDurationUs - clip.sourceOutUs;
    var maxDelta = (room / clip.speed).floor();
    if (p.track.kind != TrackKind.main && p.index < p.track.clips.length - 1) {
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
    final sourceDelta = (delta * clip.speed).round();
    final trimmed = clip.reversed
        ? clip.copyWith(
            sourceInUs: (clip.sourceInUs - sourceDelta).clamp(
              0,
              clip.sourceOutUs - 1,
            ),
          )
        : clip.copyWith(
            sourceOutUs: (clip.sourceOutUs + sourceDelta).clamp(
              clip.sourceInUs + 1,
              clip.sourceDurationUs,
            ),
          );
    final clips = [...p.track.clips]..[p.index] = trimmed;
    return _withTrack(p.track.withClips(clips));
  }

  /// Changes one clip. [change] returns the new version of the clip.
  /// Every media file the project uses (video, sound and picture-in-picture
  /// clips), with the names of the clips that use it.
  Map<String, List<String>> get mediaSources {
    final out = <String, List<String>>{};
    for (final t in [mainTrack, ...overlayTracks, ...audioTracks]) {
      for (final c in t.clips) {
        final s = c.sourcePath;
        if (s == null || !c.isMedia) continue;
        (out[s] ??= []).add(c.name);
      }
    }
    return out;
  }

  /// A file was found somewhere else: every clip that used [from] now uses
  /// [to] (same file, new place).
  Project relinkSource(String from, String to) {
    if (from == to) return this;
    Track fix(Track t) {
      if (!t.clips.any((c) => c.sourcePath == from)) return t;
      return t.withClips([
        for (final c in t.clips)
          c.sourcePath == from ? c.copyWith(sourcePath: to) : c,
      ]);
    }

    return copyWith(
      mainTrack: fix(mainTrack),
      overlayTracks: [for (final t in overlayTracks) fix(t)],
      audioTracks: [for (final t in audioTracks) fix(t)],
    );
  }

  Project updateClip(int clipId, Clip Function(Clip clip) change) {
    final p = placementOf(clipId);
    if (p == null) return this;
    final updated = change(p.clip);
    if (identical(updated, p.clip)) return this;
    final clips = [...p.track.clips]..[p.index] = updated;
    return _withTrack(p.track.withClips(clips));
  }

  /// Sets a clip's speed (0.25× to 4×). Its length on the timeline changes
  /// accordingly; on audio tracks it can't grow into the next clip.
  Project setSpeed(int clipId, double speed) {
    final p = placementOf(clipId);
    if (p == null) return this;
    var s = speed.clamp(Clip.minSpeed, Clip.maxSpeed);
    if ((s - p.clip.speed).abs() < 0.0001) return this;
    if (p.track.kind != TrackKind.main && p.index < p.track.clips.length - 1) {
      final room = p.track.clips[p.index + 1].startUs - p.startUs;
      s = math.max(s, p.clip.sourceLengthUs / math.max(1, room));
    }
    return updateClip(clipId, (c) => c.copyWith(speed: s));
  }

  /// Puts the main-track clips in the order given by [clipIds] (which must
  /// list every main-track clip once).
  Project reorderMain(List<int> clipIds) {
    final byId = {for (final c in mainTrack.clips) c.id: c};
    if (clipIds.length != byId.length || !clipIds.every(byId.containsKey)) {
      return this;
    }
    final same = [for (final c in mainTrack.clips) c.id];
    if (listEqualsInt(same, clipIds)) return this;
    return copyWith(
      mainTrack: mainTrack.withClips([for (final id in clipIds) byId[id]!]),
    );
  }

  static bool listEqualsInt(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Moves an audio clip along its track. It stops at neighbouring clips
  /// and at the start of the timeline.
  Project moveAudioClip(int clipId, int newStartUs) {
    final p = placementOf(clipId);
    if (p == null || p.track.kind == TrackKind.main) return this;
    final prevEnd = p.index > 0 ? p.track.clips[p.index - 1].endUs : 0;
    final nextStart = p.index < p.track.clips.length - 1
        ? p.track.clips[p.index + 1].startUs
        : null;
    var start = math.max(prevEnd, newStartUs);
    if (nextStart != null) {
      start = math.min(start, nextStart - p.clip.durationUs);
    }
    if (start < prevEnd || start == p.clip.startUs) return this;
    return updateClip(clipId, (c) => c.copyWith(startUs: start));
  }

  /// Moves a sound, text or picture-in-picture clip to start near
  /// [newStartUs] on row [trackId] (its own row if null; a new row of its
  /// kind if [newTrack]). It lands in the free spot nearest to where it was
  /// dropped, so it can pass other clips. Rows it leaves empty stay until
  /// [withoutEmptyLayerTracks] (so rows don't jump about during a drag).
  Project moveLayerClip(
    int clipId,
    int newStartUs, {
    int? trackId,
    bool newTrack = false,
  }) {
    final p = placementOf(clipId);
    if (p == null || p.track.kind == TrackKind.main) return this;
    final kind = p.track.kind;
    final rows = switch (kind) {
      TrackKind.text => textTracks,
      TrackKind.overlay => overlayTracks,
      _ => audioTracks,
    };
    final source = p.track.withClips([
      for (final c in p.track.clips)
        if (c.id != clipId) c,
    ]);
    var q = _withTrack(source);
    final want = math.max(0, newStartUs);
    if (newTrack) {
      final track = Track(
        id: q.nextId,
        kind: kind,
        clips: List.unmodifiable([p.clip.copyWith(startUs: want)]),
      );
      return switch (kind) {
        TrackKind.text => q.copyWith(
          textTracks: [...q.textTracks, track],
          nextId: q.nextId + 1,
        ),
        TrackKind.overlay => q.copyWith(
          overlayTracks: [...q.overlayTracks, track],
          nextId: q.nextId + 1,
        ),
        _ => q.copyWith(
          audioTracks: [...q.audioTracks, track],
          nextId: q.nextId + 1,
        ),
      };
    }
    final targetId = rows.any((t) => t.id == trackId) ? trackId! : source.id;
    final target = targetId == source.id
        ? source
        : rows.firstWhere((t) => t.id == targetId);
    final start = freeStartNear(target.clips, want, p.clip.durationUs);
    final clips = [...target.clips, p.clip.copyWith(startUs: start)]
      ..sort((a, b) => a.startUs.compareTo(b.startUs));
    q = q._withTrack(target.withClips(clips));
    return q;
  }

  /// Removes sound, text and picture-in-picture rows that have no clips.
  Project withoutEmptyLayerTracks() {
    bool used(Track t) => t.clips.isNotEmpty;
    if (overlayTracks.every(used) &&
        audioTracks.every(used) &&
        textTracks.every(used)) {
      return this;
    }
    return copyWith(
      overlayTracks: [...overlayTracks.where(used)],
      audioTracks: [...audioTracks.where(used)],
      textTracks: [...textTracks.where(used)],
    );
  }

  /// Copies a video clip's sound onto an audio track (same moment, same
  /// part of the file) and mutes the video, so the sound can be edited on
  /// its own.
  Project extractAudio(int clipId) {
    final p = placementOf(clipId);
    if (p == null || p.track.kind != TrackKind.main || !p.clip.isMedia) {
      return this;
    }
    if (!(p.clip.media?.hasAudio ?? false)) return this;
    final audio = p.clip.copyWith(
      kind: ClipKind.audio,
      startUs: p.startUs,
      name: '${p.clip.name} (sound)',
      rotation: 0,
      flipH: false,
      flipV: false,
      crop: CropRect.full,
      opacity: 1,
    );
    return updateClip(clipId, (c) => c.copyWith(volume: 0)).addAudio(audio);
  }

  Project withBackground(BackgroundFill background) =>
      background == this.background ? this : copyWith(background: background);

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
    'background': background.toJson(),
    'textTracks': [for (final t in textTracks) t.toJson()],
    if (overlayTracks.isNotEmpty)
      'overlayTracks': [for (final t in overlayTracks) t.toJson()],
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
      background: BackgroundFill.fromJson(json['background']),
      textTracks: List.unmodifiable([
        for (final t in json['textTracks'] as List? ?? const [])
          Track.fromJson((t as Map).cast<String, Object?>()),
      ]),
      audioTracks: List.unmodifiable([
        for (final t in json['audioTracks'] as List? ?? const [])
          Track.fromJson((t as Map).cast<String, Object?>()),
      ]),
      overlayTracks: List.unmodifiable([
        for (final t in json['overlayTracks'] as List? ?? const [])
          Track.fromJson((t as Map).cast<String, Object?>()),
      ]),
    );
  }
}

/// Where the playhead goes when clip [deletedId] is removed ([before] →
/// [after]): on the same video frame it was showing (later main clips move
/// up, so the time changes), or, if that frame was in the deleted clip, at
/// the start of the clip that followed it. Deleting from other tracks moves
/// nothing, so the playhead stays put.
int playheadAfterDelete(
  Project before,
  Project after,
  int deletedId,
  int playheadUs,
) {
  final del = before.placementOf(deletedId);
  if (del == null || del.track.kind != TrackKind.main) {
    return playheadUs.clamp(0, after.durationUs);
  }
  final at = before.mainClipAt(playheadUs);
  if (at == null) return after.durationUs; // was at the very end
  if (at.clip.id == deletedId) {
    final clips = before.mainTrack.clips;
    final i = del.index + 1;
    if (i >= clips.length) return after.durationUs;
    return after.placementOf(clips[i].id)?.startUs ?? 0;
  }
  final now = after.placementOf(at.clip.id);
  if (now == null) return playheadUs.clamp(0, after.durationUs);
  return (now.startUs + playheadUs - at.startUs).clamp(0, after.durationUs);
}

/// The start nearest to [wantUs] where a clip [durationUs] long fits
/// between [others] (sorted by start) without overlapping any.
int freeStartNear(List<Clip> others, int wantUs, int durationUs) {
  final sorted = [...others]..sort((a, b) => a.startUs.compareTo(b.startUs));
  var best = wantUs;
  int? bestGap;
  var gapStart = 0;
  for (var i = 0; i <= sorted.length; i++) {
    final gapEnd = i < sorted.length ? sorted[i].startUs : null;
    final latest = gapEnd == null ? null : gapEnd - durationUs;
    if (latest == null || latest >= gapStart) {
      var s = wantUs < gapStart ? gapStart : wantUs;
      if (latest != null && s > latest) s = latest;
      final off = (s - wantUs).abs();
      if (bestGap == null || off < bestGap) {
        bestGap = off;
        best = s;
      }
    }
    if (i < sorted.length) {
      gapStart = math.max(gapStart, sorted[i].endUs);
    }
  }
  return best;
}
