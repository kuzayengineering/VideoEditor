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
  // (High matches Lockbox's "High": hard to tell apart from the original.)
  standard('Standard', 0.05),
  high('High', 0.08),
  veryHigh('Very high', 0.12),
  maximum('Maximum', 0.18),

  /// The source videos' own bit rate (scaled to the export's size and frame
  /// rate): about as much detail as was filmed, nothing visibly lost.
  original('Original', 0.18);

  const ExportQuality(this.label, this.bitsPerPixel);
  final String label;

  /// Average compressed bits spent on each pixel of each frame (for HEVC).
  final double bitsPerPixel;
}

/// The "short side" of the picture: 1080 means 1920×1080 for 16:9 and
/// 1080×1920 for 9:16.
enum ExportResolution {
  p480('480p', 480),
  p720('720p', 720),
  p1080('1080p', 1080),
  p1440('1440p (2K)', 1440),
  p2160('2160p (4K)', 2160);

  const ExportResolution(this.label, this.shortSide);
  final String label;
  final int shortSide;
}

/// Which recording date the exported video carries (what galleries such as
/// Google Photos sort it by).
enum ExportDate {
  firstClip('Same as first clip'),
  now('When exported'),
  custom('Choose…');

  const ExportDate(this.label);
  final String label;
}

class ExportSettings {
  const ExportSettings({
    this.resolution = ExportResolution.p2160,
    this.frameRate = 60,
    this.quality = ExportQuality.high,
    this.dynamicRange = DynamicRange.hlg,
    this.codec = VideoCodec.hevc,
    this.outputFolder,
    this.date = ExportDate.firstClip,
    this.customDate,
    this.creationTime,
  });

  final ExportDate date;

  /// The date picked for [ExportDate.custom].
  final DateTime? customDate;

  /// The exact date written into the file, worked out when Export is
  /// pressed (null: the engine's default).
  final DateTime? creationTime;

  /// The date for [date]: [firstClipDate] is when the first clip was
  /// recorded (if known).
  DateTime resolveDate({DateTime? firstClipDate, DateTime? now}) {
    now ??= DateTime.now();
    return switch (date) {
      ExportDate.firstClip => firstClipDate ?? now,
      ExportDate.now => now,
      ExportDate.custom => customDate ?? now,
    };
  }

  static const frameRates = <double>[24, 25, 30, 50, 60];

  /// Sensible starting choices for a project: the largest resolution the
  /// clips actually have (no pointless upscaling), the project's frame rate,
  /// and HDR if any clip is HDR (in the clips' own HDR format).
  static ExportSettings suggestedFor(Project project) {
    final media = [
      for (final c in project.mainTrack.clips)
        if (c.media != null) c.media!,
    ];
    if (media.isEmpty) return const ExportSettings();
    final shortSide = media
        .map((m) => m.width < m.height ? m.width : m.height)
        .reduce((a, b) => a > b ? a : b);
    var resolution = ExportResolution.values.first;
    for (final r in ExportResolution.values) {
      if (r.shortSide <= shortSide + 8) resolution = r;
    }
    var fps = frameRates.last;
    for (final f in frameRates) {
      if ((f - project.frameRate).abs() < (fps - project.frameRate).abs()) {
        fps = f;
      }
    }
    final hdr = media.where((m) => m.isHdr).toList();
    final range = hdr.isEmpty
        ? DynamicRange.sdr
        : (hdr.every((m) => m.transfer == ColorTransfer.pq)
              ? DynamicRange.hdr10
              : DynamicRange.hlg);
    return ExportSettings(
      resolution: resolution,
      frameRate: fps,
      dynamicRange: range,
    );
  }

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
    bool resetFolder = false,
    ExportDate? date,
    DateTime? customDate,
    DateTime? creationTime,
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
      outputFolder: resetFolder ? null : (outputFolder ?? this.outputFolder),
      date: date ?? this.date,
      customDate: customDate ?? this.customDate,
      creationTime: creationTime ?? this.creationTime,
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

  /// Average video bit rate in bits per second: pixels × frames × the
  /// quality's bits per pixel, but never more than the source videos' own
  /// rate (scaled to the export's size and frame rate) when [project] is
  /// given: spending more than the original can't add quality, only size.
  int videoBitrateFor(CanvasRatio canvas, {Project? project}) {
    final d = dimensionsFor(canvas);
    var bpp = quality.bitsPerPixel;
    if (codec == VideoCodec.h264) bpp *= 1.4; // H.264 is less efficient
    var rate = (d.width * d.height * frameRate * bpp).round();
    if (project != null) {
      int? cap;
      for (final c in project.mainTrack.clips) {
        final m = c.media;
        final src = m?.videoBitRate;
        if (m == null || src == null || m.width <= 0 || m.height <= 0) continue;
        var scaled = src * (d.width * d.height) / (m.width * m.height);
        if (m.frameRate > 0 && frameRate < m.frameRate) {
          scaled *= frameRate / m.frameRate;
        }
        // H.264 from an HEVC original needs more for the same picture.
        if (codec == VideoCodec.h264 && m.codec == 'hevc') scaled *= 1.4;
        final s = scaled.round();
        if (cap == null || s > cap) cap = s;
      }
      if (quality == ExportQuality.original && cap != null) {
        // Match the originals, rather than only never going over them.
        rate = math.max(cap, 500000);
      } else if (cap != null && cap < rate) {
        rate = math.max(cap, 500000);
      }
    }
    return rate;
  }

  int peakBitrateFor(CanvasRatio canvas, {Project? project}) =>
      (videoBitrateFor(canvas, project: project) * vbrPeakFactor).round();

  /// Rough file size. It's an estimate because variable bit rate spends
  /// more on busy scenes and less on calm ones.
  int estimatedBytes(CanvasRatio canvas, int durationUs, {Project? project}) {
    final bits =
        (videoBitrateFor(canvas, project: project) + audioBitrateBps) *
        durationUs /
        usPerSecond;
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
