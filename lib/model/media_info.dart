/// How a video's brightness values are encoded.
enum ColorTransfer {
  /// Standard dynamic range (BT.709 / sRGB-like).
  sdr,

  /// HDR, Hybrid Log-Gamma: what most phones (including Pixels) record.
  hlg,

  /// HDR, Perceptual Quantizer (SMPTE ST 2084): used by HDR10 / Dolby Vision.
  pq;

  bool get isHdr => this != ColorTransfer.sdr;

  String get label => switch (this) {
    ColorTransfer.sdr => 'SDR',
    ColorTransfer.hlg => 'HDR · HLG',
    ColorTransfer.pq => 'HDR · PQ',
  };
}

/// Facts about a media file, read once when it is imported.
class MediaInfo {
  const MediaInfo({
    required this.durationUs,
    required this.width,
    required this.height,
    this.frameRate = 30,
    this.transfer = ColorTransfer.sdr,
    this.bitDepth = 8,
    this.hasVideo = true,
    this.hasAudio = true,
    this.codec,
    this.wideGamut = false,
    this.createdAtMs,
  });

  /// When the video was recorded (from the file's own information), in
  /// milliseconds since 1970 (UTC), if known.
  final int? createdAtMs;

  DateTime? get createdAt => createdAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(createdAtMs!, isUtc: true);

  final int durationUs;

  /// Size as displayed, i.e. after applying the file's rotation flag.
  final int width;
  final int height;

  final double frameRate;
  final ColorTransfer transfer;
  final int bitDepth;
  final bool hasVideo;
  final bool hasAudio;

  /// e.g. "hevc", "h264".
  final String? codec;

  /// BT.2020 color primaries.
  final bool wideGamut;

  bool get isHdr => transfer.isHdr;

  /// "3840×2160 · 60 fps · HDR · HLG"
  String get summary {
    final fps = frameRate == frameRate.roundToDouble()
        ? frameRate.toStringAsFixed(0)
        : frameRate.toStringAsFixed(2);
    return '$width×$height · $fps fps · ${transfer.label}';
  }

  Map<String, Object?> toJson() => {
    'durationUs': durationUs,
    'width': width,
    'height': height,
    'frameRate': frameRate,
    'transfer': transfer.name,
    'bitDepth': bitDepth,
    'hasVideo': hasVideo,
    'hasAudio': hasAudio,
    'codec': codec,
    'wideGamut': wideGamut,
    if (createdAtMs != null) 'createdAtMs': createdAtMs,
  };

  factory MediaInfo.fromJson(Map<String, Object?> json) => MediaInfo(
    durationUs: (json['durationUs'] as num).toInt(),
    width: (json['width'] as num).toInt(),
    height: (json['height'] as num).toInt(),
    frameRate: (json['frameRate'] as num?)?.toDouble() ?? 30,
    transfer:
        ColorTransfer.values.asNameMap()[json['transfer'] as String? ??
            'sdr'] ??
        ColorTransfer.sdr,
    bitDepth: (json['bitDepth'] as num?)?.toInt() ?? 8,
    hasVideo: json['hasVideo'] as bool? ?? true,
    hasAudio: json['hasAudio'] as bool? ?? true,
    codec: json['codec'] as String?,
    wideGamut: json['wideGamut'] as bool? ?? false,
    createdAtMs: (json['createdAtMs'] as num?)?.toInt(),
  );
}

/// Picks the standard frame rate closest to a measured one, so a phone video
/// reported as 59.94 or 60.02 fps lines up with a clean timeline.
double standardFrameRate(double measured) {
  const rates = [
    23.976,
    24.0,
    25.0,
    29.97,
    30.0,
    48.0,
    50.0,
    59.94,
    60.0,
    120.0,
  ];
  if (measured <= 0 || measured.isNaN) return 30;
  var best = rates.first;
  for (final r in rates) {
    if ((r - measured).abs() < (best - measured).abs()) best = r;
  }
  // Treat the NTSC rates as their round cousins: editing on a 60 fps grid
  // for 59.94 footage is indistinguishable and keeps timecodes simple.
  return switch (best) {
    23.976 => 24,
    29.97 => 30,
    59.94 => 60,
    _ => best,
  };
}
