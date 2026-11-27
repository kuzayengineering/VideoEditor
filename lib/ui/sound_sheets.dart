import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// Opens one of the sound-effect panels for the selected clip. Changes are
/// heard live and become one undo step per gesture.
Future<void> _soundPanel(
  BuildContext context,
  EditorController c,
  String title,
  Widget Function(BuildContext context, AudioFx fx, _FxEdit edit) builder, {
  bool scrollable = true,
}) async {
  final id = c.selectedClipId;
  if (id == null) return;
  await showToolPanel(
    context,
    title: title,
    scrollable: scrollable,
    builder: (context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final clip = c.project.placementOf(id)?.clip;
        if (clip == null) return const SizedBox.shrink();
        return builder(context, clip.audioFx ?? AudioFx.none, _FxEdit(c, id));
      },
    ),
  );
  c.endLiveEdit();
}

/// Changes the clip's sound effects (live while a slider moves).
class _FxEdit {
  _FxEdit(this.c, this.id);

  final EditorController c;
  final int id;

  void live(AudioFx Function(AudioFx fx) change) => c.liveEdit(
    (b) => b.updateClip(
      id,
      (x) => x.copyWith(audioFx: change(x.audioFx ?? AudioFx.none)),
    ),
  );

  void now(AudioFx Function(AudioFx fx) change) {
    c.endLiveEdit();
    c.apply(
      c.project.updateClip(
        id,
        (x) => x.copyWith(audioFx: change(x.audioFx ?? AudioFx.none)),
      ),
    );
  }

  void done() => c.endLiveEdit();
}

Widget _note(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(top: 6),
  child: Text(text, style: Theme.of(context).textTheme.bodySmall),
);

Widget _slider(
  BuildContext context,
  String label,
  double value,
  double min,
  double max,
  String shown,
  ValueChanged<double> onChanged,
  VoidCallback onEnd, {
  int? divisions,
}) => Row(
  children: [
    SizedBox(width: 72, child: Text(label)),
    Expanded(
      child: Slider(
        min: min,
        max: max,
        divisions: divisions,
        value: value.clamp(min, max),
        onChanged: onChanged,
        onChangeEnd: (_) => onEnd(),
      ),
    ),
    SizedBox(width: 64, child: Text(shown, textAlign: TextAlign.end)),
  ],
);

// -----------------------------------------------------------------------------
// Pitch
// -----------------------------------------------------------------------------

Future<void> showPitchSheet(BuildContext context, EditorController c) =>
    _soundPanel(context, c, 'Pitch', (context, fx, edit) {
      String label(int s) => s == 0
          ? 'Normal'
          : '${s > 0 ? '+' : ''}$s semitone${s.abs() == 1 ? '' : 's'}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _slider(
            context,
            'Pitch',
            fx.pitch.toDouble(),
            -12,
            12,
            fx.pitch == 0 ? 'Normal' : '${fx.pitch > 0 ? '+' : ''}${fx.pitch}',
            (v) => edit.live((f) => f.copyWith(pitch: v.round())),
            edit.done,
            divisions: 24,
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final s in const [-12, -5, -2, 0, 2, 5, 12])
                ChoiceChip(
                  label: Text(s == 0 ? 'Normal' : '${s > 0 ? '+' : ''}$s'),
                  selected: fx.pitch == s,
                  onSelected: (_) => edit.now((f) => f.copyWith(pitch: s)),
                ),
            ],
          ),
          SameSourceButton(
            c: c,
            clipId: edit.id,
            what: 'pitch',
            copy: (p, target, from) => p.updateClip(
              target,
              (x) => x.copyWith(
                audioFx: (x.audioFx ?? AudioFx.none).copyWith(
                  pitch: (from.audioFx ?? AudioFx.none).pitch,
                ),
              ),
            ),
          ),
          _note(
            context,
            '${label(fx.pitch)}. The speed stays the same. 12 semitones is '
            'one octave (twice or half the pitch).',
          ),
        ],
      );
    });

// -----------------------------------------------------------------------------
// Equalizer
// -----------------------------------------------------------------------------

Future<void> showEqualizerSheet(BuildContext context, EditorController c) =>
    _soundPanel(
      context,
      c,
      'Equalizer',
      scrollable: false,
      (context, fx, edit) => _EqualizerPanel(fx: fx, edit: edit),
    );

class _EqualizerPanel extends StatefulWidget {
  const _EqualizerPanel({required this.fx, required this.edit});

  final AudioFx fx;
  final _FxEdit edit;

  @override
  State<_EqualizerPanel> createState() => _EqualizerPanelState();
}

class _EqualizerPanelState extends State<_EqualizerPanel> {
  int? _band;

  static const _minHz = 20.0, _maxHz = 20000.0, _range = 12.0;

  double _xOf(double hz, double w) =>
      w * (math.log(hz / _minHz) / math.log(_maxHz / _minHz)).clamp(0.0, 1.0);

  double _yOf(double db, double h) => h / 2 - db / _range * (h / 2 - 8);

  double _dbAt(double y, double h) =>
      ((h / 2 - y) / (h / 2 - 8) * _range).clamp(-_range, _range);

  void _drag(Offset pos, Size size) {
    final band = _band;
    if (band == null) return;
    var db = _dbAt(pos.dy, size.height);
    if (db.abs() < 0.6) db = 0; // easy to find "no change"
    db = (db * 2).round() / 2; // half-dB steps
    final gains = [...widget.fx.eq];
    gains[band] = db;
    widget.edit.live((f) => f.copyWith(eq: gains));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fx = widget.fx;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: LayoutBuilder(
              builder: (context, box) {
                final size = box.biggest;
                return GestureDetector(
                  onPanStart: (d) {
                    // The band nearest the finger (left to right).
                    var best = 0;
                    var bestDx = double.infinity;
                    for (var i = 0; i < AudioFx.eqFrequencies.length; i++) {
                      final dx =
                          (_xOf(AudioFx.eqFrequencies[i], size.width) -
                                  d.localPosition.dx)
                              .abs();
                      if (dx < bestDx) {
                        bestDx = dx;
                        best = i;
                      }
                    }
                    setState(() => _band = best);
                    _drag(d.localPosition, size);
                  },
                  onPanUpdate: (d) => _drag(d.localPosition, size),
                  onPanEnd: (_) {
                    setState(() => _band = null);
                    widget.edit.done();
                  },
                  child: CustomPaint(
                    size: size,
                    painter: _EqPainter(
                      fx: fx,
                      active: _band,
                      color: theme.colorScheme.primary,
                      grid: theme.colorScheme.onSurface.withValues(alpha: 0.15),
                      label: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      xOf: _xOf,
                      yOf: _yOf,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final p in EqPreset.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.label),
                    selected: AudioFx.sameGains(fx.eq, p.gains),
                    onSelected: (_) =>
                        widget.edit.now((f) => f.copyWith(eq: p.gains)),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Drag a point up or down to boost or cut that range of sound.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({
    required this.fx,
    required this.active,
    required this.color,
    required this.grid,
    required this.label,
    required this.xOf,
    required this.yOf,
  });

  final AudioFx fx;
  final int? active;
  final Color color;
  final Color grid;
  final Color label;
  final double Function(double hz, double w) xOf;
  final double Function(double db, double h) yOf;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final db in const [-12.0, -6.0, 0.0, 6.0, 12.0]) {
      final y = yOf(db, h);
      canvas.drawLine(Offset(0, y), Offset(w, y), line);
    }
    void text(String s, Offset at) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(color: label, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at);
    }

    text('+12 dB', Offset(w - 38, yOf(12, h) + 2));
    text('−12 dB', Offset(w - 38, yOf(-12, h) - 14));
    // The curve (exact response of the bands together).
    final path = Path();
    const steps = 160;
    for (var i = 0; i <= steps; i++) {
      final hz = 20 * math.pow(1000, i / steps).toDouble();
      final x = xOf(hz, w);
      final y = yOf(fx.eqResponseDb(hz).clamp(-14.0, 14.0), h);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(w, yOf(0, h))
      ..lineTo(0, yOf(0, h))
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.15));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < AudioFx.eqFrequencies.length; i++) {
      final f = AudioFx.eqFrequencies[i];
      final x = xOf(f, w), y = yOf(fx.eq[i], h);
      canvas.drawCircle(
        Offset(x, y),
        i == active ? 9 : 7,
        Paint()..color = i == active ? color : Colors.white,
      );
      canvas.drawCircle(
        Offset(x, y),
        i == active ? 9 : 7,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final name = f >= 1000
          ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k'
          : f.toStringAsFixed(0);
      text(name, Offset(x - 8, h - 12));
    }
  }

  @override
  bool shouldRepaint(_EqPainter old) => old.fx != fx || old.active != active;
}

// -----------------------------------------------------------------------------
// Reverb
// -----------------------------------------------------------------------------

Future<void> showReverbSheet(BuildContext context, EditorController c) =>
    _soundPanel(context, c, 'Reverb', (context, fx, edit) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Off'),
                selected: fx.reverb == null,
                onSelected: (_) =>
                    edit.now((f) => f.copyWith(clearReverb: true)),
              ),
              for (final k in ReverbKind.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: fx.reverb == k,
                  onSelected: (_) => edit.now((f) => f.copyWith(reverb: k)),
                ),
            ],
          ),
          if (fx.reverb != null)
            _slider(
              context,
              'Amount',
              fx.reverbAmount,
              0,
              1,
              '${(fx.reverbAmount * 100).round()}%',
              (v) => edit.live((f) => f.copyWith(reverbAmount: v)),
              edit.done,
            ),
          _note(
            context,
            'Makes the sound seem to be in a bigger space: a room, a hall, '
            'a church or a cave.',
          ),
        ],
      );
    });

// -----------------------------------------------------------------------------
// Delay
// -----------------------------------------------------------------------------

Future<void> showDelaySheet(BuildContext context, EditorController c) =>
    _soundPanel(context, c, 'Delay', (context, fx, edit) {
      final presets = <(String, double?)>[
        ('Off', null),
        ('Slapback', 120),
        ('Echo', 300),
        ('Long echo', 600),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (name, ms) in presets)
                ChoiceChip(
                  label: Text(name),
                  selected: fx.delayMs == ms,
                  onSelected: (_) => edit.now(
                    (f) => ms == null
                        ? f.copyWith(clearDelay: true)
                        : f.copyWith(delayMs: ms),
                  ),
                ),
            ],
          ),
          if (fx.delayMs != null) ...[
            _slider(
              context,
              'Time',
              fx.delayMs!,
              50,
              1000,
              '${fx.delayMs!.round()} ms',
              (v) => edit.live((f) => f.copyWith(delayMs: v.roundToDouble())),
              edit.done,
            ),
            _slider(
              context,
              'Repeats',
              fx.delayRepeats,
              0.1,
              0.8,
              '${(fx.delayRepeats * 100).round()}%',
              (v) => edit.live((f) => f.copyWith(delayRepeats: v)),
              edit.done,
            ),
            _slider(
              context,
              'Amount',
              fx.delayAmount,
              0,
              1,
              '${(fx.delayAmount * 100).round()}%',
              (v) => edit.live((f) => f.copyWith(delayAmount: v)),
              edit.done,
            ),
          ],
          _note(
            context,
            'Repeats the sound after a short time, fading each time.',
          ),
        ],
      );
    });

// -----------------------------------------------------------------------------
// Noise reduction
// -----------------------------------------------------------------------------

Future<void> showNoiseSheet(BuildContext context, EditorController c) =>
    _soundPanel(context, c, 'Noise reduction', (context, fx, edit) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Off'),
                selected: fx.noise == null,
                onSelected: (_) =>
                    edit.now((f) => f.copyWith(clearNoise: true)),
              ),
              for (final k in NoiseKind.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: fx.noise == k,
                  onSelected: (_) => edit.now((f) => f.copyWith(noise: k)),
                ),
            ],
          ),
          if (fx.noise != null)
            _slider(
              context,
              'Amount',
              fx.noiseAmount,
              0,
              1,
              '${(fx.noiseAmount * 100).round()}%',
              (v) => edit.live((f) => f.copyWith(noiseAmount: v)),
              edit.done,
            ),
          _note(
            context,
            fx.noise?.description ??
                'Pick the kind of noise to take out. A lighter amount keeps '
                    'voices more natural.',
          ),
        ],
      );
    });
