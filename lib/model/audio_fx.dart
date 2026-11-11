import 'dart:math' as math;

/// Kinds of space for the reverb (each a set of reflections).
enum ReverbKind {
  room('Room'),
  hall('Hall'),
  church('Church'),
  cave('Cave');

  const ReverbKind(this.label);
  final String label;
}

/// Ready-made equalizer settings (gains for [AudioFx.eqFrequencies]).
enum EqPreset {
  flat('Flat', [0, 0, 0, 0, 0, 0, 0]),
  voice('Voice clarity', [-6, -3, -1, 1, 4, 3, 1]),
  bass('Bass boost', [6, 4, 1, 0, 0, 0, 0]),
  treble('Treble boost', [0, 0, 0, 0, 2, 4, 6]),
  warm('Warm', [2, 3, 1, 0, 0, -2, -3]),
  rumble('Less rumble', [-12, -6, 0, 0, 0, 0, 0]),
  telephone('Telephone', [-12, -12, 0, 4, 3, -12, -12]);

  const EqPreset(this.label, this.gains);
  final String label;
  final List<double> gains;
}

/// A clip's sound effects: equalizer, pitch, delay and reverb.
///
/// One description, two engines: the Windows version turns it into FFmpeg
/// filters ([ffmpegFilters], used by both its preview player and its
/// export); Android runs the same equalizer maths and echo taps in its own
/// audio processor ([toEngineMap]).
class AudioFx {
  const AudioFx({
    this.pitch = 0,
    this.eq = const [0, 0, 0, 0, 0, 0, 0],
    this.reverb,
    this.reverbAmount = 0.35,
    this.delayMs,
    this.delayRepeats = 0.4,
    this.delayAmount = 0.4,
  });

  /// Semitones up (+) or down (−), from −12 to 12. The speed doesn't change.
  final int pitch;

  /// Gain of each equalizer band in dB (−12 to 12).
  final List<double> eq;

  /// The space, or null for no reverb.
  final ReverbKind? reverb;

  /// How much reverb (0–1).
  final double reverbAmount;

  /// Time between echoes, or null for no delay.
  final double? delayMs;

  /// How strongly each echo repeats (0.1–0.8).
  final double delayRepeats;

  /// How loud the echoes are (0–1).
  final double delayAmount;

  /// Centre of each equalizer band (Hz).
  static const eqFrequencies = <double>[60, 150, 400, 1000, 2400, 6000, 15000];

  /// Width of each band (FFmpeg's "Q").
  static const eqQ = 1.0;

  static const none = AudioFx();

  bool get hasEq => eq.any((g) => g.abs() > 0.05);

  bool get isNeutral =>
      pitch == 0 &&
      !hasEq &&
      (reverb == null || reverbAmount <= 0.001) &&
      (delayMs == null || delayAmount <= 0.001);

  /// How much the pitch is multiplied by.
  double get pitchFactor => math.pow(2, pitch / 12).toDouble();

  AudioFx copyWith({
    int? pitch,
    List<double>? eq,
    ReverbKind? reverb,
    bool clearReverb = false,
    double? reverbAmount,
    double? delayMs,
    bool clearDelay = false,
    double? delayRepeats,
    double? delayAmount,
  }) => AudioFx(
    pitch: (pitch ?? this.pitch).clamp(-12, 12),
    eq: eq ?? this.eq,
    reverb: clearReverb ? null : (reverb ?? this.reverb),
    reverbAmount: (reverbAmount ?? this.reverbAmount).clamp(0.0, 1.0),
    delayMs: clearDelay ? null : (delayMs ?? this.delayMs),
    delayRepeats: (delayRepeats ?? this.delayRepeats).clamp(0.1, 0.8),
    delayAmount: (delayAmount ?? this.delayAmount).clamp(0.0, 1.0),
  );

  /// Reflections of the reverb: (delay in ms, loudness).
  List<({double ms, double gain})> get reverbTaps {
    final kind = reverb;
    if (kind == null || reverbAmount <= 0.001) return const [];
    final (times, first, keep) = switch (kind) {
      ReverbKind.room => (const [12.0, 19, 27, 34, 43, 53, 64, 77], 0.55, 0.82),
      ReverbKind.hall => (
        const [23.0, 37, 51, 67, 83, 101, 121, 143, 167, 193],
        0.5,
        0.86,
      ),
      ReverbKind.church => (
        const [41.0, 67, 97, 131, 167, 211, 257, 307, 361, 421, 487],
        0.5,
        0.88,
      ),
      ReverbKind.cave => (
        const [73.0, 131, 197, 269, 349, 439, 541, 653],
        0.55,
        0.85,
      ),
    };
    return [
      for (var i = 0; i < times.length; i++)
        (
          ms: times[i].toDouble(),
          gain: reverbAmount * first * math.pow(keep, i).toDouble(),
        ),
    ];
  }

  /// The echoes of the delay: (delay in ms, loudness).
  List<({double ms, double gain})> get delayTaps {
    final ms = delayMs;
    if (ms == null || delayAmount <= 0.001) return const [];
    return [
      for (var i = 1; i <= 4; i++)
        (
          ms: ms * i,
          gain: delayAmount * math.pow(delayRepeats, i - 1).toDouble(),
        ),
    ];
  }

  /// FFmpeg audio filters for these effects (for 48 kHz stereo input), or
  /// null for none. Order: pitch, equalizer, delay, reverb.
  String? ffmpegFilters() {
    if (isNeutral) return null;
    final parts = <String>[];
    if (pitch != 0) {
      final k = pitchFactor;
      // Play faster (higher), back to 48 kHz, then slow back down keeping
      // the new pitch.
      parts.addAll([
        'asetrate=${(48000 * k).toStringAsFixed(3)}',
        'aresample=48000',
        'atempo=${(1 / k).toStringAsFixed(6)}',
      ]);
    }
    for (var i = 0; i < eq.length; i++) {
      if (eq[i].abs() <= 0.05) continue;
      parts.add(
        'equalizer=f=${eqFrequencies[i].toStringAsFixed(0)}:t=q:'
        'w=${eqQ.toStringAsFixed(2)}:g=${eq[i].toStringAsFixed(2)}',
      );
    }
    for (final taps in [delayTaps, reverbTaps]) {
      if (taps.isEmpty) continue;
      parts.add(
        'aecho=1:1:${taps.map((t) => t.ms.toStringAsFixed(1)).join('|')}:'
        '${taps.map((t) => t.gain.toStringAsFixed(4)).join('|')}',
      );
    }
    return parts.join(',');
  }

  /// For Android's audio processor: pitch factor, equalizer bands
  /// [frequency, Q, gain dB] and echo taps [ms, gain] (delay, then reverb).
  Map<String, Object?> toEngineMap() => {
    'pitch': pitchFactor,
    'eq': [
      for (var i = 0; i < eq.length; i++)
        if (eq[i].abs() > 0.05) [eqFrequencies[i], eqQ, eq[i]],
    ],
    'delayTaps': [
      for (final t in delayTaps) [t.ms, t.gain],
    ],
    'reverbTaps': [
      for (final t in reverbTaps) [t.ms, t.gain],
    ],
  };

  /// The equalizer's effect at [hz], in dB (for drawing its curve): the
  /// same peaking filters FFmpeg's "equalizer" and Android use.
  double eqResponseDb(double hz, {double sampleRate = 48000}) {
    var total = 0.0;
    for (var i = 0; i < eq.length; i++) {
      if (eq[i].abs() <= 0.05) continue;
      total += peakingResponseDb(eqFrequencies[i], eqQ, eq[i], hz, sampleRate);
    }
    return total;
  }

  @override
  bool operator ==(Object other) =>
      other is AudioFx &&
      other.pitch == pitch &&
      _listEq(other.eq, eq) &&
      other.reverb == reverb &&
      other.reverbAmount == reverbAmount &&
      other.delayMs == delayMs &&
      other.delayRepeats == delayRepeats &&
      other.delayAmount == delayAmount;

  @override
  int get hashCode => Object.hash(
    pitch,
    Object.hashAll(eq),
    reverb,
    reverbAmount,
    delayMs,
    delayRepeats,
    delayAmount,
  );

  /// True if two sets of equalizer gains are the same.
  static bool sameGains(List<double> a, List<double> b) => _listEq(a, b);

  static bool _listEq(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    if (pitch != 0) 'pitch': pitch,
    if (hasEq) 'eq': eq,
    if (reverb != null) 'reverb': reverb!.name,
    'reverbAmount': reverbAmount,
    if (delayMs != null) 'delayMs': delayMs,
    'delayRepeats': delayRepeats,
    'delayAmount': delayAmount,
  };

  static AudioFx? fromJson(Object? json) {
    if (json is! Map) return null;
    final eq = [
      for (final g in json['eq'] as List? ?? const [0, 0, 0, 0, 0, 0, 0])
        (g as num).toDouble().clamp(-12.0, 12.0),
    ];
    return AudioFx(
      pitch: ((json['pitch'] as num?)?.toInt() ?? 0).clamp(-12, 12),
      eq: eq.length == eqFrequencies.length ? eq : AudioFx.none.eq,
      reverb: ReverbKind.values.asNameMap()[json['reverb']],
      reverbAmount: ((json['reverbAmount'] as num?)?.toDouble() ?? 0.35).clamp(
        0.0,
        1.0,
      ),
      delayMs: (json['delayMs'] as num?)?.toDouble(),
      delayRepeats: ((json['delayRepeats'] as num?)?.toDouble() ?? 0.4).clamp(
        0.1,
        0.8,
      ),
      delayAmount: ((json['delayAmount'] as num?)?.toDouble() ?? 0.4).clamp(
        0.0,
        1.0,
      ),
    );
  }
}

/// Coefficients of a peaking equalizer band (the "Audio EQ Cookbook"
/// formulas, as in FFmpeg's equalizer): b0, b1, b2, a0, a1, a2.
List<double> peakingCoefficients(
  double freq,
  double q,
  double gainDb,
  double sampleRate,
) {
  final a = math.pow(10, gainDb / 40).toDouble();
  final w0 = 2 * math.pi * freq / sampleRate;
  final alpha = math.sin(w0) / (2 * q);
  final cosw = math.cos(w0);
  return [
    1 + alpha * a,
    -2 * cosw,
    1 - alpha * a,
    1 + alpha / a,
    -2 * cosw,
    1 - alpha / a,
  ];
}

/// How much one peaking band changes the level at [hz], in dB.
double peakingResponseDb(
  double freq,
  double q,
  double gainDb,
  double hz,
  double sampleRate,
) {
  final c = peakingCoefficients(freq, q, gainDb, sampleRate);
  final w = 2 * math.pi * hz / sampleRate;
  // |H(e^jw)| for H = (b0 + b1 z^-1 + b2 z^-2) / (a0 + a1 z^-1 + a2 z^-2).
  double mag(double c0, double c1, double c2) {
    final re = c0 + c1 * math.cos(w) + c2 * math.cos(2 * w);
    final im = -c1 * math.sin(w) - c2 * math.sin(2 * w);
    return math.sqrt(re * re + im * im);
  }

  final h = mag(c[0], c[1], c[2]) / mag(c[3], c[4], c[5]);
  return 20 * math.log(h) / math.ln10;
}
