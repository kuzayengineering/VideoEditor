/// Builds FFmpeg command lines for examining, thumbnailing and exporting.
///
/// Everything here is plain text-building with no side effects, so it can be
/// tested on any computer with FFmpeg installed.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

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
  // When it was recorded ("2026-11-05T12:34:56.000000Z").
  final created = DateTime.tryParse(
    '${(format['tags'] as Map?)?['creation_time'] ?? ''}',
  );
  final createdAtMs = created != null && created.year > 1971
      ? created.millisecondsSinceEpoch
      : null;
  final durationSeconds = double.tryParse('${format['duration']}') ?? 0;
  final durationUs = (durationSeconds * usPerSecond).round();
  if (video.isEmpty) {
    return MediaInfo(
      durationUs: durationUs,
      width: 0,
      height: 0,
      hasVideo: false,
      hasAudio: hasAudio,
      createdAtMs: createdAtMs,
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
    createdAtMs: createdAtMs,
    videoBitRate: int.tryParse('${v['bit_rate']}'),
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

/// Volume and fade filters for a clip lasting [lengthSeconds] (each
/// begins with a comma, or the result is empty).
String gainFilters(Clip c, double lengthSeconds) {
  final f = c.effectiveFades;
  final out = StringBuffer();
  if ((c.volume - 1).abs() > 0.0001) {
    out.write(',volume=${c.volume.toStringAsFixed(4)}');
  }
  if (f.fadeIn > 0) {
    out.write(
      ',afade=t=in:st=0:d=${(f.fadeIn / usPerSecond).toStringAsFixed(4)}',
    );
  }
  if (f.fadeOut > 0) {
    final d = f.fadeOut / usPerSecond;
    final st = math.max(0.0, lengthSeconds - d);
    out.write(
      ',afade=t=out:st=${st.toStringAsFixed(4)}:d=${d.toStringAsFixed(4)}',
    );
  }
  return out.toString();
}

int _even(double v) => math.max(2, (v / 2).round() * 2);

/// A clip's sound effects as filters followed by a comma (or nothing).
String _fx(Clip c) {
  final f = c.activeAudioFx?.ffmpegFilters();
  return f == null ? '' : '$f,';
}

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

// -----------------------------------------------------------------------------
// Text overlays
//
// These mirror textFrameAt() in lib/model/text_spec.dart exactly, written as
// FFmpeg formulas, so the export animates like the preview.
// -----------------------------------------------------------------------------

String _f(double v) => v.toStringAsFixed(6);

/// Lengths of the arrive / leave animations (each at most half the text).
({double inSec, double outSec}) _animLengths(TextSpec s, double d) => (
  inSec: s.animIn == TextAnim.none
      ? 0
      : math.min(s.animInUs / usPerSecond, d / 2),
  outSec: s.animOut == TextAnim.none
      ? 0
      : math.min(s.animOutUs / usPerSecond, d / 2),
);

/// The pictures to show and for how long: the whole text, or for typewriter
/// animations one picture per letter count.
String textPictureList(TextSpec s, TextImages images, double d) {
  final l = _animLengths(s, d);
  final n = images.typewriterPaths.length - 1;
  final entries = <(String, double)>[];
  var middle = d;
  if (s.animIn == TextAnim.typewriter && n > 0 && l.inSec > 0) {
    for (var k = 1; k <= n; k++) {
      entries.add((images.typewriterPaths[k], l.inSec / n));
    }
    middle -= l.inSec;
  }
  final outEntries = <(String, double)>[];
  if (s.animOut == TextAnim.typewriter && n > 0 && l.outSec > 0) {
    for (var k = n; k >= 1; k--) {
      outEntries.add((images.typewriterPaths[k], l.outSec / n));
    }
    middle -= l.outSec;
  }
  if (middle > 0.0005) entries.add((images.fullPath, middle));
  entries.addAll(outEntries);
  String q(String p) => p.replaceAll("'", r"'\''");
  final b = StringBuffer('ffconcat version 1.0\n');
  for (final (path, dur) in entries) {
    b.writeln("file '${q(path)}'");
    b.writeln('duration ${_f(dur)}');
  }
  // The last picture is listed again so its duration counts.
  b.writeln("file '${q(entries.last.$1)}'");
  return b.toString();
}

const _alphaAnims = {
  TextAnim.fade,
  TextAnim.slideUp,
  TextAnim.slideDown,
  TextAnim.slideLeft,
  TextAnim.slideRight,
  TextAnim.pop,
};

/// Ease-out curve E(p) = 1 - (1 - p)^3 as an FFmpeg formula.
String _ease(String p) => '(1-pow(1-clip($p,0,1),3))';

/// Fades, pop scaling and colour conversion for one text (local time).
String textOverlayChain(TextSpec s, double d, String fps, DynamicRange range) {
  final l = _animLengths(s, d);
  final parts = <String>['fps=$fps', 'format=rgba'];
  if (_alphaAnims.contains(s.animIn) && l.inSec > 0) {
    parts.add('fade=t=in:st=0:d=${_f(l.inSec)}:alpha=1');
  }
  if (_alphaAnims.contains(s.animOut) && l.outSec > 0) {
    parts.add('fade=t=out:st=${_f(d - l.outSec)}:d=${_f(l.outSec)}:alpha=1');
  }
  final scales = <String>[
    if (s.animIn == TextAnim.pop && l.inSec > 0)
      '(0.5+0.5*${_ease('t/${_f(l.inSec)}')})',
    if (s.animOut == TextAnim.pop && l.outSec > 0)
      '(0.5+0.5*${_ease('(${_f(d)}-t)/${_f(l.outSec)}')})',
  ];
  if (scales.isNotEmpty) {
    final k = scales.join('*');
    parts.add(
      "scale=w='max(2,trunc(iw*$k/2)*2)':h='max(2,trunc(ih*$k/2)*2)':eval=frame",
    );
  }
  // Text is drawn in ordinary (SDR) colours; convert it so white text sits at
  // the HDR "reference white" instead of glaring at full brightness.
  final target = switch (range) {
    DynamicRange.hlg => 't=arib-std-b67:p=2020:m=2020_ncl:npl=203',
    DynamicRange.hdr10 => 't=smpte2084:p=2020:m=2020_ncl:npl=203',
    DynamicRange.sdr => 't=709:p=709:m=709',
  };
  parts.addAll([
    'format=gbrap',
    'zscale=tin=iec61966-2-1:pin=709:min=gbr:$target:r=tv',
    'format=${range.isHdr ? 'yuva420p10le' : 'yuva420p'}',
  ]);
  return parts.join(',');
}

/// Where the text's top-left corner goes, as overlay formulas (t is the
/// timeline time; w/h the text picture's current size).
({String x, String y}) textPositionExprs(
  TextSpec s,
  double startSec,
  double d,
  int frameW,
  int frameH,
) {
  final l = _animLengths(s, d);
  final pin = '(t-${_f(startSec)})/${_f(math.max(l.inSec, 1e-6))}';
  final pout = '(${_f(startSec + d)}-t)/${_f(math.max(l.outSec, 1e-6))}';
  // Each term: (+1 or -1, formula); written out with explicit signs.
  final dx = <(int, String)>[], dy = <(int, String)>[];
  void slide(TextAnim a, String p, int leaving) {
    final amount = '(1-${_ease(p)})';
    switch (a) {
      case TextAnim.slideUp:
        dy.add((leaving, '$amount*${_f(slideDistance * frameH)}'));
      case TextAnim.slideDown:
        dy.add((-leaving, '$amount*${_f(slideDistance * frameH)}'));
      case TextAnim.slideLeft:
        dx.add((leaving, '$amount*${_f(slideDistance * frameW)}'));
      case TextAnim.slideRight:
        dx.add((-leaving, '$amount*${_f(slideDistance * frameW)}'));
      default:
        break;
    }
  }

  if (l.inSec > 0) slide(s.animIn, pin, 1);
  if (l.outSec > 0) slide(s.animOut, pout, -1);
  String sum(List<(int, String)> xs) =>
      xs.map((t) => '${t.$1 > 0 ? '+' : '-'}${t.$2}').join();
  return (
    x: '${_f(s.x * frameW)}${sum(dx)}-w/2',
    y: '${_f(s.y * frameH)}${sum(dy)}-h/2',
  );
}

class FfmpegExportPlan {
  const FfmpegExportPlan({
    required this.args,
    required this.expectedFrames,
    required this.durationUs,
    this.sideFiles = const {},
    this.workingDirectory,
  });

  final List<String> args;

  /// Run FFmpeg in this folder: filter lookup tables are named relative to
  /// it (file paths inside filters are awkward on Windows).
  final String? workingDirectory;

  /// Small text files (lists of pictures) to write before running.
  final Map<String, String> sideFiles;
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
  Map<int, TextImages> textImages = const {},
  String? workDir,
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
  final clipFrames = <int>[];
  var totalFrames = 0;

  final workFmt = tenBit ? 'yuv420p10le' : 'yuv420p';

  // Filters: one lookup table per filtered clip, run on the video signal
  // (after conversion to the output's colours), as in the preview.
  final sideFiles = <String, String>{};
  String? gradeFilter(Clip c) {
    final g = c.gradeParams;
    if (g == null) return null;
    final name = 'grade_${c.id}.cube';
    sideFiles['${workDir ?? '.'}/$name'] = gradeCube(
      g,
      knee: range == DynamicRange.hdr10 ? kneePq : kneeHlg,
    );
    // To RGB and back with the output's own colour maths (FFmpeg's
    // guess would shift the colours).
    final matrix = range.isHdr ? 'bt2020' : 'bt709';
    final rgb = tenBit ? 'gbrp16le' : 'gbrp';
    return 'scale=in_color_matrix=$matrix:in_range=tv,format=$rgb,'
        'lut3d=file=$name:interp=tetrahedral,'
        'scale=out_color_matrix=$matrix:out_range=tv,format=$workFmt';
  }

  final bg = project.background;

  // Transitions, in frames. "Through black/white" trims half its length off
  // each clip and fades to and from the colour (exactly what Android does);
  // the others overlap the clips and blend them (xfade).
  final n = clips.length;
  final dipHead = List.filled(n, 0), dipTail = List.filled(n, 0);
  final dipHeadColor = List.filled(n, 'black'),
      dipTailColor = List.filled(n, 'black');
  // White at the brightness of paper, not the HDR maximum (which would
  // flash): reference white for HLG / HDR10 (measured 721 / 572 of 1023).
  final white = switch (range) {
    DynamicRange.hlg => '0xBFBFBF',
    DynamicRange.hdr10 => '0x949494',
    DynamicRange.sdr => 'white',
  };
  final xfadeAfter = List.filled(n, 0);
  for (var i = 0; i + 1 < n; i++) {
    final mainIndex = project.mainTrack.clips.indexOf(clips[i]);
    final linked =
        mainIndex >= 0 &&
        mainIndex + 1 < project.mainTrack.clips.length &&
        identical(project.mainTrack.clips[mainIndex + 1], clips[i + 1]);
    if (!linked) continue;
    final dFrames = (project.transitionUsAfter(mainIndex) * fps / usPerSecond)
        .round();
    if (dFrames <= 0) continue;
    final kind = clips[i].transition!.kind;
    if (kind.isDip) {
      dipTail[i] = dFrames ~/ 2;
      dipHead[i + 1] = dFrames - dFrames ~/ 2;
      final color = kind == TransitionKind.fadeWhite ? white : 'black';
      dipTailColor[i] = color;
      dipHeadColor[i + 1] = color;
    } else {
      xfadeAfter[i] = dFrames;
    }
  }

  for (var i = 0; i < clips.length; i++) {
    final c = clips[i];
    final info = c.media!;
    final frames = math.max(
      1,
      (c.durationUs * fps / usPerSecond).round() - dipHead[i] - dipTail[i],
    );
    clipFrames.add(frames);
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
    // Skip the part a fade-through-black trims off the start.
    final headSkipUs = (dipHead[i] / fps * usPerSecond * c.speed).round();
    inputs.addAll([
      '-ss', _seconds(startUs + headSkipUs),
      // A little extra is read so the exact frame count can be cut below.
      '-t', _seconds(c.sourceLengthUs + 200000),
      '-i', path,
    ]);

    final color = colorConversionFilter(info, range);
    final grade = gradeFilter(c);
    final head = [
      '[$i:v]${_speedPts(c.speed)}',
      // Smooth slow motion: in-between frames made from the motion
      // (instead of showing each frame for longer).
      if (c.smoothsSlowMo)
        'minterpolate=fps=$fpsText:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1',
      'fps=$fpsText',
      ...lookFilters(c),
    ].join(',');
    // Every clip ends the same way: exact pixel format and exact frame count
    // (repeat the last frame if the file runs short, then cut).
    final tailSteps = [
      'setsar=1',
      // Joined (and cross-faded) in a plain planar format; converted for
      // the encoder at the very end.
      'format=$workFmt',
      'tpad=stop_mode=clone:stop_duration=1',
      'trim=end_frame=$frames',
      'setpts=N/($fpsText)/TB',
      if (dipHead[i] > 0)
        'fade=t=in:st=0:d=${_f(dipHead[i] / fps)}:color=${dipHeadColor[i]}',
      if (dipTail[i] > 0)
        'fade=t=out:st=${_f((frames - dipTail[i]) / fps)}:d=${_f(dipTail[i] / fps)}:color=${dipTailColor[i]}',
    ];
    final tail = "${tailSteps.join(',')}[v$i]";
    final fit =
        'scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bicubic';

    if (bg.isPlainBlack && c.opacity >= 0.999) {
      // Simple and fastest: fit, black bars.
      filters.add(
        [
          head,
          fit,
          ?color,
          ?grade,
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
        '$fgSource$fit,${color != null ? '$color,' : ''}'
        '${grade != null ? '$grade,' : ''}format=$workFmt[fg$i]',
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
    if (info.hasAudio && c.volume > 0) {
      filters.add(
        '[$i:a]asetpts=PTS-STARTPTS,${atempoChain(c.speed)}aresample=48000,'
        'aformat=sample_fmts=fltp:channel_layouts=stereo,${_fx(c)}'
        'apad,atrim=0:$audioLen,asetpts=N/SR/TB${gainFilters(c, segSeconds)}'
        '${dipHead[i] > 0 ? ',afade=t=in:st=0:d=${_f(dipHead[i] / fps)}' : ''}'
        '${dipTail[i] > 0 ? ',afade=t=out:st=${_f((frames - dipTail[i]) / fps)}:d=${_f(dipTail[i] / fps)}' : ''}'
        '[a$i]',
      );
    } else {
      filters.add(
        'anullsrc=r=48000:cl=stereo,atrim=0:$audioLen,'
        'aformat=sample_fmts=fltp:channel_layouts=stereo[a$i]',
      );
    }
  }
  // Join the clips: plain cuts are joined end to end; transitions overlap
  // the clips (xfade for the picture, a crossfade for the sound), which
  // makes the video shorter by each transition's length.
  var curV = '[v0]', curA = '[a0]';
  var curFrames = clipFrames.first;
  for (var i = 1; i < clips.length; i++) {
    final dFrames = xfadeAfter[i - 1];
    final nextV = '[jv$i]', nextA = '[ja$i]';
    if (dFrames <= 0) {
      filters.add('$curV$curA[v$i][a$i]concat=n=2:v=1:a=1$nextV$nextA');
    } else {
      final kind = clips[i - 1].transition!.kind;
      final dSec = dFrames / fps;
      final offset = (curFrames - dFrames) / fps;
      filters.add(
        '$curV[v$i]xfade=transition=${kind.ffmpegName}:'
        'duration=${_f(dSec)}:offset=${_f(offset)}$nextV',
      );
      filters.add('$curA[a$i]acrossfade=d=${_f(dSec)}:c1=tri:c2=tri$nextA');
      totalFrames -= dFrames;
    }
    curFrames += clipFrames[i] - dFrames;
    curV = nextV;
    curA = nextA;
  }
  filters.add('${curV}format=$pixFmt[vout]');
  filters.add('${curA}anull[amain]');

  // Audio tracks (music, voice-over, extracted sound): each clip is cut,
  // sped up or slowed, given its volume and fades, delayed to its place on
  // the timeline, and mixed with the video's own sound. The mix is exactly
  // as long as the video.
  final videoSeconds = totalFrames / fps;
  final mixInputs = <String>['[amain]'];
  var inputIndex = clips.length;
  for (final track in project.audioTracks) {
    for (final a in track.clips) {
      if (!a.isMedia || !(a.media?.hasAudio ?? false) || a.volume <= 0) {
        continue;
      }
      final startSeconds = a.startUs / usPerSecond;
      if (startSeconds >= videoSeconds) continue;
      final String path;
      final int fromUs;
      if (a.reversed && a.reverseReady) {
        path = a.reverseProxy!.path;
        fromUs = a.reverseProxy!.proxyTimeOf(a.sourceOutUs);
      } else {
        path = a.sourcePath!;
        fromUs = a.sourceInUs;
      }
      inputs.addAll([
        '-ss',
        _seconds(fromUs),
        '-t',
        _seconds(a.sourceLengthUs),
        '-i',
        path,
      ]);
      final lengthSeconds = a.durationUs / usPerSecond;
      final delayMs = (a.startUs / 1000).round();
      filters.add(
        '[$inputIndex:a]asetpts=PTS-STARTPTS,${atempoChain(a.speed)}'
        'aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,'
        '${_fx(a)}atrim=0:${lengthSeconds.toStringAsFixed(6)}'
        '${gainFilters(a, lengthSeconds)},'
        'adelay=$delayMs|$delayMs[t$inputIndex]',
      );
      mixInputs.add('[t$inputIndex]');
      inputIndex++;
    }
  }
  // Picture in picture: each clip is cut and timed like a main clip, given
  // its turn/mirror/crop and colour conversion, scaled to its size, turned
  // by its angle (transparent corners), faded by its opacity, and laid on
  // the video while it plays. Its sound joins the mix.
  final pipLabels = <String>[];
  var videoAfterPip = 'vout';
  var pipNo = 0;
  final pipFmt = tenBit ? 'yuva420p10le' : 'yuva420p';
  for (final track in project.overlayTracks) {
    for (final c in track.clips) {
      final info = c.media;
      if (!c.isMedia || info == null || c.pip == null) continue;
      final startSeconds = c.startUs / usPerSecond;
      if (startSeconds >= videoSeconds) continue;
      final String path;
      final int fromUs;
      if (c.reversed && c.reverseReady) {
        path = c.reverseProxy!.path;
        fromUs = c.reverseProxy!.proxyTimeOf(c.sourceOutUs);
      } else {
        path = c.sourcePath!;
        fromUs = c.sourceInUs;
      }
      inputs.addAll([
        '-ss',
        _seconds(fromUs),
        '-t',
        _seconds(c.sourceLengthUs + 200000),
        '-i',
        path,
      ]);
      final j = inputIndex++;
      final frames = math.max(1, (c.durationUs * fps / usPerSecond).round());
      final pip = c.pip!;
      final d = c.displaySize;
      final pw = _even(pip.size * w);
      final ph = _even(d.width > 0 ? pw * d.height / d.width : pw * 9 / 16);
      final color = colorConversionFilter(info, range);
      final angle = pip.angle * math.pi / 180;
      final turn = angle.abs() < 1e-6
          ? null
          : 'rotate=a=${angle.toStringAsFixed(6)}:'
                'ow=rotw(${angle.toStringAsFixed(6)}):'
                'oh=roth(${angle.toStringAsFixed(6)}):c=none';
      final chain = [
        '[$j:v]${_speedPts(c.speed)}',
        'fps=$fpsText',
        ...lookFilters(c),
        ?color,
        ?gradeFilter(c),
        'scale=$pw:$ph:flags=bicubic',
        'setsar=1',
        'format=$pipFmt',
        if (c.opacity < 0.999 && pip.blend == PipBlend.normal)
          'lutyuv=a=val*${c.opacity.toStringAsFixed(4)}',
        ?turn,
        'tpad=stop_mode=clone:stop_duration=1',
        'trim=end_frame=$frames',
        'setpts=N/($fpsText)/TB+${startSeconds.toStringAsFixed(6)}/TB',
      ];
      filters.add('${chain.join(',')}[pv$j]');
      final endSeconds = startSeconds + frames / fps;
      final next = 'vp${pipNo++}';
      final place =
          'x=${(pip.x * w).toStringAsFixed(2)}-overlay_w/2:'
          'y=${(pip.y * h).toStringAsFixed(2)}-overlay_h/2:'
          "enable='between(t,${startSeconds.toStringAsFixed(6)},"
          "${endSeconds.toStringAsFixed(6)})':eof_action=pass";
      if (pip.blend == PipBlend.normal) {
        filters.add('[$videoAfterPip][pv$j]overlay=$place:format=auto[$next]');
      } else {
        // Blend modes: the clip on a full-frame layer that is neutral
        // everywhere else (black for Screen/Add/Lighten, white for
        // Multiply/Darken: no change there), then the two pictures are
        // mixed colour by colour (in RGB, with the output's own colour
        // maths).
        final neutral = pip.blend.neutralIsWhite ? 'white' : 'black';
        final mode = switch (pip.blend) {
          PipBlend.screen => 'screen',
          PipBlend.add => 'addition',
          PipBlend.multiply => 'multiply',
          PipBlend.lighten => 'lighten',
          PipBlend.darken => 'darken',
          PipBlend.normal => 'normal',
        };
        final matrix = range.isHdr ? 'bt2020' : 'bt709';
        final rgb = tenBit ? 'gbrp16le' : 'gbrp';
        final toRgb = 'scale=in_color_matrix=$matrix:in_range=tv,format=$rgb';
        filters.add(
          'color=c=$neutral:s=${w}x$h:r=$fpsText:'
          'd=${videoSeconds.toStringAsFixed(6)},format=$pipFmt[pn$j]',
        );
        filters.add('[pn$j][pv$j]overlay=$place:format=auto,$toRgb[pl$j]');
        filters.add('[$videoAfterPip]$toRgb[pb$j]');
        filters.add(
          '[pb$j][pl$j]blend=all_mode=$mode:'
          'all_opacity=${c.opacity.clamp(0.0, 1.0).toStringAsFixed(4)}:'
          'shortest=1,'
          'scale=out_color_matrix=$matrix:out_range=tv,format=$workFmt[$next]',
        );
      }
      videoAfterPip = next;
      pipLabels.add(next);
      if ((info.hasAudio) && c.volume > 0) {
        final lengthSeconds = c.durationUs / usPerSecond;
        final delayMs = (c.startUs / 1000).round();
        filters.add(
          '[$j:a]asetpts=PTS-STARTPTS,${atempoChain(c.speed)}'
          'aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,'
          '${_fx(c)}atrim=0:${lengthSeconds.toStringAsFixed(6)}'
          '${gainFilters(c, lengthSeconds)},'
          'adelay=$delayMs|$delayMs[t$j]',
        );
        mixInputs.add('[t$j]');
      }
    }
  }
  if (videoAfterPip != 'vout') {
    filters.add('[$videoAfterPip]format=$pixFmt[vpip]');
  }

  if (mixInputs.length == 1) {
    filters.add('[amain]anull[aout]');
  } else {
    // normalize=0: every sound keeps the loudness you set (no automatic
    // turning-down when tracks are added).
    filters.add(
      '${mixInputs.join()}amix=inputs=${mixInputs.length}:normalize=0:'
      'duration=first:dropout_transition=0,'
      'atrim=0:${videoSeconds.toStringAsFixed(6)}[aout]',
    );
  }

  // Text overlays, drawn on top of the finished picture.
  var videoLabel = pipLabels.isEmpty ? 'vout' : 'vpip';
  final initialVideo = videoLabel;
  final textWork = workDir ?? '.';
  var textNo = 0;
  for (final track in project.textTracks) {
    for (final c in track.clips) {
      final spec = c.text;
      final images = textImages[c.id];
      if (spec == null || images == null) continue;
      final startSec = c.startUs / usPerSecond;
      if (startSec >= videoSeconds) continue;
      final d = math.min(c.durationUs / usPerSecond, videoSeconds - startSec);
      final listPath = '$textWork/text_${c.id}.ffconcat';
      sideFiles[listPath] = textPictureList(spec, images, d);
      inputs.addAll(['-f', 'concat', '-safe', '0', '-i', listPath]);
      final j = inputIndex++;
      filters.add(
        '[$j:v]${textOverlayChain(spec, d, fpsText, range)},'
        'setpts=PTS-STARTPTS+${startSec.toStringAsFixed(6)}/TB[tx$j]',
      );
      final pos = textPositionExprs(spec, startSec, d, w, h);
      final next = 'vt${textNo++}';
      filters.add(
        '[$videoLabel][tx$j]overlay=x=\'${pos.x}\':y=\'${pos.y}\':'
        'eval=frame:eof_action=pass[$next]',
      );
      videoLabel = next;
    }
  }
  if (videoLabel != initialVideo) {
    filters.add('[$videoLabel]format=$pixFmt[vfinal]');
    videoLabel = 'vfinal';
  }

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
    '[$videoLabel]',
    '-map',
    '[aout]',
    ...encoder.args(
      bitrate: settings.videoBitrateFor(project.canvas, project: project),
      maxrate: settings.peakBitrateFor(project.canvas, project: project),
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
    // The recording date galleries sort by (otherwise the first clip's).
    if (settings.creationTime != null) ...[
      '-metadata',
      'creation_time=${settings.creationTime!.toUtc().toIso8601String()}',
    ],
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
    sideFiles: sideFiles,
    workingDirectory: workDir,
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

/// Loudest sample in each group of [perBucket] samples, scaled to 0–255.
Uint8List peaksFromSamples(Int16List samples, int perBucket) {
  final out = Uint8List((samples.length / perBucket).ceil());
  for (var b = 0; b < out.length; b++) {
    var peak = 0;
    final end = math.min(samples.length, (b + 1) * perBucket);
    for (var i = b * perBucket; i < end; i++) {
      final v = samples[i].abs();
      if (v > peak) peak = v;
    }
    out[b] = math.min(255, peak * 255 ~/ 32767);
  }
  return out;
}

/// The filming location in ffprobe's format tags (ISO 6709, such as
/// "+37.4219-122.0840/"), from phones' "location" or Apple's tag.
String? locationFromProbeJson(String json) {
  try {
    final tags = (jsonDecode(json) as Map)['format']?['tags'] as Map?;
    if (tags == null) return null;
    for (final e in tags.entries) {
      final k = '${e.key}'.toLowerCase();
      if (k == 'location' || k == 'com.apple.quicktime.location.iso6709') {
        final v = '${e.value}'.trim();
        if (RegExp(r'^[+-]\d').hasMatch(v)) return v;
      }
    }
  } catch (_) {}
  return null;
}
