import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Where a dragged item (text or picture-in-picture) lands after snapping,
/// and which guide lines to show (as fractions of the frame: 0 = left/top
/// edge, 0.5 = centre, 1 = right/bottom edge).
typedef FrameSnap = ({double x, double y, double? guideX, double? guideY});

/// Snaps an item centred at ([x], [y]) (fractions of the frame) whose
/// picture is [size] pixels, turned by [angle] radians, in a frame of
/// [box] pixels: its centre to the frame's centre lines, or its outer edges
/// to the frame's edges, when within [reach] pixels.
FrameSnap snapInFrame(
  double x,
  double y,
  Size size,
  double angle,
  Size box, {
  double reach = 10,
}) {
  // Half the width and height of the turned item's outline.
  final c = math.cos(angle).abs(), s = math.sin(angle).abs();
  final hw = (size.width * c + size.height * s) / 2;
  final hh = (size.width * s + size.height * c) / 2;

  (double, double?) axis(double v, double half, double length) {
    if (length <= 0) return (v, null);
    final h = half / length;
    double? guide;
    var best = v;
    var gap = reach / length;
    for (final (target, lineAt) in [
      (0.5, 0.5), // centre on the centre line
      (h, 0.0), // first edge on the left/top edge
      (1 - h, 1.0), // far edge on the right/bottom edge
    ]) {
      final d = (v - target).abs();
      if (d < gap) {
        gap = d;
        best = target;
        guide = lineAt;
      }
    }
    return (best, guide);
  }

  final (nx, gx) = axis(x, hw, box.width);
  final (ny, gy) = axis(y, hh, box.height);
  return (x: nx, y: ny, guideX: gx, guideY: gy);
}

/// Draws the guide lines of a [FrameSnap].
void paintSnapGuides(
  Canvas canvas,
  Size size,
  double? guideX,
  double? guideY,
  Color color,
) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = 3;
  if (guideX != null) {
    // Kept just inside the frame so edge lines show.
    final x = (guideX * size.width).clamp(1.5, size.width - 1.5);
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
  }
  if (guideY != null) {
    final y = (guideY * size.height).clamp(1.5, size.height - 1.5);
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
}
