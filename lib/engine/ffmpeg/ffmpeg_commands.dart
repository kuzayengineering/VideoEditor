/// Builds FFmpeg command lines for examining, thumbnailing and exporting.
///
/// Everything here is plain text-building with no side effects, so it can be
/// tested on any computer with FFmpeg installed.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../model/export_settings.dart';
import '../../model/project.dart';
import '../../model/timecode.dart';
import '../media_engine.dart';

// -----------------------------------------------------------------------------
// Color conversions
//
// Levels were measured (see test/ffmpeg_integration_test.dart):
// - SDR white  -> HLG 75 % and PQ 203 nits (ITU-R BT.2408 reference white)
// - HDR reference white -> SDR ~97 %, with highlights rolled off smoothly
//   (Möbius curve) instead of clipped.
// -----------------------------------------------------------------------------

/// zscale names for the input's color space.
String _zscaleIn(MediaInfo m) => switch (m.transfer) {
  ColorTransfer.hlg => 'tin=arib-std-b67:pin=2020:min=2020_ncl',
  ColorTransfer.pq => 'tin=smpte2084:pin=2020:min=2020_ncl',
  ColorTransfer.sdr =>
    m.wideGamut ? 'tin=709:pin=2020:min=2020_ncl' : 'tin=709:pin=709:min=709',
};

/// Filter that converts [source] footage to the export's color format, or
/// null if no conversion is needed.
String? colorConversionFilter(MediaInfo source, DynamicRange target) {
  final from = source.transfer;
  switch (target) {
    case DynamicRange.hlg:
      if (from == ColorTransfer.hlg) return null;
      return 'zscale=${_zscaleIn(source)}:t=arib-std-b67:p=2020:m=2020_ncl:r=tv:npl=203';
    case DynamicRange.hdr10:
      if (from == ColorTransfer.pq) return null;
      return 'zscale=${_zscaleIn(source)}:t=smpte2084:p=2020:m=2020_ncl:r=tv:npl=203';
    case DynamicRange.sdr:
      if (from == ColorTransfer.sdr && !source.wideGamut) return null;
      if (from == ColorTransfer.sdr) {
        return 'zscale=${_zscaleIn(source)}:t=709:p=709:m=709:r=tv';
      }
      return 'zscale=${_zscaleIn(source)}:t=linear:npl=100,format=gbrpf32le,'
          'zscale=p=709,tonemap=mobius:param=0.6:peak=10:desat=0,'
          'zscale=t=709:m=709:r=tv';
  }
}

/// FFmpeg's names for the export's color tags.
({String primaries, String transfer, String matrix}) colorTags(
  DynamicRange r,
) => switch (r) {
  DynamicRange.hlg => (
    primaries: 'bt2020',
    transfer: 'arib-std-b67',
    matrix: 'bt2020nc',
  ),
  DynamicRange.hdr10 => (
    primaries: 'bt2020',
    transfer: 'smpte2084',
    matrix: 'bt2020nc',
  ),
  DynamicRange.sdr => (primaries: 'bt709', transfer: 'bt709', matrix: 'bt709'),
};

// -----------------------------------------------------------------------------
// Encoders
// -----------------------------------------------------------------------------

/// A video encoder FFmpeg can use. Hardware encoders (graphics card or Intel
/// Quick Sync) are strongly preferred: they're many times faster.
enum EncoderFamily { nvenc, qsv, amf, software }

class VideoEncoder {
  const VideoEncoder(this.name, this.family, this.codec);

  final String name;
  final EncoderFamily family;
  final VideoCodec codec;

  bool get isHardware => family != EncoderFamily.software;

  String get friendlyName => switch (family) {
    EncoderFamily.nvenc => 'NVIDIA graphics',
    EncoderFamily.qsv => 'Intel Quick Sync',
    EncoderFamily.amf => 'AMD graphics',
    EncoderFamily.software => 'processor (software)',
  };

  /// Candidates in order of preference.
  static const hevcCandidates = [
    VideoEncoder('hevc_nvenc', EncoderFamily.nvenc, VideoCodec.hevc),
    VideoEncoder('hevc_qsv', EncoderFamily.qsv, VideoCodec.hevc),
    VideoEncoder('hevc_amf', EncoderFamily.amf, VideoCodec.hevc),
    VideoEncoder('libx265', EncoderFamily.software, VideoCodec.hevc),
  ];

  static const h264Candidates = [
    VideoEncoder('h264_nvenc', EncoderFamily.nvenc, VideoCodec.h264),
    VideoEncoder('h264_qsv', EncoderFamily.qsv, VideoCodec.h264),
    VideoEncoder('h264_amf', EncoderFamily.amf, VideoCodec.h264),
    VideoEncoder('libx264', EncoderFamily.software, VideoCodec.h264),
    VideoEncoder('libopenh264', EncoderFamily.software, VideoCodec.h264),
  ];

  /// Pixel format handed to the encoder.
  String pixelFormat({required bool tenBit}) {
    if (!tenBit) return family == EncoderFamily.software ? 'yuv420p' : 'nv12';
    return family == EncoderFamily.software ? 'yuv420p10le' : 'p010le';
  }

  /// Encoder options for variable bit rate at the given average and peak.
  List<String> args({
    required int bitrate,
    required int maxrate,
    required bool tenBit,
    required DynamicRange range,
    required double fps,
  }) {
    final common = [
      '-b:v',
      '$bitrate',
      '-maxrate',
      '$maxrate',
      '-bufsize',
      '${maxrate * 2}',
      '-g',
      '${(fps * 2).round()}',
    ];
    final hevcProfile = tenBit ? 'main10' : 'main';
    switch (family) {
      case EncoderFamily.nvenc:
        return [
          '-c:v',
          name,
          '-preset',
          'p5',
          '-tune',
          'hq',
          '-rc',
          'vbr',
          ...common,
          '-profile:v',
          codec == VideoCodec.hevc ? hevcProfile : 'high',
        ];
      case EncoderFamily.qsv:
        return [
          '-c:v',
          name,
          '-preset',
          'slow',
          ...common,
          '-profile:v',
          codec == VideoCodec.hevc ? hevcProfile : 'high',
        ];
      case EncoderFamily.amf:
        return [
          '-c:v',
          name,
          '-quality',
          'quality',
          '-rc',
          'vbr_peak',
          ...common,
          '-profile:v',
          codec == VideoCodec.hevc ? hevcProfile : 'high',
        ];
      case EncoderFamily.software:
        if (name == 'libx265') {
          final t = colorTags(range);
          return [
            '-c:v',
            name,
            '-preset',
            'medium',
            ...common,
            '-x265-params',
            'log-level=error:repeat-headers=1:colorprim=${t.primaries}:'
                'transfer=${t.transfer}:colormatrix=${t.matrix}'
                '${range == DynamicRange.hdr10 ? ':hdr10-opt=1' : ''}',
          ];
        }
        if (name == 'libx264') {
          return ['-c:v', name, '-preset', 'medium', ...common];
        }
        return ['-c:v', name, ...common];
    }
  }

  /// A tiny test encode used to find out which encoders actually work on
  /// this computer (an encoder can be built in but have no hardware behind
  /// it).
  List<String> probeArgs({required bool tenBit}) => [
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    'color=c=black:s=640x360:r=30:d=0.2',
    '-pix_fmt',
    pixelFormat(tenBit: tenBit),
    ...args(
      bitrate: 2000000,
      maxrate: 3000000,
      tenBit: tenBit,
      range: tenBit ? DynamicRange.hlg : DynamicRange.sdr,
      fps: 30,
    ),
    '-f',
    'null',
    '-',
  ];
}

// -----------------------------------------------------------------------------
// Probe
// -----------------------------------------------------------------------------

const probeArgsPrefix = [
  '-v',
  'error',
  '-print_format',
  'json',
  '-show_format',
  '-show_streams',
];

double _parseRate(Object? value) {
  if (value is! String || value.isEmpty) return 0;
  final parts = value.split('/');
  final n = double.tryParse(parts[0]) ?? 0;
  final d = parts.length > 1 ? double.tryParse(parts[1]) ?? 1 : 1;
  return d == 0 ? 0 : n / d;
}

/// Turns ffprobe's JSON output into [MediaInfo].
MediaInfo parseProbeJson(String text) {
  final json = (jsonDecode(text) as Map).cast<String, Object?>();
  final streams = [
    for (final s in json['streams'] as List? ?? const [])
      (s as Map).cast<String, Object?>(),
  ];
  final format = (json['format'] as Map?)?.cast<String, Object?>() ?? const {};
  final video = streams.where(
    (s) =>
        s['codec_type'] == 'video' &&
        ((s['disposition'] as Map?)?['attached_pic'] ?? 0) == 0,
  );
  final hasAudio = streams.any((s) => s['codec_type'] == 'audio');
  final durationSeconds = double.tryParse('${format['duration']}') ?? 0;
  final durationUs = (durationSeconds * usPerSecond).round();
  if (video.isEmpty) {
    return MediaInfo(
      durationUs: durationUs,
      width: 0,
      height: 0,
      hasVideo: false,
      hasAudio: hasAudio,
    );
  }
  final v = video.first;
  var width = (v['width'] as num?)?.toInt() ?? 0;
  var height = (v['height'] as num?)?.toInt() ?? 0;

  // Phones store portrait video as landscape plus a "rotate" flag.
  num rotation = 0;
  for (final sd in v['side_data_list'] as List? ?? const []) {
    final r = (sd as Map)['rotation'];
    if (r is num) rotation = r;
  }
  final tagRotate = ((v['tags'] as Map?)?['rotate']);
  if (rotation == 0 && tagRotate != null) {
    rotation = num.tryParse('$tagRotate') ?? 0;
  }
  if ((rotation.round().abs() % 180) == 90) {
    final t = width;
    width = height;
    height = t;
  }

  var fps = _parseRate(v['avg_frame_rate']);
  if (fps <= 0 || fps > 1000) fps = _parseRate(v['r_frame_rate']);

  final trc = v['color_transfer'] as String?;
  final transfer = switch (trc) {
    'arib-std-b67' => ColorTransfer.hlg,
    'smpte2084' => ColorTransfer.pq,
    _ => ColorTransfer.sdr,
  };
  final pixFmt = v['pix_fmt'] as String? ?? '';
  final bits =
      int.tryParse('${v['bits_per_raw_sample']}') ??
      (pixFmt.contains('10') ? 10 : (pixFmt.contains('12') ? 12 : 8));

  final streamDuration = double.tryParse('${v['duration']}');
  return MediaInfo(
    durationUs: durationUs > 0
        ? durationUs
        : ((streamDuration ?? 0) * usPerSecond).round(),
    width: width,
    height: height,
    frameRate: fps > 0 ? fps : 30,
    transfer: transfer,
    bitDepth: bits,
    hasAudio: hasAudio,
    codec: v['codec_name'] as String?,
    wideGamut: v['color_primaries'] == 'bt2020',
  );
}

// -----------------------------------------------------------------------------
// Thumbnails
// -----------------------------------------------------------------------------

/// One preview image at [timeUs]. Seeks to the nearest keyframe for speed.
List<String> thumbnailArgs(
  String source,
  MediaInfo info,
  int timeUs,
  int height,
  String outPath,
) {
  final tone = info.isHdr || info.wideGamut
      ? ',${colorConversionFilter(info, DynamicRange.sdr)}'
      : '';
  return [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-ss',
    _seconds(timeUs),
    '-noaccurate_seek',
    '-i',
    source,
    '-frames:v',
    '1',
    '-an',
    '-vf',
    'scale=-2:$height$tone,format=yuvj420p',
    '-q:v',
    '5',
    outPath,
  ];
}

// -----------------------------------------------------------------------------
// Export
// -----------------------------------------------------------------------------

String _seconds(int us) => (us / usPerSecond).toStringAsFixed(6);

int _even(double v) => math.max(2, (v / 2).round() * 2);

String _speedPts(double speed) => (speed - 1).abs() < 0.0001
    ? 'setpts=PTS-STARTPTS'
    : 'setpts=(PTS-STARTPTS)/${speed.toStringAsFixed(4)}';

/// Audio speed change that keeps the pitch (each atempo step handles
/// 0.5×–2×, so bigger changes are chained). Ends with a comma, or is empty.
String atempoChain(double speed) {
  if ((speed - 1).abs() < 0.0001) return '';
  final steps = <double>[];
  var s = speed;
  while (s > 2.0) {
    steps.add(2.0);
    s /= 2.0;
  }
  while (s < 0.5) {
    steps.add(0.5);
    s /= 0.5;
  }
  steps.add(s);
  return steps.map((x) => 'atempo=${x.toStringAsFixed(5)},').join();
}

/// Rotate, mirror and crop filters for a clip (in that order: the crop is
/// drawn on the turned picture, the way the user sees it).
List<String> lookFilters(Clip c) {
  final f = <String>[];
  switch (c.rotation) {
    case 1:
      f.add('transpose=clock');
    case 2:
      f.addAll(['hflip', 'vflip']);
    case 3:
      f.add('transpose=cclock');
  }
  if (c.flipH) f.add('hflip');
  if (c.flipV) f.add('vflip');
  final r = c.crop;
  if (!r.isFull) {
    String frac(double v) => v.toStringAsFixed(5);
    f.add(
      'crop=w=trunc(iw*${frac(r.width)}/2)*2:h=trunc(ih*${frac(r.height)}/2)*2:'
      'x=trunc(iw*${frac(r.left)}):y=trunc(ih*${frac(r.top)})',
    );
  }
  return f;
}

class FfmpegExportPlan {
  const FfmpegExportPlan({
    required this.args,
    required this.expectedFrames,
    required this.durationUs,
  });

  final List<String> args;
  final int expectedFrames;
  final int durationUs;
}

/// Builds the complete export command.
///
/// Every clip is decoded, converted to the output's color format, fitted
/// into the canvas (black bars where shapes differ), forced to the exact
/// frame rate and frame count, and joined. Audio is resampled and padded or
/// trimmed to the exact same length, so picture and sound can never drift
/// apart across cuts. Timing comes from frame counts, never from a clock,
/// which is why an export can't skip or freeze frames however busy the
/// computer is.
FfmpegExportPlan buildExportPlan({
  required Project project,
  required ExportSettings settings,
  required VideoEncoder encoder,
  required String outputPath,
}) {
  final clips = [
    for (final c in project.mainTrack.clips)
      if (c.isMedia) c,
  ];
  if (clips.isEmpty) {
    throw ArgumentError('The project has no videos to export.');
  }
  final dims = settings.dimensionsFor(project.canvas);
  final w = dims.width;
  final h = dims.height;
  final fps = settings.frameRate;
  final range = settings.dynamicRange;
  final tenBit = range.isHdr;
  final pixFmt = encoder.pixelFormat(tenBit: tenBit);
  final fpsText = fps == fps.roundToDouble()
      ? fps.toStringAsFixed(0)
      : fps.toStringAsFixed(3);

  final inputs = <String>[];
  final filters = <String>[];
  final concatInputs = StringBuffer();
  var totalFrames = 0;

  final workFmt = tenBit ? 'yuv420p10le' : 'yuv420p';
  final bg = project.background;

  for (var i = 0; i < clips.length; i++) {
    final c = clips[i];
    final info = c.media!;
    final frames = math.max(1, (c.durationUs * fps / usPerSecond).round());
    totalFrames += frames;
    final segSeconds = frames / fps;

    // Backwards clips read from their prepared reversed copy.
    final String path;
    final int startUs;
    if (c.reversed) {
      final proxy = c.reverseProxy;
      if (proxy == null || !c.reverseReady) {
        throw ArgumentError(
          'The reversed clip "${c.name}" is not ready yet. Turn Reverse off '
          'and on again to prepare it.',
        );
      }
      path = proxy.path;
      startUs = proxy.proxyTimeOf(c.sourceOutUs);
    } else {
      path = c.sourcePath!;
      startUs = c.sourceInUs;
    }
    inputs.addAll([
      '-ss', _seconds(startUs),
      // A little extra is read so the exact frame count can be cut below.
      '-t', _seconds(c.sourceLengthUs + 200000),
      '-i', path,
    ]);

    final color = colorConversionFilter(info, range);
    final head = [
      '[$i:v]${_speedPts(c.speed)}',
      'fps=$fpsText',
      ...lookFilters(c),
    ].join(',');
    // Every clip ends the same way: exact pixel format and exact frame count
    // (repeat the last frame if the file runs short, then cut).
    final tail = [
      'setsar=1',
      'format=$pixFmt',
      'tpad=stop_mode=clone:stop_duration=1',
      'trim=end_frame=$frames',
      'setpts=N/($fpsText)/TB[v$i]',
    ].join(',');
    final fit =
        'scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bicubic';

    if (bg.isPlainBlack && c.opacity >= 0.999) {
      // Simple and fastest: fit, black bars.
      filters.add(
        [
          head,
          fit,
          ?color,
          'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black',
          tail,
        ].join(','),
      );
    } else {
      final String fgSource;
      String background;
      if (bg.blur) {
        filters.add('$head,split=2[f$i][b$i]');
        fgSource = '[f$i]';
        // Blur at quarter size (fast), then enlarge: soft background made
        // from the video itself.
        final qw = _even(w / 4), qh = _even(h / 4);
        background = [
          '[b$i]scale=$qw:$qh:force_original_aspect_ratio=increase',
          'crop=$qw:$qh',
          'boxblur=luma_radius=${math.max(2, qh ~/ 18)}:luma_power=2',
          'scale=$w:$h:flags=bilinear',
          ?color,
          'format=$workFmt',
        ].join(',');
      } else {
        fgSource = '[fh$i]';
        filters.add('$head[fh$i]');
        final rgb = (bg.colorValue & 0xFFFFFF)
            .toRadixString(16)
            .padLeft(6, '0');
        final bgColor = colorConversionFilter(
          const MediaInfo(durationUs: 0, width: 0, height: 0),
          range,
        );
        background = [
          'color=c=0x$rgb:s=${w}x$h:r=$fpsText:d=${(segSeconds + 1).toStringAsFixed(3)}',
          'format=yuv420p',
          ?bgColor,
          'format=$workFmt',
        ].join(',');
      }
      filters.add(
        '$fgSource$fit,${color != null ? '$color,' : ''}format=$workFmt[fg$i]',
      );
      if (c.opacity < 0.999) {
        filters.add('$background,split=2[bga$i][bgb$i]');
        filters.add(
          '[bga$i][fg$i]overlay=x=(W-w)/2:y=(H-h)/2:shortest=1[comp$i]',
        );
        filters.add(
          '[comp$i][bgb$i]blend=all_mode=normal:'
          'all_opacity=${c.opacity.toStringAsFixed(3)}:shortest=1,$tail',
        );
      } else {
        filters.add('$background[bg$i]');
        filters.add('[bg$i][fg$i]overlay=x=(W-w)/2:y=(H-h)/2:shortest=1,$tail');
      }
    }

    final audioLen = segSeconds.toStringAsFixed(6);
    if (info.hasAudio) {
      filters.add(
        '[$i:a]asetpts=PTS-STARTPTS,${atempoChain(c.speed)}aresample=48000,'
        'aformat=sample_fmts=fltp:channel_layouts=stereo,'
        'apad,atrim=0:$audioLen,asetpts=N/SR/TB[a$i]',
      );
    } else {
      filters.add(
        'anullsrc=r=48000:cl=stereo,atrim=0:$audioLen,'
        'aformat=sample_fmts=fltp:channel_layouts=stereo[a$i]',
      );
    }
    concatInputs.write('[v$i][a$i]');
  }
  filters.add('${concatInputs}concat=n=${clips.length}:v=1:a=1[vout][aout]');

  final tags = colorTags(range);
  final args = [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostats',
    '-y',
    ...inputs,
    '-filter_complex',
    filters.join(';'),
    '-map',
    '[vout]',
    '-map',
    '[aout]',
    ...encoder.args(
      bitrate: settings.videoBitrateFor(project.canvas),
      maxrate: settings.peakBitrateFor(project.canvas),
      tenBit: tenBit,
      range: range,
      fps: fps,
    ),
    '-r',
    fpsText,
    '-color_primaries',
    tags.primaries,
    '-color_trc',
    tags.transfer,
    '-colorspace',
    tags.matrix,
    '-color_range',
    'tv',
    if (encoder.codec == VideoCodec.hevc) ...['-tag:v', 'hvc1'],
    '-c:a',
    'aac',
    '-b:a',
    '${ExportSettings.audioBitrateBps}',
    '-movflags',
    '+faststart',
    '-progress',
    'pipe:1',
    outputPath,
  ];
  return FfmpegExportPlan(
    args: args,
    expectedFrames: totalFrames,
    durationUs: (totalFrames * usPerSecond / fps).round(),
  );
}

/// Arguments for counting the frames in a finished file.
List<String> verifyArgs(String path) => [
  '-v',
  'error',
  '-select_streams',
  'v:0',
  '-count_packets',
  '-show_entries',
  'stream=nb_read_packets,color_transfer:format=duration',
  '-print_format',
  'json',
  path,
];

ExportVerification parseVerification(
  String json,
  int expectedFrames,
  int expectedDurationUs,
) {
  final data = (jsonDecode(json) as Map).cast<String, Object?>();
  final stream = ((data['streams'] as List?)?.firstOrNull as Map?) ?? const {};
  final format = (data['format'] as Map?) ?? const {};
  final frames = int.tryParse('${stream['nb_read_packets']}') ?? 0;
  final seconds = double.tryParse('${format['duration']}') ?? 0;
  final trc = stream['color_transfer'];
  return ExportVerification(
    expectedFrames: expectedFrames,
    actualFrames: frames,
    expectedDurationUs: expectedDurationUs,
    actualDurationUs: (seconds * usPerSecond).round(),
    isHdr: trc == null ? null : (trc == 'arib-std-b67' || trc == 'smpte2084'),
  );
}

/// Reads `out_time_us=` lines from FFmpeg's `-progress` output.
int? parseProgressLine(String line) {
  if (!line.startsWith('out_time_us=')) return null;
  return int.tryParse(line.substring('out_time_us='.length).trim());
}

// -----------------------------------------------------------------------------
// Reverse
// -----------------------------------------------------------------------------

class ReversePlan {
  const ReversePlan({
    required this.chunkArgs,
    required this.chunkPaths,
    required this.concatListPath,
    required this.concatList,
    required this.concatArgs,
  });

  /// One command per piece; each reverses a short piece of the clip.
  final List<List<String>> chunkArgs;
  final List<String> chunkPaths;

  /// The pieces in backwards order, joined without re-encoding.
  final String concatListPath;
  final String concatList;
  final List<String> concatArgs;
}

/// Plans a reversed copy of [inUs]–[outUs] of [source].
///
/// Reversing needs every frame of a stretch in memory at once, so the clip is
/// done in short pieces (half a second for 4K, a second otherwise), each
/// reversed, then the pieces are joined last-to-first. Quality is kept high
/// and the original color format (HDR or SDR) is preserved.
ReversePlan buildReversePlan({
  required String source,
  required MediaInfo info,
  required int inUs,
  required int outUs,
  required VideoEncoder encoder,
  required String workDir,
  required String outputPath,
}) {
  final pixels = info.width * info.height;
  final chunkUs = pixels > 2500000 ? 500000 : usPerSecond;
  final tenBit = info.isHdr || info.bitDepth > 8;
  final range = switch (info.transfer) {
    ColorTransfer.hlg => DynamicRange.hlg,
    ColorTransfer.pq => DynamicRange.hdr10,
    ColorTransfer.sdr => DynamicRange.sdr,
  };
  final tags = colorTags(range);
  final fps = info.frameRate > 0 ? info.frameRate : 30.0;
  final bitrate = (pixels * fps * 0.3).round();
  final chunkArgs = <List<String>>[];
  final chunkPaths = <String>[];
  var k = 0;
  for (var a = inUs; a < outUs; a += chunkUs, k++) {
    final len = math.min(chunkUs, outUs - a);
    final out = '$workDir/chunk_${k.toString().padLeft(5, '0')}.mp4';
    chunkPaths.add(out);
    chunkArgs.add([
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-ss',
      _seconds(a),
      '-t',
      _seconds(len),
      '-i',
      source,
      '-vf',
      'reverse,format=${encoder.pixelFormat(tenBit: tenBit)}',
      if (info.hasAudio) ...['-af', 'areverse'] else '-an',
      ...encoder.args(
        bitrate: bitrate,
        maxrate: (bitrate * 1.5).round(),
        tenBit: tenBit,
        range: range,
        fps: fps,
      ),
      '-color_primaries',
      tags.primaries,
      '-color_trc',
      tags.transfer,
      '-colorspace',
      tags.matrix,
      if (info.hasAudio) ...['-c:a', 'aac', '-b:a', '320000'],
      out,
    ]);
  }
  final listPath = '$workDir/pieces.txt';
  final list = [
    for (final p in chunkPaths.reversed) "file '${p.replaceAll("'", r"'\''")}'",
  ].join('\n');
  return ReversePlan(
    chunkArgs: chunkArgs,
    chunkPaths: chunkPaths,
    concatListPath: listPath,
    concatList: list,
    concatArgs: [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listPath,
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      if (encoder.codec == VideoCodec.hevc) ...['-tag:v', 'hvc1'],
      outputPath,
    ],
  );
}
