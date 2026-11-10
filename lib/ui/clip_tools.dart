import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';
import '../model/timecode.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// A tool panel (below the video) whose changes are shown live and become
/// a single undo step when it closes.
Future<void> _liveSheet(
  BuildContext context,
  EditorController c,
  String title,
  Widget Function(BuildContext context) builder,
) async {
  await showToolPanel(
    context,
    title: title,
    builder: (context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) => builder(context),
    ),
  );
  c.endLiveEdit();
}

// -----------------------------------------------------------------------------
// Speed
// -----------------------------------------------------------------------------

Future<void> showSpeedSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  // The slider works on a doubling scale: the middle is 1×.
  double toSlider(double speed) => math.log(speed) / math.ln2;
  double fromSlider(double v) => math.pow(2, v).toDouble();
  const presets = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0];

  return _liveSheet(context, c, 'Speed', (context) {
    final clip = c.project.placementOf(id)?.clip;
    if (clip == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    String label(double s) =>
        s == s.roundToDouble() ? '${s.toStringAsFixed(0)}×' : '$s×';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Speed', style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(
              '${clip.speed.toStringAsFixed(2)}× · '
              '${formatShortDuration(clip.durationUs)}',
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        Slider(
          min: toSlider(Clip.minSpeed),
          max: toSlider(Clip.maxSpeed),
          value: toSlider(clip.speed),
          onChanged: (v) {
            // Snap gently to round values.
            var s = fromSlider(v);
            for (final p in presets) {
              if ((s - p).abs() / p < 0.04) s = p;
            }
            c.liveEdit((base) => base.setSpeed(id, s));
          },
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in presets)
              ChoiceChip(
                label: Text(label(p)),
                selected: (clip.speed - p).abs() < 0.001,
                onSelected: (_) => c.liveEdit((base) => base.setSpeed(id, p)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Sound keeps its normal pitch. Smooth slow motion (made-up '
          'in-between frames) arrives in Stage 7.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  });
}

// -----------------------------------------------------------------------------
// Opacity
// -----------------------------------------------------------------------------

Future<void> showOpacitySheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  return _liveSheet(context, c, 'Opacity', (context) {
    final clip = c.project.placementOf(id)?.clip;
    if (clip == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Opacity', style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(
              '${(clip.opacity * 100).round()}%',
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        Slider(
          value: clip.opacity,
          divisions: 100,
          onChanged: (v) => c.liveEdit(
            (base) => base.updateClip(id, (x) => x.copyWith(opacity: v)),
          ),
        ),
        Text(
          'Lower values let the background show through.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  });
}

// -----------------------------------------------------------------------------
// Background
// -----------------------------------------------------------------------------

const backgroundColors = <int>[
  0xFF000000,
  0xFFFFFFFF,
  0xFF424242,
  0xFF1E88E5,
  0xFF43A047,
  0xFFFDD835,
  0xFFFB8C00,
  0xFFE53935,
  0xFF8E24AA,
  0xFFF8BBD0,
];

Future<void> showBackgroundSheet(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
) {
  return showToolPanel(
    context,
    title: 'Background',
    builder: (context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final current = c.project.background;
        final theme = Theme.of(context);
        final allowed = engine.supportsBackgrounds;
        Widget swatch(BackgroundFill fill, Widget child, String tooltip) {
          final selected = current == fill;
          final enabled = allowed || fill.isPlainBlack;
          return Tooltip(
            message: tooltip,
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: enabled ? () => c.setBackground(fill) : null,
              child: Opacity(
                opacity: enabled ? 1 : 0.3,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : Colors.white24,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: ClipOval(child: child),
                ),
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Background', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Fills the space around videos that don\'t match the canvas '
              'shape, and shows through when opacity is lowered.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                swatch(
                  const BackgroundFill.blur(),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF4DB6AC), Color(0xFF7986CB)],
                      ),
                    ),
                    child: Center(
                      child: Icon(Icons.blur_on, color: Colors.white),
                    ),
                  ),
                  'Blurred video',
                ),
                for (final color in backgroundColors)
                  swatch(
                    BackgroundFill.color(color),
                    ColoredBox(color: Color(color)),
                    color == 0xFF000000 ? 'Black' : 'Color',
                  ),
              ],
            ),
            if (!allowed) ...[
              const SizedBox(height: 12),
              Text(
                'Colored and blurred backgrounds aren\'t available on '
                'Android yet (they need custom work beyond Google\'s video '
                'tools). They already work on Windows.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        );
      },
    ),
  );
}

// -----------------------------------------------------------------------------
// Crop
// -----------------------------------------------------------------------------

/// Full-screen crop editor: drag the corners or edges, or drag inside to
/// move. Optional fixed shapes.
class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.clip,
    required this.frame,
    required this.canvas,
  });

  final Clip clip;

  /// A picture of the current frame (before turning/mirroring), or null.
  final File? frame;
  final CanvasRatio canvas;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

enum _Handle { none, move, tl, tr, bl, br, l, r, t, b }

class _CropScreenState extends State<CropScreen> {
  late CropRect _rect = widget.clip.crop;
  double? _ratio; // width / height of the crop, null = free
  _Handle _active = _Handle.none;

  /// Shape of the turned picture.
  double get _pictureAspect {
    final m = widget.clip.media;
    if (m == null || m.height == 0) return 16 / 9;
    final w = widget.clip.rotation.isOdd ? m.height : m.width;
    final h = widget.clip.rotation.isOdd ? m.width : m.height;
    return w / h;
  }

  void _setRatio(double? ratio) {
    setState(() {
      _ratio = ratio;
      if (ratio == null) return;
      // Largest centred rectangle of that shape.
      final pa = _pictureAspect;
      var w = 1.0, h = pa / ratio;
      if (h > 1) {
        h = 1;
        w = ratio / pa;
      }
      _rect = CropRect((1 - w) / 2, (1 - h) / 2, (1 + w) / 2, (1 + h) / 2);
    });
  }

  _Handle _hit(Offset p, Size s) {
    final r = Rect.fromLTRB(
      _rect.left * s.width,
      _rect.top * s.height,
      _rect.right * s.width,
      _rect.bottom * s.height,
    );
    const grab = 28.0;
    bool near(Offset a) => (a - p).distance < grab;
    if (near(r.topLeft)) return _Handle.tl;
    if (near(r.topRight)) return _Handle.tr;
    if (near(r.bottomLeft)) return _Handle.bl;
    if (near(r.bottomRight)) return _Handle.br;
    if ((p.dx - r.left).abs() < grab / 2 && p.dy > r.top && p.dy < r.bottom) {
      return _Handle.l;
    }
    if ((p.dx - r.right).abs() < grab / 2 && p.dy > r.top && p.dy < r.bottom) {
      return _Handle.r;
    }
    if ((p.dy - r.top).abs() < grab / 2 && p.dx > r.left && p.dx < r.right) {
      return _Handle.t;
    }
    if ((p.dy - r.bottom).abs() < grab / 2 && p.dx > r.left && p.dx < r.right) {
      return _Handle.b;
    }
    if (r.contains(p)) return _Handle.move;
    return _Handle.none;
  }

  void _drag(Offset delta, Size s) {
    final dx = delta.dx / s.width, dy = delta.dy / s.height;
    var l = _rect.left, t = _rect.top, r = _rect.right, b = _rect.bottom;
    switch (_active) {
      case _Handle.move:
        final w = r - l, h = b - t;
        l = (l + dx).clamp(0.0, 1.0 - w);
        t = (t + dy).clamp(0.0, 1.0 - h);
        r = l + w;
        b = t + h;
      case _Handle.tl:
        l += dx;
        t += dy;
      case _Handle.tr:
        r += dx;
        t += dy;
      case _Handle.bl:
        l += dx;
        b += dy;
      case _Handle.br:
        r += dx;
        b += dy;
      case _Handle.l:
        l += dx;
      case _Handle.r:
        r += dx;
      case _Handle.t:
        t += dy;
      case _Handle.b:
        b += dy;
      case _Handle.none:
        return;
    }
    var next = CropRect(l, t, r, b).normalized();
    final ratio = _ratio;
    if (ratio != null && _active != _Handle.move) {
      // Keep the chosen shape: height follows width (in picture terms).
      final pa = _pictureAspect;
      final wantH = next.width * pa / ratio;
      final anchoredTop =
          _active == _Handle.b ||
          _active == _Handle.bl ||
          _active == _Handle.br ||
          _active == _Handle.l ||
          _active == _Handle.r;
      next = anchoredTop
          ? CropRect(next.left, next.top, next.right, next.top + wantH)
          : CropRect(next.left, next.bottom - wantH, next.right, next.bottom);
      if (next.top < 0 || next.bottom > 1) return; // would leave the picture
    }
    setState(() => _rect = next.normalized());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clip = widget.clip;
    final presets = <(String, double?)>[
      ('Free', null),
      ('Canvas', widget.canvas.value),
      ('16:9', 16 / 9),
      ('9:16', 9 / 16),
      ('1:1', 1),
      ('4:5', 4 / 5),
      ('4:3', 4 / 3),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Crop'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _rect = CropRect.full;
              _ratio = null;
            }),
            child: const Text('Reset'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: () => Navigator.pop(context, _rect),
              child: const Text('Apply'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _pictureAspect,
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final size = box.biggest;
                        return GestureDetector(
                          onPanStart: (d) =>
                              _active = _hit(d.localPosition, size),
                          onPanUpdate: (d) => _drag(d.delta, size),
                          onPanEnd: (_) => _active = _Handle.none,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _turnedPicture(clip),
                              CustomPaint(
                                painter: _CropPainter(
                                  _rect,
                                  theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final (label, ratio) in presets)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: _ratio == ratio,
                        onSelected: (_) => _setRatio(ratio),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _turnedPicture(Clip clip) {
    final frame = widget.frame;
    final Widget image = frame == null
        ? const ColoredBox(
            color: Color(0xFF263238),
            child: Center(
              child: Icon(Icons.image_outlined, color: Colors.white38),
            ),
          )
        : Image.file(frame, fit: BoxFit.fill, gaplessPlayback: true);
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        clip.flipH ? -1 : 1,
        clip.flipV ? -1 : 1,
        1,
      ),
      child: RotatedBox(quarterTurns: clip.rotation, child: image),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect, this.color);

  final CropRect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.6);
    final full = Offset.zero & size;
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(full),
        Path()..addRect(r),
      ),
      shade,
    );
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), line);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), line);
    }
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final corner = Paint()
      ..color = color
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const len = 18.0;
    for (final (p, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(p, p + Offset(len * dx, 0), corner);
      canvas.drawLine(p, p + Offset(0, len * dy), corner);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}

// -----------------------------------------------------------------------------
// Volume
// -----------------------------------------------------------------------------

Future<void> showVolumeSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  return _liveSheet(context, c, 'Volume', (context) {
    final clip = c.project.placementOf(id)?.clip;
    if (clip == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    void set(double v) =>
        c.liveEdit((base) => base.updateClip(id, (x) => x.copyWith(volume: v)));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Volume', style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(
              clip.volume == 0 ? 'Muted' : '${(clip.volume * 100).round()}%',
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: clip.volume == 0 ? 'Unmute' : 'Mute',
              icon: Icon(clip.volume == 0 ? Icons.volume_off : Icons.volume_up),
              onPressed: () => set(clip.volume == 0 ? 1 : 0),
            ),
            Expanded(
              child: Slider(
                max: Clip.maxVolume,
                divisions: 40,
                value: clip.volume,
                onChanged: set,
              ),
            ),
          ],
        ),
        Text(
          'Tip: to lower music under speech, split the music clip where the '
          'speech starts and ends, and turn down the middle piece. Over 100% '
          'is heard in the export (the preview tops out at 100%).',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  });
}

// -----------------------------------------------------------------------------
// Fade
// -----------------------------------------------------------------------------

Future<void> showFadeSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  return _liveSheet(context, c, 'Fade', (context) {
    final clip = c.project.placementOf(id)?.clip;
    if (clip == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final maxUs = math.min(10 * usPerSecond, clip.durationUs);
    String secs(int us) => '${(us / usPerSecond).toStringAsFixed(1)} s';
    Widget row(String label, int value, void Function(int) onChanged) => Row(
      children: [
        SizedBox(width: 72, child: Text(label)),
        Expanded(
          child: Slider(
            max: maxUs.toDouble(),
            value: value.clamp(0, maxUs).toDouble(),
            onChanged: (v) {
              // Tenths of a second.
              onChanged(((v / 100000).round()) * 100000);
            },
          ),
        ),
        SizedBox(width: 56, child: Text(secs(value), textAlign: TextAlign.end)),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Fade', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        row(
          'Fade in',
          clip.fadeInUs,
          (v) => c.liveEdit(
            (b) => b.updateClip(id, (x) => x.copyWith(fadeInUs: v)),
          ),
        ),
        row(
          'Fade out',
          clip.fadeOutUs,
          (v) => c.liveEdit(
            (b) => b.updateClip(id, (x) => x.copyWith(fadeOutUs: v)),
          ),
        ),
        Text(
          'The sound rises from silence at the start and sinks to silence '
          'at the end. Up to 10 seconds each.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  });
}
