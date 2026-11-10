import 'dart:math' as math;

/// A colour with channels from 0 to 1.
typedef Rgb = ({double r, double g, double b});

/// Reads a picture at (u, v): u from 0 (left) to 1 (right), v from 0 (top)
/// to 1 (bottom).
typedef Sampler = Rgb Function(double u, double v);

const Rgb _black = (r: 0, g: 0, b: 0);

Rgb _mix(Rgb x, Rgb y, double m) => (
  r: x.r + (y.r - x.r) * m,
  g: x.g + (y.g - x.g) * m,
  b: x.b + (y.b - x.b) * m,
);

double _smooth(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _fract(double x) => x - x.floorToDouble();

/// One pixel of a mixing transition ([code] is [TransitionKind.code]) at
/// [t] (0 = start, 1 = end), between picture [a] (outgoing) and [b]
/// (incoming), for an output of [w] × [h] pixels.
///
/// The same maths as Android's TransitionBlender.kt shader and FFmpeg's
/// xfade filter (Windows), so the picker's little previews show exactly
/// what the video does.
Rgb transitionPixel(
  int code,
  double u,
  double v,
  double t,
  double w,
  double h,
  Sampler a,
  Sampler b,
) {
  t = t.clamp(0.0, 1.0);
  final p = 1 - t; // FFmpeg's "progress"
  Rgb sa(double x, double y) => a(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  Rgb sb(double x, double y) => b(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  final halfDiag = math.sqrt(w * w + h * h) / 2;
  double dist() {
    final dx = (u - 0.5) * w, dy = (v - 0.5) * h;
    return math.sqrt(dx * dx + dy * dy);
  }

  switch (code) {
    case 1: // crossfade
      return _mix(sa(u, v), sb(u, v), t);
    case 2: // dissolve
      final px = (u * w).floorToDouble(), py = (v * h).floorToDouble();
      final r = _fract(math.sin(px * 12.9898 + py * 78.233) * 43758.545);
      return r * 2 + p * 2 - 1.5 >= 0.5 ? sa(u, v) : sb(u, v);
    case 3: // pixelate
      final d = math.min(p, 1 - p);
      final step = (d * 50).ceilToDouble() / 50;
      final sq = 2 * step * math.min(w, h) / 20;
      var qu = u, qv = v;
      if (step > 0) {
        qu = math.min(((u * w / sq).floorToDouble() + 0.5) * sq, w - 1) / w;
        qv = math.min(((v * h / sq).floorToDouble() + 0.5) * sq, h - 1) / h;
      }
      return _mix(sa(qu, qv), sb(qu, qv), t);
    case 4: // zoom in
      final zf = _smooth(0.5, 1, p);
      final za = sa(0.5 + (u - 0.5) * zf, 0.5 + (v - 0.5) * zf);
      return _mix(sb(u, v), za, _smooth(0, 0.5, p));
    case 10: // slide left
      final s = u + t - 1;
      return s >= 0 ? sb(s, v) : sa(u + t, v);
    case 11: // slide right
      final s = u + 1 - t;
      return s < 1 ? sb(s, v) : sa(s - 1, v);
    case 12: // slide up
      final s = v + t - 1;
      return s >= 0 ? sb(u, s) : sa(u, v + t);
    case 13: // slide down
      final s = v + 1 - t;
      return s < 1 ? sb(u, s) : sa(u, s - 1);
    case 14: // cover left
      final s = u + t - 1;
      return s >= 0 ? sb(s, v) : sa(u, v);
    case 15: // cover right
      final s = u + 1 - t;
      return s < 1 ? sb(s, v) : sa(u, v);
    case 16: // cover up
      final s = v + t - 1;
      return s >= 0 ? sb(u, s) : sa(u, v);
    case 17: // cover down
      final s = v + 1 - t;
      return s < 1 ? sb(u, s) : sa(u, v);
    case 18: // reveal left
      return u + t - 1 >= 0 ? sb(u, v) : sa(u + t, v);
    case 19: // reveal right
      final s = u + 1 - t;
      return s < 1 ? sb(u, v) : sa(s - 1, v);
    case 20: // reveal up
      return v + t - 1 >= 0 ? sb(u, v) : sa(u, v + t);
    case 21: // reveal down
      final s = v + 1 - t;
      return s < 1 ? sb(u, v) : sa(u, s - 1);
    case 30: // wipe left
      return u > p ? sb(u, v) : sa(u, v);
    case 31: // wipe right
      return u > t ? sa(u, v) : sb(u, v);
    case 32: // wipe up
      return v > p ? sb(u, v) : sa(u, v);
    case 33: // wipe down
      return v > t ? sa(u, v) : sb(u, v);
    case 34: // soft wipe left
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, 1 + u - 2 * p));
    case 35: // soft wipe right
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, 2 - u - 2 * p));
    case 36: // soft wipe up
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, 1 + v - 2 * p));
    case 37: // soft wipe down
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, 2 - v - 2 * p));
    case 38: // corner, to the top left
      return v <= p && u <= p ? sa(u, v) : sb(u, v);
    case 39: // corner, to the top right
      return v <= p && u > t ? sa(u, v) : sb(u, v);
    case 40: // corner, to the bottom left
      return v > t && u <= p ? sa(u, v) : sb(u, v);
    case 41: // corner, to the bottom right
      return v > t && u > t ? sa(u, v) : sb(u, v);
    case 42: // clock
      final angle = math.atan2((u - 0.5) * w, (v - 0.5) * h);
      final s = angle - (p - 0.5) * math.pi * 2.5;
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, s));
    case 50: // circle open
      final s = dist() / halfDiag + (p - 0.5) * 3;
      return _mix(sb(u, v), sa(u, v), _smooth(0, 1, s));
    case 51: // circle close
      final s = dist() / halfDiag + (t - 0.5) * 3;
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, s));
    case 52: // iris (through black)
      final r = math.pow(2 * (p - 0.5).abs(), 3) * halfDiag;
      if (r < dist()) return _black;
      return p < 0.5 ? sb(u, v) : sa(u, v);
    case 53: // box (through black)
      final hz = (p - 0.5).abs();
      final inside = (u - 0.5).abs() < hz && (v - 0.5).abs() < hz;
      if (!inside) return _black;
      return p < 0.5 ? sb(u, v) : sa(u, v);
    case 54: // doors open
      final s = 2 - (u - 0.5).abs() * 2 - 2 * p;
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, s));
    case 55: // doors close
      final s = 1 + (u - 0.5).abs() * 2 - 2 * p;
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, s));
    case 56: // split open
      final s = 2 - (v - 0.5).abs() * 2 - 2 * p;
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, s));
    case 57: // split close
      final s = 1 + (v - 0.5).abs() * 2 - 2 * p;
      return _mix(sa(u, v), sb(u, v), _smooth(0, 1, s));
    default:
      return sa(u, v);
  }
}

/// A dip through [color]: the outgoing clip fades to it by the middle, then
/// the incoming clip fades in from it.
Rgb dipPixel(double u, double v, double t, Rgb color, Sampler a, Sampler b) {
  final amount = 1 - (2 * t - 1).abs();
  final pic = t < 0.5 ? a(u, v) : b(u, v);
  return _mix(pic, color, amount);
}
