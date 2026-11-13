import 'dart:math' as math;

import 'audio_fx.dart';
import 'color_grade.dart';
import 'media_info.dart';
import 'text_spec.dart';

export 'audio_fx.dart';
export 'color_grade.dart';
export 'media_info.dart';
export 'text_spec.dart';

/// What a clip holds.
enum ClipKind { video, audio, text }

/// Part of the picture to keep, as fractions of the (rotated) frame:
/// 0,0 is the top-left corner and 1,1 the bottom-right.
class CropRect {
  const CropRect(this.left, this.top, this.right, this.bottom);

  static const full = CropRect(0, 0, 1, 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  bool get isFull =>
      left <= 0.0005 && top <= 0.0005 && right >= 0.9995 && bottom >= 0.9995;

  /// Keeps the rectangle inside the frame and at least 5 % in each direction.
  CropRect normalized() {
    const minSize = 0.05;
    final l = left.clamp(0.0, 1.0 - minSize);
    final t = top.clamp(0.0, 1.0 - minSize);
    final r = right.clamp(l + minSize, 1.0);
    final b = bottom.clamp(t + minSize, 1.0);
    return CropRect(l, t, r, b);
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  List<double> toJson() => [left, top, right, bottom];

  factory CropRect.fromJson(Object? json) {
    if (json is! List || json.length != 4) return full;
    final v = [for (final x in json) (x as num).toDouble()];
    return CropRect(v[0], v[1], v[2], v[3]).normalized();
  }
}

/// A reversed copy of part of a source file, made when "Reverse" is turned on
/// (a video can't be decoded backwards on the fly, so a copy is prepared).
class ReverseProxy {
  const ReverseProxy(this.path, this.sourceInUs, this.sourceOutUs);

  final String path;

  /// The part of the original that the copy covers.
  final int sourceInUs;
  final int sourceOutUs;

  bool covers(int inUs, int outUs) =>
      inUs >= sourceInUs - 1000 && outUs <= sourceOutUs + 1000;

  /// Where original moment [sourceUs] is found inside the reversed copy.
  int proxyTimeOf(int sourceUs) => sourceOutUs - sourceUs;

  Map<String, Object?> toJson() => {
    'path': path,
    'inUs': sourceInUs,
    'outUs': sourceOutUs,
  };

  static ReverseProxy? fromJson(Object? json) {
    if (json is! Map) return null;
    return ReverseProxy(
      json['path'] as String,
      (json['inUs'] as num).toInt(),
      (json['outUs'] as num).toInt(),
    );
  }
}

/// How one clip changes into the next.
/// The groups the transition picker shows as tabs.
enum TransitionGroup {
  basic('Basic'),
  slide('Slide'),
  wipe('Wipe'),
  shape('Shape');

  const TransitionGroup(this.label);
  final String label;
}

/// How one clip changes into the next.
///
/// [ffmpegName] is FFmpeg's name for it (the xfade filter, Windows); [code]
/// picks the same picture on Android (TransitionBlender.kt draws it with the
/// same maths). "Through black/white" are done differently on both: each
/// clip fades to the colour and back, so the middle is a solid colour.
enum TransitionKind {
  fade('Crossfade', 'fade', 1, TransitionGroup.basic),
  fadeBlack('Through black', 'fadeblack', 0, TransitionGroup.basic),
  fadeWhite('Through white', 'fadewhite', 0, TransitionGroup.basic),
  dissolve('Dissolve', 'dissolve', 2, TransitionGroup.basic),
  pixelize('Pixelate', 'pixelize', 3, TransitionGroup.basic),
  zoom('Zoom in', 'zoomin', 4, TransitionGroup.basic),

  slideLeft('Slide left', 'slideleft', 10, TransitionGroup.slide),
  slideRight('Slide right', 'slideright', 11, TransitionGroup.slide),
  slideUp('Slide up', 'slideup', 12, TransitionGroup.slide),
  slideDown('Slide down', 'slidedown', 13, TransitionGroup.slide),
  coverLeft('Cover left', 'coverleft', 14, TransitionGroup.slide),
  coverRight('Cover right', 'coverright', 15, TransitionGroup.slide),
  coverUp('Cover up', 'coverup', 16, TransitionGroup.slide),
  coverDown('Cover down', 'coverdown', 17, TransitionGroup.slide),
  revealLeft('Reveal left', 'revealleft', 18, TransitionGroup.slide),
  revealRight('Reveal right', 'revealright', 19, TransitionGroup.slide),
  revealUp('Reveal up', 'revealup', 20, TransitionGroup.slide),
  revealDown('Reveal down', 'revealdown', 21, TransitionGroup.slide),

  wipeLeft('Wipe left', 'wipeleft', 30, TransitionGroup.wipe),
  wipeRight('Wipe right', 'wiperight', 31, TransitionGroup.wipe),
  wipeUp('Wipe up', 'wipeup', 32, TransitionGroup.wipe),
  wipeDown('Wipe down', 'wipedown', 33, TransitionGroup.wipe),
  softLeft('Soft wipe left', 'smoothleft', 34, TransitionGroup.wipe),
  softRight('Soft wipe right', 'smoothright', 35, TransitionGroup.wipe),
  softUp('Soft wipe up', 'smoothup', 36, TransitionGroup.wipe),
  softDown('Soft wipe down', 'smoothdown', 37, TransitionGroup.wipe),
  cornerTopLeft('Corner ↖', 'wipetl', 38, TransitionGroup.wipe),
  cornerTopRight('Corner ↗', 'wipetr', 39, TransitionGroup.wipe),
  cornerBottomLeft('Corner ↙', 'wipebl', 40, TransitionGroup.wipe),
  cornerBottomRight('Corner ↘', 'wipebr', 41, TransitionGroup.wipe),
  clock('Clock', 'radial', 42, TransitionGroup.wipe),

  circleOpen('Circle open', 'circleopen', 50, TransitionGroup.shape),
  circleClose('Circle close', 'circleclose', 51, TransitionGroup.shape),
  iris('Iris', 'circlecrop', 52, TransitionGroup.shape),
  box('Box', 'rectcrop', 53, TransitionGroup.shape),
  doorsOpen('Doors open', 'vertopen', 54, TransitionGroup.shape),
  doorsClose('Doors close', 'vertclose', 55, TransitionGroup.shape),
  splitOpen('Split open', 'horzopen', 56, TransitionGroup.shape),
  splitClose('Split close', 'horzclose', 57, TransitionGroup.shape);

  const TransitionKind(this.label, this.ffmpegName, this.code, this.group);
  final String label;

  /// FFmpeg's name for it (the xfade filter).
  final String ffmpegName;

  /// Android's number for it (0: a dip through a colour, not a blend).
  final int code;
  final TransitionGroup group;

  /// Each clip fades to a solid colour and back, instead of the two clips
  /// being mixed.
  bool get isDip => code == 0;

  /// The solid colour a dip passes through (ARGB).
  int get dipColor =>
      this == TransitionKind.fadeWhite ? 0xFFFFFFFF : 0xFF000000;
}

/// A transition into the next clip. Clips overlap by [durationUs] while it
/// plays, so the video gets that much shorter (as in most phone editors).
class TransitionSpec {
  const TransitionSpec(this.kind, {this.durationUs = 500000});

  final TransitionKind kind;
  final int durationUs;

  static const maxUs = 3000000;

  TransitionSpec copyWith({TransitionKind? kind, int? durationUs}) =>
      TransitionSpec(
        kind ?? this.kind,
        durationUs: durationUs ?? this.durationUs,
      );

  @override
  bool operator ==(Object other) =>
      other is TransitionSpec &&
      other.kind == kind &&
      other.durationUs == durationUs;

  @override
  int get hashCode => Object.hash(kind, durationUs);

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'durationUs': durationUs,
  };

  static TransitionSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = TransitionKind.values.asNameMap()[json['kind']];
    if (kind == null) return null;
    return TransitionSpec(
      kind,
      durationUs: (json['durationUs'] as num?)?.toInt() ?? 500000,
    );
  }
}

/// Where a picture-in-picture video sits on the canvas.
class PipLayout {
  const PipLayout({
    this.x = 0.72,
    this.y = 0.3,
    this.size = 0.4,
    this.angle = 0,
  });

  /// Centre of the picture, as fractions of the canvas (0,0 top left).
  final double x;
  final double y;

  /// Width of the picture as a fraction of the canvas width.
  final double size;

  /// Turned clockwise, in degrees.
  final double angle;

  static const minSize = 0.05;
  static const maxSize = 1.5;

  PipLayout copyWith({double? x, double? y, double? size, double? angle}) =>
      PipLayout(
        x: (x ?? this.x).clamp(-0.5, 1.5),
        y: (y ?? this.y).clamp(-0.5, 1.5),
        size: (size ?? this.size).clamp(minSize, maxSize),
        angle: angle ?? this.angle,
      );

  @override
  bool operator ==(Object other) =>
      other is PipLayout &&
      other.x == x &&
      other.y == y &&
      other.size == size &&
      other.angle == angle;

  @override
  int get hashCode => Object.hash(x, y, size, angle);

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'size': size,
    if (angle != 0) 'angle': angle,
  };

  static PipLayout? fromJson(Object? json) {
    if (json is! Map) return null;
    return PipLayout(
      x: (json['x'] as num?)?.toDouble() ?? 0.72,
      y: (json['y'] as num?)?.toDouble() ?? 0.3,
      size: ((json['size'] as num?)?.toDouble() ?? 0.4).clamp(minSize, maxSize),
      angle: (json['angle'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// One piece of media placed on the timeline.
///
/// A clip never changes the original file. It just says "use this part of
/// that file": from [sourceInUs] to [sourceOutUs], played at [speed], with
/// these adjustments.
/// The video frame a clip off the main track starts on: main clip [clipId]
/// at moment [sourceUs] of its file [source].
class ClipAnchor {
  const ClipAnchor(this.clipId, this.source, this.sourceUs);

  final int clipId;
  final String source;
  final int sourceUs;

  @override
  bool operator ==(Object other) =>
      other is ClipAnchor &&
      other.clipId == clipId &&
      other.source == source &&
      other.sourceUs == sourceUs;

  @override
  int get hashCode => Object.hash(clipId, source, sourceUs);

  Map<String, Object?> toJson() => {
    'clip': clipId,
    'source': source,
    'at': sourceUs,
  };

  static ClipAnchor? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['clip'], src = json['source'], at = json['at'];
    if (id is! num || src is! String || at is! num) return null;
    return ClipAnchor(id.toInt(), src, at.toInt());
  }
}

class Clip {
  const Clip({
    required this.id,
    required this.kind,
    required this.name,
    required this.sourceDurationUs,
    required this.sourceInUs,
    required this.sourceOutUs,
    this.sourcePath,
    this.startUs = 0,
    this.speed = 1.0,
    this.colorValue = 0xFF607D8B,
    this.media,
    this.rotation = 0,
    this.flipH = false,
    this.flipV = false,
    this.crop = CropRect.full,
    this.fillFrom,
    this.opacity = 1.0,
    this.reversed = false,
    this.reverseProxy,
    this.volume = 1.0,
    this.fadeInUs = 0,
    this.fadeOutUs = 0,
    this.text,
    this.transition,
    this.pip,
    this.grade,
    this.audioFx,
    this.anchor,
  });

  /// For clips off the main track (sound, text, picture-in-picture): the
  /// video frame they start on, so they move with it when the main video
  /// is edited.
  final ClipAnchor? anchor;

  /// Sound effects: equalizer, pitch, delay, reverb.
  final AudioFx? audioFx;

  /// The sound effects, or null when there are none.
  AudioFx? get activeAudioFx {
    final f = audioFx;
    return f == null || f.isNeutral ? null : f;
  }

  /// Filter: a ready-made look and/or brightness, contrast and so on.
  final ColorGrade? grade;

  /// The filter's combined changes, or null when it changes nothing.
  GradeParams? get gradeParams {
    final g = grade;
    if (g == null || g.isNeutral) return null;
    return g.params;
  }

  /// Set for picture-in-picture clips (on an overlay track): where the
  /// picture sits on top of the main video.
  final PipLayout? pip;

  static const minSpeed = 0.25;

  /// Up to 200 % (doubling the loudness).
  static const maxVolume = 2.0;
  static const maxSpeed = 4.0;

  /// Unique within a project.
  final int id;
  final ClipKind kind;

  /// Display name shown on the timeline.
  final String name;

  /// Where the media lives: a file path on Windows, a `content://` address
  /// on Android. `null` for the colored placeholder clips in the demo.
  final String? sourcePath;

  /// Facts about the source file. `null` for placeholder clips.
  final MediaInfo? media;

  /// True for real media (as opposed to demo placeholders).
  bool get isMedia => sourcePath != null && media != null;

  /// Full length of the original media file.
  final int sourceDurationUs;

  /// Where in the original file this clip starts and ends.
  final int sourceInUs;
  final int sourceOutUs;

  /// Position on the timeline. Only used on free-placement tracks (audio).
  /// Clips on the main video track sit end-to-end automatically.
  final int startUs;

  /// Playback speed: 1.0 is normal, 0.5 is half speed, 2.0 is double.
  final double speed;

  /// Placeholder color (ARGB) used until real thumbnails exist.
  final int colorValue;

  /// Quarter turns clockwise (0–3).
  final int rotation;

  /// Mirrored left↔right / upside down.
  final bool flipH;
  final bool flipV;

  /// Part of the (rotated, mirrored) picture to keep.
  final CropRect crop;

  /// Set while the clip fills the whole frame ("Fill frame"): the crop it
  /// had before, which [crop] trims further to the frame's shape. "Fit
  /// frame" goes back to it.
  final CropRect? fillFrom;

  bool get fills => fillFrom != null;

  /// True when the picture already has the frame's shape (no bars, nothing
  /// cut off).
  bool matchesShape(double canvasAspect) {
    final d = displaySize;
    if (d.width <= 0 || d.height <= 0) return true;
    return ((d.width / d.height) / canvasAspect - 1).abs() < 0.005;
  }

  /// Fills a frame of shape [canvasAspect] (width / height): the middle of
  /// the picture, cut to that shape.
  Clip filled(double canvasAspect) {
    final m = media;
    if (m == null) return this;
    final base = fillFrom ?? crop;
    final w = (rotation.isOdd ? m.height : m.width) * base.width;
    final h = (rotation.isOdd ? m.width : m.height) * base.height;
    if (w <= 0 || h <= 0) return this;
    var r = base;
    if (w / h > canvasAspect) {
      final keep = base.width * (h * canvasAspect / w);
      final l = base.left + (base.width - keep) / 2;
      r = CropRect(l, base.top, l + keep, base.bottom);
    } else {
      final keep = base.height * (w / canvasAspect / h);
      final t = base.top + (base.height - keep) / 2;
      r = CropRect(base.left, t, base.right, t + keep);
    }
    return copyWith(crop: r, fillFrom: base);
  }

  /// Back to showing the whole picture inside the frame.
  Clip fitted() =>
      fillFrom == null ? this : copyWith(crop: fillFrom, clearFill: true);

  /// 1.0 is fully visible; lower lets the background show through.
  final double opacity;

  /// Where in this clip (timeline time from its start) its file's moment
  /// [sourceUs] shows, or null if that moment isn't part of the clip.
  int? offsetOfSource(int sourceUs) {
    if (sourceUs < sourceInUs || sourceUs > sourceOutUs) return null;
    final s = reversed ? sourceOutUs - sourceUs : sourceUs - sourceInUs;
    return (s / speed).round().clamp(0, durationUs);
  }

  /// Text clips can be any length (up to an hour).
  static const textSourceUs = 3600 * 1000000;

  /// A new text clip.
  factory Clip.text(
    TextSpec spec, {
    required int startUs,
    int durationUs = 3000000,
  }) => Clip(
    id: 0,
    kind: ClipKind.text,
    name: spec.text,
    sourceDurationUs: textSourceUs,
    sourceInUs: 0,
    sourceOutUs: durationUs,
    startUs: startUs,
    colorValue: 0xFF7B1FA2,
    text: spec,
  );

  /// Plays backwards.
  final bool reversed;

  /// The prepared backwards copy, once made.
  final ReverseProxy? reverseProxy;

  /// Loudness: 1.0 is as recorded, 0 is silent, 2.0 is twice as loud.
  final double volume;

  /// How long the sound takes to rise from silence at the start / fall to
  /// silence at the end (timeline time).
  final int fadeInUs;
  final int fadeOutUs;

  /// For text clips: what it says and how it looks.
  final TextSpec? text;

  /// Main-track clips: how this clip changes into the next one (null = a
  /// plain cut).
  final TransitionSpec? transition;

  /// Length of the used part of the original file.
  int get sourceLengthUs => sourceOutUs - sourceInUs;

  /// How long the clip lasts on the timeline (after speed is applied).
  int get durationUs => (sourceLengthUs / speed).round();

  int get endUs => startUs + durationUs;

  /// True when any picture adjustment is applied.
  bool get hasLook =>
      rotation != 0 ||
      flipH ||
      flipV ||
      !crop.isFull ||
      opacity < 0.999 ||
      gradeParams != null;

  /// True when the reversed copy is ready for the current in/out points.
  bool get reverseReady =>
      reversed && (reverseProxy?.covers(sourceInUs, sourceOutUs) ?? false);

  /// The picture size after rotation and crop (before fitting into the
  /// canvas).
  ({double width, double height}) get displaySize {
    final m = media;
    if (m == null) return (width: 16, height: 9);
    final w = (rotation.isOdd ? m.height : m.width).toDouble();
    final h = (rotation.isOdd ? m.width : m.height).toDouble();
    return (width: w * crop.width, height: h * crop.height);
  }

  /// Fades can't be longer than the clip together.
  ({int fadeIn, int fadeOut}) get effectiveFades {
    final d = durationUs;
    var fi = fadeInUs.clamp(0, d);
    var fo = fadeOutUs.clamp(0, d);
    if (fi + fo > d) {
      final scale = d / (fi + fo);
      fi = (fi * scale).floor();
      fo = (fo * scale).floor();
    }
    return (fadeIn: fi, fadeOut: fo);
  }

  /// Loudness [offsetUs] into the clip, including fades (0.0–2.0).
  double gainAt(int offsetUs) {
    final f = effectiveFades;
    var g = volume;
    if (f.fadeIn > 0 && offsetUs < f.fadeIn) g *= offsetUs / f.fadeIn;
    final fromEnd = durationUs - offsetUs;
    if (f.fadeOut > 0 && fromEnd < f.fadeOut) g *= fromEnd / f.fadeOut;
    return g.clamp(0.0, maxVolume);
  }

  /// The same clip with [headUs] cut off its start and [tailUs] off its end
  /// (timeline time; speed and reverse are taken into account).
  Clip trimmedBy({int headUs = 0, int tailUs = 0}) {
    final h = (headUs * speed).round(), t = (tailUs * speed).round();
    if (h == 0 && t == 0) return this;
    return reversed
        ? copyWith(sourceOutUs: sourceOutUs - h, sourceInUs: sourceInUs + t)
        : copyWith(sourceInUs: sourceInUs + h, sourceOutUs: sourceOutUs - t);
  }

  /// Which moment of the original file is showing [offsetUs] into the clip
  /// (accounts for speed and reverse).
  int sourceTimeAt(int offsetUs) {
    final s = (offsetUs * speed).round();
    return reversed ? sourceOutUs - s : sourceInUs + s;
  }

  Clip copyWith({
    int? id,
    String? name,
    int? sourceInUs,
    int? sourceOutUs,
    int? startUs,
    double? speed,
    int? colorValue,
    int? rotation,
    bool? flipH,
    bool? flipV,
    CropRect? crop,
    CropRect? fillFrom,
    bool clearFill = false,
    double? opacity,
    bool? reversed,
    ReverseProxy? reverseProxy,
    bool clearReverseProxy = false,
    double? volume,
    int? fadeInUs,
    int? fadeOutUs,
    ClipKind? kind,
    String? sourcePath,
    TextSpec? text,
    TransitionSpec? transition,
    bool clearTransition = false,
    PipLayout? pip,
    bool clearPip = false,
    ColorGrade? grade,
    bool clearGrade = false,
    AudioFx? audioFx,
    ClipAnchor? anchor,
    bool clearAnchor = false,
  }) {
    return Clip(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      name: name ?? this.name,
      sourcePath: sourcePath ?? this.sourcePath,
      sourceDurationUs: sourceDurationUs,
      sourceInUs: sourceInUs ?? this.sourceInUs,
      sourceOutUs: sourceOutUs ?? this.sourceOutUs,
      startUs: startUs ?? this.startUs,
      speed: speed ?? this.speed,
      colorValue: colorValue ?? this.colorValue,
      media: media,
      rotation: (rotation ?? this.rotation) % 4,
      flipH: flipH ?? this.flipH,
      flipV: flipV ?? this.flipV,
      crop: crop ?? this.crop,
      fillFrom: clearFill ? null : (fillFrom ?? this.fillFrom),
      opacity: opacity ?? this.opacity,
      reversed: reversed ?? this.reversed,
      reverseProxy: clearReverseProxy
          ? null
          : (reverseProxy ?? this.reverseProxy),
      volume: volume ?? this.volume,
      fadeInUs: fadeInUs ?? this.fadeInUs,
      fadeOutUs: fadeOutUs ?? this.fadeOutUs,
      text: text ?? this.text,
      transition: clearTransition ? null : (transition ?? this.transition),
      pip: clearPip ? null : (pip ?? this.pip),
      grade: clearGrade ? null : (grade ?? this.grade),
      audioFx: audioFx ?? this.audioFx,
      anchor: clearAnchor ? null : (anchor ?? this.anchor),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'sourcePath': sourcePath,
    'sourceDurationUs': sourceDurationUs,
    'sourceInUs': sourceInUs,
    'sourceOutUs': sourceOutUs,
    'startUs': startUs,
    'speed': speed,
    'colorValue': colorValue,
    if (media != null) 'media': media!.toJson(),
    if (rotation != 0) 'rotation': rotation,
    if (flipH) 'flipH': true,
    if (flipV) 'flipV': true,
    if (!crop.isFull) 'crop': crop.toJson(),
    if (fillFrom != null) 'fillFrom': fillFrom!.toJson(),
    if (opacity < 1) 'opacity': opacity,
    if (reversed) 'reversed': true,
    if (reverseProxy != null) 'reverseProxy': reverseProxy!.toJson(),
    if (volume != 1) 'volume': volume,
    if (fadeInUs > 0) 'fadeInUs': fadeInUs,
    if (fadeOutUs > 0) 'fadeOutUs': fadeOutUs,
    if (text != null) 'text': text!.toJson(),
    if (transition != null) 'transition': transition!.toJson(),
    if (pip != null) 'pip': pip!.toJson(),
    if (grade != null && !grade!.isNeutral) 'grade': grade!.toJson(),
    if (audioFx != null && !audioFx!.isNeutral) 'audioFx': audioFx!.toJson(),
    if (anchor != null) 'anchor': anchor!.toJson(),
  };

  factory Clip.fromJson(Map<String, Object?> json) {
    final sourceDuration = (json['sourceDurationUs'] as num).toInt();
    final sourceIn = (json['sourceInUs'] as num).toInt();
    final sourceOut = (json['sourceOutUs'] as num).toInt();
    return Clip(
      id: (json['id'] as num).toInt(),
      kind: ClipKind.values.byName(json['kind'] as String),
      name: json['name'] as String,
      sourcePath: json['sourcePath'] as String?,
      sourceDurationUs: sourceDuration,
      sourceInUs: math.max(0, sourceIn),
      sourceOutUs: math.min(sourceDuration, sourceOut),
      startUs: (json['startUs'] as num?)?.toInt() ?? 0,
      speed: ((json['speed'] as num?)?.toDouble() ?? 1.0).clamp(
        minSpeed,
        maxSpeed,
      ),
      colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFF607D8B,
      media: json['media'] == null
          ? null
          : MediaInfo.fromJson((json['media'] as Map).cast<String, Object?>()),
      rotation: ((json['rotation'] as num?)?.toInt() ?? 0) % 4,
      flipH: json['flipH'] as bool? ?? false,
      flipV: json['flipV'] as bool? ?? false,
      crop: CropRect.fromJson(json['crop']),
      fillFrom: json['fillFrom'] == null
          ? null
          : CropRect.fromJson(json['fillFrom']),
      opacity: ((json['opacity'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
      reversed: json['reversed'] as bool? ?? false,
      reverseProxy: ReverseProxy.fromJson(json['reverseProxy']),
      volume: ((json['volume'] as num?)?.toDouble() ?? 1.0).clamp(
        0.0,
        maxVolume,
      ),
      fadeInUs: (json['fadeInUs'] as num?)?.toInt() ?? 0,
      fadeOutUs: (json['fadeOutUs'] as num?)?.toInt() ?? 0,
      text: json['text'] is Map
          ? TextSpec.fromJson((json['text'] as Map).cast<String, Object?>())
          : null,
      transition: TransitionSpec.fromJson(json['transition']),
      pip: PipLayout.fromJson(json['pip']),
      grade: ColorGrade.fromJson(json['grade']),
      audioFx: AudioFx.fromJson(json['audioFx']),
      anchor: ClipAnchor.fromJson(json['anchor']),
    );
  }
}
