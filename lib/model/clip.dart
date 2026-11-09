import 'dart:math' as math;

/// What a clip holds.
enum ClipKind { video, audio }

/// One piece of media placed on the timeline.
///
/// A clip never changes the original file. It just says "use this part of
/// that file": from [sourceInUs] to [sourceOutUs], played at [speed].
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
  });

  /// Unique within a project.
  final int id;
  final ClipKind kind;

  /// Display name shown on the timeline.
  final String name;

  /// File on disk. `null` for the colored placeholder clips in the demo.
  final String? sourcePath;

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

  /// Length of the used part of the original file.
  int get sourceLengthUs => sourceOutUs - sourceInUs;

  /// How long the clip lasts on the timeline (after speed is applied).
  int get durationUs => (sourceLengthUs / speed).round();

  int get endUs => startUs + durationUs;

  Clip copyWith({
    int? id,
    String? name,
    int? sourceInUs,
    int? sourceOutUs,
    int? startUs,
    double? speed,
    int? colorValue,
  }) {
    return Clip(
      id: id ?? this.id,
      kind: kind,
      name: name ?? this.name,
      sourcePath: sourcePath,
      sourceDurationUs: sourceDurationUs,
      sourceInUs: sourceInUs ?? this.sourceInUs,
      sourceOutUs: sourceOutUs ?? this.sourceOutUs,
      startUs: startUs ?? this.startUs,
      speed: speed ?? this.speed,
      colorValue: colorValue ?? this.colorValue,
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
      speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
      colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFF607D8B,
    );
  }
}
