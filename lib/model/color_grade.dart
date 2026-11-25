import 'dart:math' as math;

/// The adjustable parts of a filter. Each runs from -1 to 1 (0 = no
/// change), except [fade], 0 to 1.
class GradeParams {
  const GradeParams({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.tint = 0,
    this.fade = 0,
    this.shadows = 0,
    this.highlights = 0,
    this.hdr = 0,
    this.blackPoint = 0,
    this.whitePoint = 0,
  });

  /// Positive: the darkest tones become black (deeper blacks); negative:
  /// black is raised.
  final double blackPoint;

  /// Positive: the brightest tones become full white (brighter whites);
  /// negative: white is dimmed.
  final double whitePoint;

  /// Lighter or darker dark tones (black stays black).
  final double shadows;

  /// Lighter or darker bright tones (white stays white).
  final double highlights;

  /// More or less of the brightness above paper white (HDR's extra range).
  final double hdr;

  final double brightness;
  final double contrast;
  final double saturation;

  /// Positive: warmer (orange); negative: cooler (blue).
  final double warmth;

  /// Positive: towards magenta; negative: towards green.
  final double tint;

  /// Lifts the blacks for a softer, washed look.
  final double fade;

  static const neutral = GradeParams();

  bool get isNeutral =>
      brightness.abs() < 1e-4 &&
      contrast.abs() < 1e-4 &&
      saturation.abs() < 1e-4 &&
      warmth.abs() < 1e-4 &&
      tint.abs() < 1e-4 &&
      fade.abs() < 1e-4 &&
      shadows.abs() < 1e-4 &&
      highlights.abs() < 1e-4 &&
      hdr.abs() < 1e-4 &&
      blackPoint.abs() < 1e-4 &&
      whitePoint.abs() < 1e-4;

  GradeParams operator *(double k) => GradeParams(
    brightness: brightness * k,
    contrast: contrast * k,
    saturation: saturation * k,
    warmth: warmth * k,
    tint: tint * k,
    fade: fade * k,
    shadows: shadows * k,
    highlights: highlights * k,
    hdr: hdr * k,
    blackPoint: blackPoint * k,
    whitePoint: whitePoint * k,
  );

  /// Adds two sets of changes (kept within range).
  GradeParams operator +(GradeParams o) => GradeParams(
    brightness: (brightness + o.brightness).clamp(-1.0, 1.0),
    contrast: (contrast + o.contrast).clamp(-1.0, 1.0),
    saturation: (saturation + o.saturation).clamp(-1.0, 1.0),
    warmth: (warmth + o.warmth).clamp(-1.0, 1.0),
    tint: (tint + o.tint).clamp(-1.0, 1.0),
    fade: (fade + o.fade).clamp(0.0, 1.0),
    shadows: (shadows + o.shadows).clamp(-1.0, 1.0),
    highlights: (highlights + o.highlights).clamp(-1.0, 1.0),
    hdr: (hdr + o.hdr).clamp(-1.0, 1.0),
    blackPoint: (blackPoint + o.blackPoint).clamp(-1.0, 1.0),
    whitePoint: (whitePoint + o.whitePoint).clamp(-1.0, 1.0),
  );

  GradeParams copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? warmth,
    double? tint,
    double? fade,
    double? shadows,
    double? highlights,
    double? hdr,
    double? blackPoint,
    double? whitePoint,
  }) => GradeParams(
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    warmth: warmth ?? this.warmth,
    tint: tint ?? this.tint,
    fade: fade ?? this.fade,
    shadows: shadows ?? this.shadows,
    highlights: highlights ?? this.highlights,
    hdr: hdr ?? this.hdr,
    blackPoint: blackPoint ?? this.blackPoint,
    whitePoint: whitePoint ?? this.whitePoint,
  );

  /// In the order the shaders take them.
  List<double> get values => [
    brightness,
    contrast,
    saturation,
    warmth,
    tint,
    fade,
    shadows,
    highlights,
    hdr,
    blackPoint,
    whitePoint,
  ];

  @override
  bool operator ==(Object other) =>
      other is GradeParams &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.warmth == warmth &&
      other.tint == tint &&
      other.fade == fade &&
      other.shadows == shadows &&
      other.highlights == highlights &&
      other.hdr == hdr &&
      other.blackPoint == blackPoint &&
      other.whitePoint == whitePoint;

  @override
  int get hashCode => Object.hash(
    brightness,
    contrast,
    saturation,
    warmth,
    tint,
    fade,
    shadows,
    highlights,
    hdr,
    blackPoint,
    whitePoint,
  );

  Map<String, Object?> toJson() => {
    if (brightness != 0) 'brightness': brightness,
    if (contrast != 0) 'contrast': contrast,
    if (saturation != 0) 'saturation': saturation,
    if (warmth != 0) 'warmth': warmth,
    if (tint != 0) 'tint': tint,
    if (fade != 0) 'fade': fade,
    if (shadows != 0) 'shadows': shadows,
    if (highlights != 0) 'highlights': highlights,
    if (hdr != 0) 'hdr': hdr,
    if (blackPoint != 0) 'blackPoint': blackPoint,
    if (whitePoint != 0) 'whitePoint': whitePoint,
  };

  factory GradeParams.fromJson(Object? json) {
    if (json is! Map) return neutral;
    double v(String k) => (json[k] as num?)?.toDouble() ?? 0;
    return GradeParams(
      brightness: v('brightness').clamp(-1.0, 1.0),
      contrast: v('contrast').clamp(-1.0, 1.0),
      saturation: v('saturation').clamp(-1.0, 1.0),
      warmth: v('warmth').clamp(-1.0, 1.0),
      tint: v('tint').clamp(-1.0, 1.0),
      fade: v('fade').clamp(0.0, 1.0),
      shadows: v('shadows').clamp(-1.0, 1.0),
      highlights: v('highlights').clamp(-1.0, 1.0),
      hdr: v('hdr').clamp(-1.0, 1.0),
      blackPoint: v('blackPoint').clamp(-1.0, 1.0),
      whitePoint: v('whitePoint').clamp(-1.0, 1.0),
    );
  }
}

/// Ready-made looks. Each is a set of [GradeParams].
enum FilterPreset {
  none('None', GradeParams.neutral),
  vivid('Vivid', GradeParams(saturation: 0.35, contrast: 0.25)),
  pop('Pop', GradeParams(saturation: 0.6, contrast: 0.15, brightness: 0.1)),
  warm('Warm', GradeParams(warmth: 0.45, saturation: 0.1)),
  golden(
    'Golden',
    GradeParams(warmth: 0.6, saturation: 0.15, brightness: 0.05, tint: 0.05),
  ),
  cool('Cool', GradeParams(warmth: -0.45)),
  cinematic(
    'Cinematic',
    GradeParams(
      contrast: 0.25,
      saturation: -0.15,
      warmth: -0.12,
      tint: -0.06,
      fade: 0.15,
    ),
  ),
  dramatic(
    'Dramatic',
    GradeParams(contrast: 0.55, saturation: -0.25, brightness: -0.15),
  ),
  moody(
    'Moody',
    GradeParams(
      brightness: -0.25,
      saturation: -0.3,
      warmth: -0.2,
      contrast: 0.2,
    ),
  ),
  bright('Bright', GradeParams(brightness: 0.35, contrast: 0.05)),
  soft('Soft', GradeParams(contrast: -0.3, brightness: 0.15, fade: 0.25)),
  faded('Faded', GradeParams(fade: 0.6, contrast: -0.25, saturation: -0.2)),
  vintage(
    'Vintage',
    GradeParams(
      fade: 0.45,
      warmth: 0.3,
      saturation: -0.3,
      contrast: -0.1,
      tint: 0.08,
    ),
  ),
  sepia('Sepia', GradeParams(saturation: -1, warmth: 0.65, fade: 0.2)),
  mono('Black & white', GradeParams(saturation: -1, contrast: 0.1)),
  noir('Noir', GradeParams(saturation: -1, contrast: 0.6, brightness: -0.15));

  const FilterPreset(this.label, this.params);
  final String label;
  final GradeParams params;
}

/// A clip's filter: a ready-made look at some strength, plus manual
/// adjustments on top.
class ColorGrade {
  const ColorGrade({
    this.preset = FilterPreset.none,
    this.strength = 1,
    this.adjust = GradeParams.neutral,
  });

  final FilterPreset preset;

  /// How much of the look (0–1).
  final double strength;
  final GradeParams adjust;

  /// The combined changes.
  GradeParams get params => preset.params * strength + adjust;

  bool get isNeutral => params.isNeutral;

  ColorGrade copyWith({
    FilterPreset? preset,
    double? strength,
    GradeParams? adjust,
  }) => ColorGrade(
    preset: preset ?? this.preset,
    strength: strength ?? this.strength,
    adjust: adjust ?? this.adjust,
  );

  @override
  bool operator ==(Object other) =>
      other is ColorGrade &&
      other.preset == preset &&
      other.strength == strength &&
      other.adjust == adjust;

  @override
  int get hashCode => Object.hash(preset, strength, adjust);

  Map<String, Object?> toJson() => {
    if (preset != FilterPreset.none) 'preset': preset.name,
    if (strength != 1) 'strength': strength,
    if (!adjust.isNeutral) 'adjust': adjust.toJson(),
  };

  static ColorGrade? fromJson(Object? json) {
    if (json is! Map) return null;
    return ColorGrade(
      preset:
          FilterPreset.values.asNameMap()[json['preset']] ?? FilterPreset.none,
      strength: ((json['strength'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0),
      adjust: GradeParams.fromJson(json['adjust']),
    );
  }
}

double _smooth(double x) => x * x * (3 - 2 * x);

/// Signal value of paper white (203 nits), where HDR's extra range
/// starts: HLG (and, for "HDR intensity", SDR) 0.75, PQ 0.58.
const kneeHlg = 0.75;
const kneePq = 0.58;

/// The filter maths, on video signal values from 0 to 1 (what is stored in
/// the file: SDR, HLG or PQ). Every step keeps black at 0 and white at 1, so
/// HDR highlights never clip. The same steps run in Android's GradeEffect
/// shader and in the Windows export's lookup table. [knee] is paper white
/// in this signal (see [kneeHlg], [kneePq]).
({double r, double g, double b}) applyGrade(
  GradeParams p,
  double r,
  double g,
  double b, {
  double knee = kneeHlg,
}) {
  // 1. Saturation, around the brightness of the colour.
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final k = 1 + p.saturation;
  r = y + (r - y) * k;
  g = y + (g - y) * k;
  b = y + (b - y) * k;
  // 2. Warmth and tint: only ever turn channels down.
  final w = p.warmth, t = p.tint;
  if (w > 0) {
    g *= 1 - 0.06 * w;
    b *= 1 - 0.22 * w;
  } else {
    r *= 1 + 0.22 * w;
    g *= 1 + 0.06 * w;
  }
  if (t > 0) {
    g *= 1 - 0.15 * t;
  } else {
    r *= 1 + 0.15 * t;
    b *= 1 + 0.15 * t;
  }
  r = r.clamp(0.0, 1.0);
  g = g.clamp(0.0, 1.0);
  b = b.clamp(0.0, 1.0);
  // 3. Brightness as a curve (0 and 1 stay put).
  final e = math.pow(2, -p.brightness).toDouble();
  // 4. Shadows and highlights: bend the dark / bright end (each keeps 0
  //    and 1 in place and never reverses tones).
  // 5. Contrast: towards (or away from) a gentle S-curve.
  // 6. HDR intensity: above paper white, more (or less) of the extra
  //    brightness; turned down it also lowers the brightest parts.
  // 7. Fade: lift the blacks.
  final f = 0.12 * p.fade;
  final he = math.pow(2, -p.hdr).toDouble();
  final hScale = p.hdr < 0 ? 1 + 0.5 * p.hdr : 1.0;
  // 0. Black and white points (levels): up to 15 % of the range at each
  //    end set to black / white, or black raised / white lowered by as much.
  final inLo = math.max(p.blackPoint, 0) * 0.15;
  final inHi = 1 - math.max(p.whitePoint, 0) * 0.15;
  final outLo = math.max(-p.blackPoint, 0) * 0.15;
  final outHi = 1 - math.max(-p.whitePoint, 0) * 0.15;
  double curve(double x) {
    x = ((x - inLo) / (inHi - inLo)).clamp(0.0, 1.0);
    x = outLo + x * (outHi - outLo);
    x = math.pow(x, e).toDouble();
    x = x + p.shadows * x * (1 - x) * (1 - x);
    x = x + p.highlights * x * x * (1 - x);
    x = x + p.contrast * (_smooth(x) - x);
    if (x > knee) {
      final t = (x - knee) / (1 - knee);
      x = knee + (1 - knee) * math.pow(t, he) * hScale;
    }
    return f + x * (1 - f);
  }

  return (r: curve(r), g: curve(g), b: curve(b));
}

/// The filter as a 3D lookup table in the ".cube" format (FFmpeg's lut3d).
String gradeCube(GradeParams p, {int size = 33, double knee = kneeHlg}) {
  final out = StringBuffer()
    ..writeln('LUT_3D_SIZE $size')
    ..writeln('DOMAIN_MIN 0 0 0')
    ..writeln('DOMAIN_MAX 1 1 1');
  final n = size - 1;
  // Red changes fastest.
  for (var bi = 0; bi < size; bi++) {
    for (var gi = 0; gi < size; gi++) {
      for (var ri = 0; ri < size; ri++) {
        final c = applyGrade(p, ri / n, gi / n, bi / n, knee: knee);
        out.writeln(
          '${c.r.toStringAsFixed(6)} ${c.g.toStringAsFixed(6)} '
          '${c.b.toStringAsFixed(6)}',
        );
      }
    }
  }
  return out.toString();
}

/// The closest simple colour mix (a 4×5 matrix as Flutter's
/// ColorFilter.matrix wants) to the filter, fitted over many sample
/// colours. Used where only such a mix can be drawn live (the Windows
/// preview); exports use the exact maths.
List<double> gradeMatrix(GradeParams p) =>
    _matrices.putIfAbsent(p, () => _fitMatrix(p));

final _matrices = <GradeParams, List<double>>{};

List<double> _fitMatrix(GradeParams p) {
  if (_matrices.length > 64) _matrices.clear();
  const steps = 6;
  // Normal equations for out = a·r + b·g + c·b + d, per output channel.
  final ata = List.generate(4, (_) => List.filled(4, 0.0));
  final atb = List.generate(3, (_) => List.filled(4, 0.0));
  for (var i = 0; i < steps; i++) {
    for (var j = 0; j < steps; j++) {
      for (var l = 0; l < steps; l++) {
        final x = [i / (steps - 1), j / (steps - 1), l / (steps - 1), 1.0];
        final o = applyGrade(p, x[0], x[1], x[2]);
        final outs = [o.r, o.g, o.b];
        for (var a = 0; a < 4; a++) {
          for (var b = 0; b < 4; b++) {
            ata[a][b] += x[a] * x[b];
          }
          for (var ch = 0; ch < 3; ch++) {
            atb[ch][a] += x[a] * outs[ch];
          }
        }
      }
    }
  }
  final m = <double>[];
  for (var ch = 0; ch < 3; ch++) {
    final s = _solve4(ata, atb[ch]);
    m.addAll([s[0], s[1], s[2], 0, s[3] * 255]);
  }
  m.addAll([0, 0, 0, 1, 0]);
  return m;
}

List<double> _solve4(List<List<double>> a, List<double> b) {
  final m = [
    for (var i = 0; i < 4; i++) [...a[i], b[i]],
  ];
  for (var c = 0; c < 4; c++) {
    var pivot = c;
    for (var r = c + 1; r < 4; r++) {
      if (m[r][c].abs() > m[pivot][c].abs()) pivot = r;
    }
    final tmp = m[c];
    m[c] = m[pivot];
    m[pivot] = tmp;
    for (var r = 0; r < 4; r++) {
      if (r == c) continue;
      final f = m[r][c] / m[c][c];
      for (var k = c; k < 5; k++) {
        m[r][k] -= f * m[c][k];
      }
    }
  }
  return [for (var i = 0; i < 4; i++) m[i][4] / m[i][i]];
}
