import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/project.dart';
import 'editor_controller.dart';
import 'frame_snap.dart';
import 'pip_view.dart';
import 'text_render.dart';

/// Draws the text overlays on top of the preview, exactly as the export will
/// (same drawing code, same animation formulas), and lets you place them:
/// tap to select, drag to move, pinch to resize and twist, double-tap to
/// edit.
class TextOverlayView extends StatefulWidget {
  const TextOverlayView({
    super.key,
    required this.controller,
    required this.onEditText,
    this.below,
  });

  final EditorController controller;

  /// Picture-in-picture moving, for touches that miss every text.
  final PipGestures? below;

  /// Opens the text editor for a text clip.
  final void Function(int clipId) onEditText;

  @override
  State<TextOverlayView> createState() => _TextOverlayViewState();
}

class _TextOverlayViewState extends State<TextOverlayView> {
  EditorController get c => widget.controller;

  int? _dragId;

  /// The current drag is moving a picture-in-picture clip.
  bool _belowDrag = false;
  double _startScale = 1;
  double _startRotation = 0;
  Offset _startPos = Offset.zero;
  Offset _focalStart = Offset.zero;

  /// Guide lines currently snapped to (shown while dragging): centre lines
  /// or frame edges, as fractions of the frame.
  double? _snapX;
  double? _snapY;

  /// The text under [pos] (top-most first), if any.
  ClipPlacement? _hit(Offset pos, Size box) {
    final texts = c.project.textsAt(c.playheadUs).reversed;
    for (final p in texts) {
      final s = p.clip.text!;
      final block = textBlockSize(s, box.height);
      final center = Offset(s.x * box.width, s.y * box.height);
      // Undo the text's tilt, then check the (unrotated) block.
      final a = -s.rotation * math.pi / 180;
      final d = pos - center;
      final local = Offset(
        d.dx * math.cos(a) - d.dy * math.sin(a),
        d.dx * math.sin(a) + d.dy * math.cos(a),
      );
      const slop = 16.0;
      if (local.dx.abs() <= block.width / 2 + slop &&
          local.dy.abs() <= block.height / 2 + slop) {
        return p;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        return ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final texts = c.project.textsAt(c.playheadUs);
            final selected = c.selected;
            final painter = CustomPaint(
              size: box,
              painter: _TextsPainter(
                texts: texts,
                playheadUs: c.playheadUs,
                selectedId: selected?.clip.kind == ClipKind.text
                    ? selected!.clip.id
                    : null,
                accent: Theme.of(context).colorScheme.primary,
                guideX: _dragId == null ? null : _snapX,
                guideY: _dragId == null ? null : _snapY,
              ),
            );
            if (c.project.textTracks.isEmpty) {
              return IgnorePointer(child: painter);
            }
            return GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onTapUp: (d) {
                final hit = _hit(d.localPosition, box);
                if (hit != null) {
                  c.pause();
                  c.select(hit.clip.id);
                } else if (widget.below?.tap(d.localPosition, box) ?? false) {
                  // A picture-in-picture clip was tapped.
                } else if (c.selected?.clip.kind == ClipKind.text) {
                  c.select(null);
                }
              },
              onDoubleTapDown: (d) {
                final hit = _hit(d.localPosition, box);
                if (hit != null) widget.onEditText(hit.clip.id);
              },
              onScaleStart: (d) {
                final hit = _hit(d.localFocalPoint, box);
                _belowDrag = false;
                if (hit == null) {
                  _dragId = null;
                  _belowDrag = widget.below?.scaleStart(d, box) ?? false;
                  return;
                }
                c.pause();
                c.select(hit.clip.id);
                final s = hit.clip.text!;
                _dragId = hit.clip.id;
                _startScale = s.scale;
                _startRotation = s.rotation;
                _startPos = Offset(s.x, s.y);
                _focalStart = d.localFocalPoint;
              },
              onScaleUpdate: (d) {
                if (_belowDrag) {
                  widget.below!.scaleUpdate(d, box);
                  return;
                }
                final id = _dragId;
                if (id == null) return;
                final move = d.localFocalPoint - _focalStart;
                // Straight text snaps level too (within 3°).
                var rot = _startRotation + d.rotation * 180 / math.pi;
                if (rot.abs() < 3) rot = 0;
                // Snap to the centre lines and the frame's edges.
                final spec = c.project.placementOf(id)?.clip.text;
                final block = spec == null
                    ? Size.zero
                    : textBlockSize(
                        spec.copyWith(scale: _startScale * d.scale),
                        box.height,
                      );
                final snap = snapInFrame(
                  _startPos.dx + move.dx / box.width,
                  _startPos.dy + move.dy / box.height,
                  block,
                  rot * math.pi / 180,
                  box,
                );
                final nx = snap.x, ny = snap.y;
                if ((snap.guideX != null && snap.guideX != _snapX) ||
                    (snap.guideY != null && snap.guideY != _snapY)) {
                  HapticFeedback.selectionClick();
                }
                if (snap.guideX != _snapX || snap.guideY != _snapY) {
                  setState(() {
                    _snapX = snap.guideX;
                    _snapY = snap.guideY;
                  });
                }
                c.liveEdit(
                  (base) => base.updateClip(
                    id,
                    (x) => x.copyWith(
                      text: x.text!.copyWith(
                        x: nx,
                        y: ny,
                        scale: _startScale * d.scale,
                        rotation: rot,
                      ),
                    ),
                  ),
                );
              },
              onScaleEnd: (_) {
                if (_belowDrag) {
                  _belowDrag = false;
                  widget.below!.scaleEnd();
                  return;
                }
                if (_dragId != null) c.endLiveEdit();
                _dragId = null;
                if (_snapX != null || _snapY != null) {
                  setState(() {
                    _snapX = null;
                    _snapY = null;
                  });
                }
              },
              // A transparent layer so empty areas can still be tapped to
              // unselect a text.
              child: ColoredBox(color: Colors.transparent, child: painter),
            );
          },
        );
      },
    );
  }
}

class _TextsPainter extends CustomPainter {
  _TextsPainter({
    required this.texts,
    required this.playheadUs,
    required this.selectedId,
    required this.accent,
    this.guideX,
    this.guideY,
  });

  /// Guide lines to draw (text is snapped to them), as frame fractions.
  final double? guideX;
  final double? guideY;

  final List<ClipPlacement> texts;
  final int playheadUs;
  final int? selectedId;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    paintSnapGuides(canvas, size, guideX, guideY, accent);
    for (final p in texts) {
      final s = p.clip.text!;
      final f = textFrameAt(s, playheadUs - p.startUs, p.clip.durationUs);
      final center = Offset(
        (s.x + f.dx) * size.width,
        (s.y + f.dy) * size.height,
      );
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(f.scale);
      if (f.alpha < 0.999) {
        canvas.saveLayer(
          null,
          Paint()..color = Colors.white.withValues(alpha: f.alpha),
        );
      }
      paintText(canvas, s, size.height, visibleChars: f.visibleChars);
      if (f.alpha < 0.999) canvas.restore();
      canvas.restore();

      if (p.clip.id == selectedId) {
        // Dashed-look frame around the selected text.
        final block = textBlockSize(s, size.height);
        canvas.save();
        canvas.translate(s.x * size.width, s.y * size.height);
        canvas.rotate(s.rotation * math.pi / 180);
        final r = Rect.fromCenter(
          center: Offset.zero,
          width: block.width + 8,
          height: block.height + 8,
        );
        canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = accent,
        );
        for (final corner in [
          r.topLeft,
          r.topRight,
          r.bottomLeft,
          r.bottomRight,
        ]) {
          canvas.drawCircle(corner, 4, Paint()..color = accent);
        }
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_TextsPainter old) => true;
}
