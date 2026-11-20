import 'dart:math' as math;

/// How a text appears or disappears.
enum TextAnim {
  none('None'),
  fade('Fade'),
  slideUp('Slide up'),
  slideDown('Slide down'),
  slideLeft('Slide left'),
  slideRight('Slide right'),
  pop('Pop'),
  typewriter('Typewriter');

  const TextAnim(this.label);
  final String label;
}

enum TextAlignSpec { left, center, right }

/// The fonts bundled with the app (see assets/fonts).
const textFonts = [
  'Roboto',
  'Montserrat',
  'Oswald',
  'Anton',
  'Bebas Neue',
  'Bangers',
  'Playfair Display',
  'Lobster',
  'Pacifico',
  'Caveat',
];

/// Everything about one text overlay except its timing (which lives on the
/// clip that holds it).
class TextSpec {
  const TextSpec({
    this.text = 'Your text',
    this.font = 'Montserrat',
    this.size = 0.08,
    this.colorValue = 0xFFFFFFFF,
    this.bold = true,
    this.italic = false,
    this.outlineColorValue = 0xFF000000,
    this.outline = 0.0,
    this.boxColorValue,
    this.shadow = true,
    this.align = TextAlignSpec.center,
    this.x = 0.5,
    this.y = 0.8,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.animIn = TextAnim.none,
    this.animInUs = 500000,
    this.animOut = TextAnim.fade,
    this.animOutUs = 500000,
  });

  final String text;
  final String font;

  /// Letter height as a fraction of the video's height.
  final double size;
  final int colorValue;
  final bool bold;
  final bool italic;

  /// Outline around the letters; [outline] is its thickness as a fraction of
  /// the letter size (0 = no outline).
  final int outlineColorValue;
  final double outline;

  /// Colored box behind the text (null = none).
  final int? boxColorValue;
  final bool shadow;
  final TextAlignSpec align;

  /// Where the middle of the text sits, as fractions of the frame (0.5, 0.5
  /// is the centre).
  final double x;
  final double y;

  /// Extra enlargement from pinching (1 = normal) and tilt in degrees.
  final double scale;
  final double rotation;

  final TextAnim animIn;
  final int animInUs;
  final TextAnim animOut;
  final int animOutUs;

  TextSpec copyWith({
    String? text,
    String? font,
    double? size,
    int? colorValue,
    bool? bold,
    bool? italic,
    int? outlineColorValue,
    double? outline,
    int? boxColorValue,
    bool clearBox = false,
    bool? shadow,
    TextAlignSpec? align,
    double? x,
    double? y,
    double? scale,
    double? rotation,
    TextAnim? animIn,
    int? animInUs,
    TextAnim? animOut,
    int? animOutUs,
  }) => TextSpec(
    text: text ?? this.text,
    font: font ?? this.font,
    size: size ?? this.size,
    colorValue: colorValue ?? this.colorValue,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    outlineColorValue: outlineColorValue ?? this.outlineColorValue,
    outline: outline ?? this.outline,
    boxColorValue: clearBox ? null : (boxColorValue ?? this.boxColorValue),
    shadow: shadow ?? this.shadow,
    align: align ?? this.align,
    x: (x ?? this.x).clamp(-0.2, 1.2),
    y: (y ?? this.y).clamp(-0.2, 1.2),
    scale: (scale ?? this.scale).clamp(0.2, 6.0),
    rotation: rotation ?? this.rotation,
    animIn: animIn ?? this.animIn,
    animInUs: animInUs ?? this.animInUs,
    animOut: animOut ?? this.animOut,
    animOutUs: animOutUs ?? this.animOutUs,
  );

  /// Appearance that matters for drawing (not position or timing).
  String get lookKey => [
    text,
    font,
    size,
    colorValue,
    bold,
    italic,
    outlineColorValue,
    outline,
    boxColorValue,
    shadow,
    align.name,
    scale,
    rotation,
  ].join('|');

  Map<String, Object?> toJson() => {
    'text': text,
    'font': font,
    'size': size,
    'color': colorValue,
    'bold': bold,
    'italic': italic,
    'outlineColor': outlineColorValue,
    'outline': outline,
    'box': boxColorValue,
    'shadow': shadow,
    'align': align.name,
    'x': x,
    'y': y,
    'scale': scale,
    'rotation': rotation,
    'animIn': animIn.name,
    'animInUs': animInUs,
    'animOut': animOut.name,
    'animOutUs': animOutUs,
  };

  factory TextSpec.fromJson(Map<String, Object?> j) {
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    int i(String k, int def) => (j[k] as num?)?.toInt() ?? def;
    TextAnim anim(String k) =>
        TextAnim.values.asNameMap()[j[k] as String? ?? 'none'] ?? TextAnim.none;
    return TextSpec(
      text: j['text'] as String? ?? '',
      font: j['font'] as String? ?? 'Montserrat',
      size: d('size', 0.08),
      colorValue: i('color', 0xFFFFFFFF),
      bold: j['bold'] as bool? ?? true,
      italic: j['italic'] as bool? ?? false,
      outlineColorValue: i('outlineColor', 0xFF000000),
      outline: d('outline', 0),
      boxColorValue: (j['box'] as num?)?.toInt(),
      shadow: j['shadow'] as bool? ?? true,
      align:
          TextAlignSpec.values.asNameMap()[j['align'] as String? ?? 'center'] ??
          TextAlignSpec.center,
      x: d('x', 0.5),
      y: d('y', 0.8),
      scale: d('scale', 1),
      rotation: d('rotation', 0),
      animIn: anim('animIn'),
      animInUs: i('animInUs', 500000),
      animOut: anim('animOut'),
      animOutUs: i('animOutUs', 500000),
    );
  }
}

/// How a text looks at one moment of its animation.
class TextFrame {
  const TextFrame({
    this.alpha = 1,
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.visibleChars,
  });

  /// 0–1.
  final double alpha;

  /// Offset from the resting place, as fractions of the frame size.
  final double dx;
  final double dy;

  /// Extra size factor (pop).
  final double scale;

  /// Typewriter: how many characters show (null = all).
  final int? visibleChars;
}

/// Slides travel this far (fraction of the frame).
const slideDistance = 0.12;

/// Smooth start-fast/end-slow curve (0→1).
double easeOut(double p) => 1 - math.pow(1 - p.clamp(0.0, 1.0), 3).toDouble();

/// The animation state [offsetUs] into a text that lasts [durationUs].
///
/// The exporters use the same formulas (written out for FFmpeg and Kotlin),
/// so the export moves exactly like the preview.
TextFrame textFrameAt(TextSpec s, int offsetUs, int durationUs) {
  var alpha = 1.0, dx = 0.0, dy = 0.0, scale = 1.0;
  int? chars;
  // [leaving]: slides keep their named direction (a text that slides up
  // in comes from below; one that slides up out moves upwards and away).
  void apply(TextAnim a, double p, {bool leaving = false}) {
    final e = easeOut(p);
    final sign = leaving ? -1.0 : 1.0;
    switch (a) {
      case TextAnim.none:
        break;
      case TextAnim.fade:
        alpha *= p;
      case TextAnim.slideUp:
        dy += sign * (1 - e) * slideDistance;
        alpha *= p;
      case TextAnim.slideDown:
        dy -= sign * (1 - e) * slideDistance;
        alpha *= p;
      case TextAnim.slideLeft:
        dx += sign * (1 - e) * slideDistance;
        alpha *= p;
      case TextAnim.slideRight:
        dx -= sign * (1 - e) * slideDistance;
        alpha *= p;
      case TextAnim.pop:
        scale *= 0.5 + 0.5 * e;
        alpha *= p;
      case TextAnim.typewriter:
        final n = s.text.runes.length;
        final shown = (n * p).ceil().clamp(0, n);
        chars = chars == null ? shown : math.min(chars!, shown);
    }
  }

  final inLen = s.animIn == TextAnim.none
      ? 0
      : math.min(s.animInUs, durationUs ~/ 2);
  final outLen = s.animOut == TextAnim.none
      ? 0
      : math.min(s.animOutUs, durationUs ~/ 2);
  if (inLen > 0 && offsetUs < inLen) apply(s.animIn, offsetUs / inLen);
  final fromEnd = durationUs - offsetUs;
  if (outLen > 0 && fromEnd < outLen) {
    // Leaving is the arrival played backwards.
    apply(s.animOut, (fromEnd / outLen).clamp(0.0, 1.0), leaving: true);
  }
  return TextFrame(
    alpha: alpha.clamp(0.0, 1.0),
    dx: dx,
    dy: dy,
    scale: scale,
    visibleChars: chars,
  );
}
