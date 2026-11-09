import 'dart:math' as math;

import 'project.dart';
import 'timecode.dart';

/// HDR or SDR output.
enum DynamicRange {
  hlg('HDR · HLG', 'Best for phones, YouTube and most HDR TVs'),
  hdr10('HDR · HDR10', 'Common for TVs and streaming'),
  sdr('SDR', 'Plays everywhere; HDR footage is tone-mapped');

  const DynamicRange(this.label, this.description);
  final String label;
  final String description;

  bool get isHdr => this != DynamicRange.sdr;
}

/// Video compression format.
enum VideoCodec {
  hevc('HEVC (H.265)'),
  h264('H.264');

  const VideoCodec(this.label);
  final String label;

  /// H.264 has no practical 10-bit HDR support on phones and PCs.
  bool supports(DynamicRange range) => this == VideoCodec.hevc || !range.isHdr;
}

/// Quality level. Higher means bigger files and finer detail.
enum ExportQuality {
  standard('Standard', 0.06),
  high('High', 0.10),
  veryHigh('Very high', 0.15),
  maximum('Maximum', 0.22);

  const ExportQuality(this.label, this.bitsPerPixel);
  final String label;

  /// Average compressed bits spent on each pixel of each frame (for HEVC).
  final double bitsPerPixel;
}

/// The "short side" of the picture: 1080 means 1920×1080 for 16:9 and
/// 1080×1920 for 9:16.
enum ExportResolution {
  p720('720p', 720),
  p1080('1080p', 1080),
  p1440('1440p (2K)', 1440),
  p2160('2160p (4K)', 2160);

  const ExportResolution(this.label, this.shortSide);
  final String label;
  final int shortSide;
}

class ExportSettings {
  const ExportSettings({
    this.resolution = ExportResolution.p2160,
    this.frameRate = 60,
    this.quality = ExportQuality.high,
    this.dynamicRange = DynamicRange.hlg,
    this.codec = VideoCodec.hevc,
    this.outputFolder,
  });

  static const frameRates = <double>[24, 25, 30, 50, 60];

  /// Audio is exported as AAC at this bit rate.
  static const audioBitrateBps = 256000;

  /// Variable bit rate peaks are allowed to reach this multiple of the
  /// average.
  static const vbrPeakFactor = 1.5;

  final ExportResolution resolution;
  final double frameRate;
  final ExportQuality quality;
  final DynamicRange dynamicRange;
  final VideoCodec codec;

  /// Where the file is saved. `null` means the default Movies/Videos folder.
  final String? outputFolder;

  ExportSettings copyWith({
    ExportResolution? resolution,
    double? frameRate,
    ExportQuality? quality,
    DynamicRange? dynamicRange,
    VideoCodec? codec,
    String? outputFolder,
  }) {
    final range = dynamicRange ?? this.dynamicRange;
    var chosenCodec = codec ?? this.codec;
    // Picking HDR switches to a codec that can carry it.
    if (!chosenCodec.supports(range)) chosenCodec = VideoCodec.hevc;
    return ExportSettings(
      resolution: resolution ?? this.resolution,
      frameRate: frameRate ?? this.frameRate,
      quality: quality ?? this.quality,
      dynamicRange: range,
      codec: chosenCodec,
      outputFolder: outputFolder ?? this.outputFolder,
    );
  }

  /// Output size in pixels for a canvas shape. Both sides are kept even,
  /// which video encoders require.
  ({int width, int height}) dimensionsFor(CanvasRatio canvas) {
    final short = resolution.shortSide;
    int even(double v) => (v / 2).round() * 2;
    if (canvas.width >= canvas.height) {
      return (width: even(short * canvas.value), height: short);
    }
    return (width: short, height: even(short / canvas.value));
  }

  /// Average video bit rate in bits per second.
  int videoBitrateFor(CanvasRatio canvas) {
    final d = dimensionsFor(canvas);
    var bpp = quality.bitsPerPixel;
    if (codec == VideoCodec.h264) bpp *= 1.4; // H.264 is less efficient
    if (dynamicRange.isHdr) bpp *= 1.1; // 10-bit needs a little more
    return (d.width * d.height * frameRate * bpp).round();
  }

  int peakBitrateFor(CanvasRatio canvas) =>
      (videoBitrateFor(canvas) * vbrPeakFactor).round();

  /// Rough file size. It's an estimate because variable bit rate spends
  /// more on busy scenes and less on calm ones.
  int estimatedBytes(CanvasRatio canvas, int durationUs) {
    final bits =
        (videoBitrateFor(canvas) + audioBitrateBps) * durationUs / usPerSecond;
    return math.max(0, (bits / 8).round());
  }

  /// One-line summary such as "3840 × 2160 · 60 fps · HEVC 10-bit HLG".
  String summary(CanvasRatio canvas) {
    final d = dimensionsFor(canvas);
    final fps = frameRate == frameRate.roundToDouble()
        ? frameRate.toStringAsFixed(0)
        : frameRate.toStringAsFixed(2);
    final color = switch (dynamicRange) {
      DynamicRange.hlg => '10-bit HLG',
      DynamicRange.hdr10 => '10-bit HDR10',
      DynamicRange.sdr => '8-bit SDR',
    };
    final codecName = codec == VideoCodec.hevc ? 'HEVC' : 'H.264';
    return '${d.width} × ${d.height} · $fps fps · $codecName $color';
  }
}

/// "52 Mbps", "800 kbps".
String formatBitrate(int bps) {
  if (bps >= 1000000) {
    final mbps = bps / 1000000;
    return '${mbps >= 10 ? mbps.toStringAsFixed(0) : mbps.toStringAsFixed(1)} Mbps';
  }
  return '${(bps / 1000).round()} kbps';
}

/// "1.2 GB", "350 MB".
String formatBytes(int bytes) {
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final text = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
