import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../model/project.dart';
import '../model/timecode.dart';
import 'editor_controller.dart';
import 'audio_preview.dart';
import 'reverse_jobs.dart';
import 'thumbnail_cache.dart';
import 'timeline_scale.dart';
import 'transition_sheet.dart';

/// The YouCut-style timeline: the playhead stays fixed in the middle and the
/// clips slide underneath it.
///
/// - Drag sideways to move through the video.
/// - Pinch (or Ctrl + mouse wheel) to zoom.
/// - Tap a clip to select it, then drag its white edge handles to trim.
class TimelineView extends StatefulWidget {
  const TimelineView({
    super.key,
    required this.controller,
    this.thumbnails,
    this.waveforms,
    this.onLongPressClip,
    this.reverseJobs,
    this.onTransitionTap,
  });

  /// Called when the button between main clip [index] and the next is
  /// tapped (opens the transition picker).
  final void Function(int index)? onTransitionTap;

  /// Where the transition button for the cut after main clip [index] sits.
  static double transitionButtonTime(
    Project p,
    List<ClipPlacement> main,
    int i,
  ) {
    final d = p.transitionUsAfter(i);
    return main[i + 1].startUs + d / 2;
  }

  static const transitionButtonSize = 24.0;

  /// Background reversals (their progress is shown on the clips).
  final ReverseJobs? reverseJobs;

  final EditorController controller;

  /// Called when a main-track clip is held down (opens the reorder screen).
  final void Function(int clipId)? onLongPressClip;

  /// Loudness outlines for sound clips.
  final WaveformCache? waveforms;

  /// Pictures for real video clips (null in the demo).
  final ThumbnailCache? thumbnails;

  static const rulerHeight = 22.0;
  static const mainTrackTop = 30.0;
  static const mainTrackHeight = 60.0;
  static const audioTrackHeight = 34.0;

  /// Picture-in-picture rows (with thumbnails).
  static const overlayTrackHeight = 44.0;
  static const trackGap = 8.0;
  static const handleWidth = 14.0;

  static double heightFor(Project project) =>
      mainTrackTop +
      mainTrackHeight +
      (project.audioTracks.length + project.textTracks.length) *
          (audioTrackHeight + trackGap) +
      project.overlayTracks.length * (overlayTrackHeight + trackGap) +
      trackGap * 2;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

enum _DragMode { none, pan, trimStart, trimEnd, zoom, move }

class _TimelineViewState extends State<TimelineView> {
  _DragMode _mode = _DragMode.none;
  double _dragDx = 0;
  double _zoomStart = 1;
  int _moveClipId = 0;
  int _moveStartUs = 0;
  int _trimEdgeUs = 0;

  /// The time scale while a clip is moved or trimmed: kept as it was when
  /// the drag began, so the clip follows the finger even though its own
  /// change may re-spread the scale.
  TimelineScale? _dragScale;

  TimelineScale? _scaleCache;
  Project? _scaleProject;
  double _scalePps = 0;

  /// Where moments sit on screen (short clips spread out to a square).
  TimelineScale get _scale {
    final project = c.project;
    if (_scaleCache != null &&
        identical(project, _scaleProject) &&
        _scalePps == c.pixelsPerSecond) {
      return _scaleCache!;
    }
    _scaleProject = project;
    _scalePps = c.pixelsPerSecond;
    return _scaleCache = TimelineScale(c.pixelsPerSecond, [
      for (final (track, _, height) in _lanes(project))
        for (final p in project.placementsOn(track))
          (p.startUs, p.endUs, height),
    ]);
  }

  /// The moment a moving clip's edge has snapped to (shown as a line).
  int? _snapUs;

  EditorController get c => widget.controller;

  double _xAtTime(int timeUs, double width) =>
      width / 2 + _scale.xOf(timeUs) - _scale.xOf(c.playheadUs);

  /// Where a clip moved to [rawStartUs] lands: an edge within a few pixels
  /// of another clip's start or end (on any track), the playhead or the
  /// very start snaps onto it, with a small vibration.
  int _snapped(int clipId, int rawStartUs, int durationUs) {
    final project = c.project;
    final targets = <int>{0, c.playheadUs};
    for (final track in [
      project.mainTrack,
      ...project.overlayTracks,
      ...project.audioTracks,
      ...project.textTracks,
    ]) {
      for (final p in project.placementsOn(track)) {
        if (p.clip.id == clipId) continue;
        targets
          ..add(p.startUs)
          ..add(p.endUs);
      }
    }
    // Within 10 pixels (on the time scale as it was when the drag began).
    final sc = _dragScale ?? _scale;
    const reach = 10.0;
    int? best;
    var bestStart = rawStartUs;
    var bestGap = reach + 1;
    for (final t in targets) {
      for (final (edge, start) in [
        (rawStartUs, t), // its start on the target
        (rawStartUs + durationUs, t - durationUs), // its end on the target
      ]) {
        final gap = (sc.xOf(edge) - sc.xOf(t)).abs();
        if (gap < bestGap && start >= 0) {
          bestGap = gap;
          best = t;
          bestStart = start;
        }
      }
    }
    if (best != _snapUs) {
      if (best != null) HapticFeedback.selectionClick();
      setState(() => _snapUs = best);
    }
    return best == null
        ? snapToFrame(rawStartUs, project.frameRate)
        : bestStart;
  }

  /// Drags the clip being moved: sideways by [dx] (it can pass other
  /// clips, landing in the nearest free spot) and onto the row of its kind
  /// under [y] (below the last such row: a new row).
  void _moveBy(double dx, double? y) {
    final project = c.project;
    final p = project.placementOf(_moveClipId);
    if (p == null) return;
    final target = _snapped(
      _moveClipId,
      (_dragScale ?? _scale).timeMovedBy(_moveStartUs, dx),
      p.clip.durationUs,
    );
    int? trackId;
    var newTrack = false;
    if (y != null) {
      final rows = [
        for (final lane in _lanes(project))
          if (lane.$1.kind == p.track.kind) lane,
      ];
      for (final (track, top, height) in rows) {
        if (y >= top - TimelineView.trackGap / 2 &&
            y < top + height + TimelineView.trackGap / 2) {
          trackId = track.id;
        }
      }
      if (trackId == null && rows.isNotEmpty) {
        final last = rows.last;
        if (y >= last.$2 + last.$3) {
          // Below the last row: a new one (unless it's alone on the last
          // row already).
          if (last.$1.id == p.track.id && p.track.clips.length == 1) {
            trackId = last.$1.id;
          } else {
            newTrack = true;
          }
        } else if (y < rows.first.$2) {
          trackId = rows.first.$1.id;
        }
      }
    }
    c.liveEdit(
      (now) => now.moveLayerClip(
        _moveClipId,
        target,
        trackId: trackId,
        newTrack: newTrack,
      ),
    );
  }

  void _endMove() {
    // Rows left empty by the move go (same undo step as the move).
    if (c.project.overlayTracks.any((t) => t.clips.isEmpty) ||
        c.project.audioTracks.any((t) => t.clips.isEmpty) ||
        c.project.textTracks.any((t) => t.clips.isEmpty)) {
      c.liveEdit((now) => now.withoutEmptyLayerTracks());
    }
    c.endLiveEdit();
    _dragScale = null;
    if (_snapUs != null) setState(() => _snapUs = null);
  }

  /// Vertical span of each track.
  List<(Track, double top, double height)> _lanes(Project project) {
    final lanes = <(Track, double, double)>[
      (
        project.mainTrack,
        TimelineView.mainTrackTop,
        TimelineView.mainTrackHeight,
      ),
    ];
    var y =
        TimelineView.mainTrackTop +
        TimelineView.mainTrackHeight +
        TimelineView.trackGap;
    for (final t in project.overlayTracks) {
      lanes.add((t, y, TimelineView.overlayTrackHeight));
      y += TimelineView.overlayTrackHeight + TimelineView.trackGap;
    }
    for (final t in [...project.audioTracks, ...project.textTracks]) {
      lanes.add((t, y, TimelineView.audioTrackHeight));
      y += TimelineView.audioTrackHeight + TimelineView.trackGap;
    }
    return lanes;
  }

  /// Which clip (and which part of it) is under a point.
  (ClipPlacement, _DragMode)? _hitTest(Offset pos, double width) {
    final project = c.project;
    final lanes = _lanes(project);
    bool inLane(double top, double height) =>
        pos.dy >= top - 6 && pos.dy <= top + height + 6;

    // The selected clip's trim handles stick out over its neighbours, so
    // they are checked first.
    final sel = c.selected;
    if (sel != null) {
      for (final (track, top, height) in lanes) {
        if (track.id != sel.track.id || !inLane(top, height)) continue;
        final left = _xAtTime(sel.startUs, width);
        final right = _xAtTime(sel.endUs, width);
        const grab = TimelineView.handleWidth + 10;
        if (pos.dx >= left - grab && pos.dx <= left + grab / 2) {
          return (sel, _DragMode.trimStart);
        }
        if (pos.dx >= right - grab / 2 && pos.dx <= right + grab) {
          return (sel, _DragMode.trimEnd);
        }
      }
    }

    for (final (track, top, height) in lanes) {
      if (!inLane(top, height)) continue;
      for (final p in project.placementsOn(track)) {
        final left = _xAtTime(p.startUs, width);
        final right = _xAtTime(p.endUs, width);
        if (pos.dx >= left && pos.dx < right) return (p, _DragMode.pan);
      }
    }
    return null;
  }

  void _onScaleStart(ScaleStartDetails d, double width) {
    _dragDx = 0;
    if (d.pointerCount >= 2) {
      _mode = _DragMode.zoom;
      _zoomStart = c.pixelsPerSecond;
      return;
    }
    final hit = _hitTest(d.localFocalPoint, width);
    if (hit != null &&
        (hit.$2 == _DragMode.trimStart || hit.$2 == _DragMode.trimEnd)) {
      _mode = hit.$2;
      _dragScale = _scale;
      _trimEdgeUs = hit.$2 == _DragMode.trimStart
          ? hit.$1.startUs
          : hit.$1.endUs;
      c.beginTrim(hit.$1.clip.id, start: hit.$2 == _DragMode.trimStart);
      HapticFeedback.selectionClick();
    } else if (hit != null &&
        hit.$1.clip.id == c.selectedClipId &&
        hit.$1.track.kind != TrackKind.main) {
      // Dragging a selected sound clip moves it along its track.
      _mode = _DragMode.move;
      _moveClipId = hit.$1.clip.id;
      _moveStartUs = hit.$1.startUs;
      _dragScale = _scale;
      c.pause();
      HapticFeedback.selectionClick();
    } else {
      _mode = _DragMode.pan;
      c.pause();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    switch (_mode) {
      case _DragMode.zoom:
        c.setZoom(_zoomStart * d.scale);
      case _DragMode.pan:
        if (d.pointerCount >= 2) {
          // A second finger landed mid-drag: switch to zooming.
          _mode = _DragMode.zoom;
          _zoomStart = c.pixelsPerSecond / d.scale;
          return;
        }
        c.seek(_scale.timeMovedBy(c.playheadUs, -d.focalPointDelta.dx));
      case _DragMode.trimStart:
      case _DragMode.trimEnd:
        _dragDx += d.focalPointDelta.dx;
        final sc = _dragScale ?? _scale;
        c.updateTrim(sc.timeMovedBy(_trimEdgeUs, _dragDx) - _trimEdgeUs);
      case _DragMode.move:
        _dragDx += d.focalPointDelta.dx;
        _moveBy(_dragDx, d.localFocalPoint.dy);
      case _DragMode.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_mode == _DragMode.trimStart || _mode == _DragMode.trimEnd) {
      c.endTrim();
      _dragScale = null;
    }
    if (_mode == _DragMode.pan) c.settle();
    if (_mode == _DragMode.move) _endMove();
    _mode = _DragMode.none;
  }

  void _onTapUp(TapUpDetails d, double width) {
    // The small buttons between clips come first.
    final project = c.project;
    if (widget.onTransitionTap != null && project.mainTrack.clips.length > 1) {
      final main = project.placementsOn(project.mainTrack);
      final y = TimelineView.mainTrackTop + TimelineView.mainTrackHeight / 2;
      for (var i = 0; i + 1 < main.length; i++) {
        final x = _xAtTime(
          TimelineView.transitionButtonTime(project, main, i).round(),
          width,
        );
        if ((d.localPosition - Offset(x, y)).distance <=
            TimelineView.transitionButtonSize * 0.8) {
          widget.onTransitionTap!(i);
          return;
        }
      }
    }
    final hit = _hitTest(d.localPosition, width);
    final id = hit?.$1.clip.id;
    // Tapping the selected clip again unselects it.
    c.select(id == c.selectedClipId ? null : id);
  }

  void _onLongPress(LongPressStartDetails d, double width) {
    final hit = _hitTest(d.localPosition, width);
    if (hit == null) return;
    HapticFeedback.mediumImpact();
    if (hit.$1.track.kind == TrackKind.main) {
      widget.onLongPressClip?.call(hit.$1.clip.id);
      return;
    }
    // Text, sound and picture-in-picture clips: hold, then drag to move.
    c.pause();
    c.select(hit.$1.clip.id);
    _mode = _DragMode.move;
    _moveClipId = hit.$1.clip.id;
    _moveStartUs = hit.$1.startUs;
    _dragScale = _scale;
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    if (_mode == _DragMode.move) {
      _moveBy(d.offsetFromOrigin.dx, d.localPosition.dy);
    }
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    if (_mode == _DragMode.move) _endMove();
    _mode = _DragMode.none;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final zoomKey = HardwareKeyboard.instance.isControlPressed;
    if (zoomKey) {
      c.setZoom(c.pixelsPerSecond * math.pow(0.998, e.scrollDelta.dy));
    } else {
      final delta = e.scrollDelta.dx != 0 ? e.scrollDelta.dx : e.scrollDelta.dy;
      c.pause();
      c.seek(_scale.timeMovedBy(c.playheadUs, delta), exact: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        c,
        widget.thumbnails,
        widget.waveforms,
        widget.reverseJobs,
      ]),
      builder: (context, _) {
        final height = TimelineView.heightFor(c.project);
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Listener(
              onPointerSignal: _onPointerSignal,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onTapUp(d, width),
                onLongPressStart: (d) => _onLongPress(d, width),
                onLongPressMoveUpdate: _onLongPressMove,
                onLongPressEnd: _onLongPressEnd,
                onScaleStart: (d) => _onScaleStart(d, width),
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: CustomPaint(
                    painter: _TimelinePainter(
                      project: c.project,
                      playheadUs: c.playheadUs,
                      pixelsPerSecond: c.pixelsPerSecond,
                      scale: _scale,
                      selectedClipId: c.selectedClipId,
                      snapUs: _snapUs,
                      lanes: _lanes(c.project),
                      colors: Theme.of(context).colorScheme,
                      textStyle: Theme.of(context).textTheme.labelSmall!,
                      thumbnails: widget.thumbnails,
                      waveforms: widget.waveforms,
                      reverseJobs: widget.reverseJobs,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.project,
    required this.playheadUs,
    required this.pixelsPerSecond,
    required this.scale,
    required this.selectedClipId,
    this.snapUs,
    required this.lanes,
    required this.colors,
    required this.textStyle,
    this.thumbnails,
    this.waveforms,
    this.reverseJobs,
  });

  final Project project;
  final ReverseJobs? reverseJobs;
  final int playheadUs;
  final double pixelsPerSecond;
  final TimelineScale scale;
  final int? selectedClipId;
  final int? snapUs;
  final List<(Track, double, double)> lanes;
  final ColorScheme colors;
  final TextStyle textStyle;
  final ThumbnailCache? thumbnails;
  final WaveformCache? waveforms;

  double _x(int timeUs, Size size) =>
      size.width / 2 + scale.xOf(timeUs) - scale.xOf(playheadUs);

  /// The moment at screen position [x].
  int _tAt(double x, Size size) =>
      scale.timeAt(x - size.width / 2 + scale.xOf(playheadUs));

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    _paintRuler(canvas, size);
    for (final (track, top, height) in lanes) {
      for (final p in project.placementsOn(track)) {
        _paintClip(canvas, size, p, top, height);
      }
    }
    _paintTransitionButtons(canvas, size);
    if (snapUs != null) {
      final x = _x(snapUs!, size);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = colors.tertiary
          ..strokeWidth = 1.5,
      );
    }
    _paintPlayhead(canvas, size);
  }

  /// A small square between clips: "+" to add a transition, or the
  /// transition's symbol (on a highlighted band showing the overlap).
  void _paintTransitionButtons(Canvas canvas, Size size) {
    final main = project.placementsOn(project.mainTrack);
    if (main.length < 2) return;
    final top = TimelineView.mainTrackTop;
    final height = TimelineView.mainTrackHeight;
    final cy = top + height / 2;
    const s = TimelineView.transitionButtonSize;
    for (var i = 0; i + 1 < main.length; i++) {
      final kind = main[i].clip.transition?.kind;
      final d = project.transitionUsAfter(i);
      if (d > 0) {
        final x0 = _x(main[i + 1].startUs, size);
        final x1 = _x(main[i + 1].startUs + d, size);
        canvas.drawRect(
          Rect.fromLTRB(x0, top, x1, top + height),
          Paint()..color = colors.primary.withValues(alpha: 0.25),
        );
      }
      final x = _x(
        TimelineView.transitionButtonTime(project, main, i).round(),
        size,
      );
      if (x < -s || x > size.width + s) continue;
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, cy), width: s, height: s),
        const Radius.circular(5),
      );
      canvas.drawRRect(
        r,
        Paint()..color = kind == null ? Colors.white : colors.primary,
      );
      final icon = kind == null ? Icons.add : transitionIcon(kind);
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: s * 0.7,
            color: kind == null ? Colors.black87 : colors.onPrimary,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, cy - tp.height / 2));
    }
  }

  void _paintRuler(Canvas canvas, Size size) {
    // Pick a label spacing that leaves room for the text.
    const steps = [
      0.1,
      0.25,
      0.5,
      1.0,
      2.0,
      5.0,
      10.0,
      15.0,
      30.0,
      60.0,
      120.0,
      300.0,
      600.0,
    ];
    final frameSeconds = 1 / project.frameRate;
    var step = steps.last;
    for (final s in steps) {
      if (s * pixelsPerSecond >= 70) {
        step = s;
        break;
      }
    }
    final tick = Paint()
      ..color = colors.onSurface.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final startSeconds = math.max(0.0, _tAt(0, size) / usPerSecond);
    final endSeconds = _tAt(size.width, size) / usPerSecond;

    // Frame ticks when zoomed in far enough to see individual frames.
    if (frameSeconds * pixelsPerSecond >= 6) {
      final firstFrame = (startSeconds / frameSeconds).floor();
      final lastFrame = (endSeconds / frameSeconds).ceil();
      for (var f = firstFrame; f <= lastFrame; f++) {
        final x = _x((f * frameSeconds * usPerSecond).round(), size);
        canvas.drawLine(
          Offset(x, TimelineView.rulerHeight - 4),
          Offset(x, TimelineView.rulerHeight),
          tick,
        );
      }
    }

    final first = (startSeconds / step).floor();
    final last = (endSeconds / step).ceil();
    for (var i = first; i <= last; i++) {
      final seconds = i * step;
      if (seconds < 0) continue;
      final x = _x((seconds * usPerSecond).round(), size);
      canvas.drawLine(
        Offset(x, TimelineView.rulerHeight - 9),
        Offset(x, TimelineView.rulerHeight),
        tick,
      );
      final label = step < 1
          ? '${seconds.toStringAsFixed(seconds == seconds.roundToDouble() ? 0 : 2)}s'
          : formatShortDuration((seconds * usPerSecond).round())
                .replaceAll('.0s', 's');
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: textStyle.copyWith(
            color: colors.onSurface.withValues(alpha: 0.6),
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 3, 2));
    }
  }

  void _paintClip(
    Canvas canvas,
    Size size,
    ClipPlacement p,
    double top,
    double height,
  ) {
    final left = _x(p.startUs, size);
    final right = _x(p.endUs, size);
    if (right < -40 || left > size.width + 40) return;

    final selected = p.clip.id == selectedClipId;
    final rect = Rect.fromLTRB(left + 1, top, right - 1, top + height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    // With neutral colours: grays by kind, so the timeline adds no colour.
    final base = !AppSettings.instance.neutralColors
        ? Color(p.clip.colorValue)
        : switch (p.clip.kind) {
            ClipKind.audio => const Color(0xFF4A4A4A),
            ClipKind.text => const Color(0xFF5A5A5A),
            _ => const Color(0xFF383838),
          };

    canvas.drawRRect(rrect, Paint()..color = base);
    canvas.save();
    canvas.clipRRect(rrect);
    if (p.clip.isMedia && thumbnails != null) {
      _paintThumbnails(canvas, size, p, rect);
      // Darken slightly behind the text so names stay readable.
      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top, rect.width, 18),
        Paint()..color = Colors.black.withValues(alpha: 0.35),
      );
    }
    if (p.clip.isMedia &&
        (p.clip.kind == ClipKind.audio ||
            (p.clip.kind == ClipKind.video &&
                p.track.kind == TrackKind.main))) {
      // On video clips a see-through layer over the pictures.
      _paintWaveform(
        canvas,
        size,
        p,
        rect,
        alpha: p.clip.kind == ClipKind.audio ? 0.55 : 0.4,
      );
    }
    // Subtle stripes stand in for pictures and sound in the demo clips.
    if (!p.clip.isMedia && p.clip.kind != ClipKind.text) {
      final stripe = Paint()..color = Colors.white.withValues(alpha: 0.07);
      final spacing = p.clip.kind == ClipKind.video ? height * 1.2 : 6.0;
      for (var x = left; x < right; x += spacing) {
        if (p.clip.kind == ClipKind.video) {
          canvas.drawRect(Rect.fromLTWH(x, top, 1.5, height), stripe);
        } else {
          // Fake waveform bars.
          final h =
              height * (0.25 + 0.5 * (0.5 + 0.5 * math.sin(x * 0.37)).abs());
          canvas.drawRect(
            Rect.fromLTWH(x, top + (height - h) / 2, 3, h),
            stripe..color = Colors.white.withValues(alpha: 0.18),
          );
        }
      }
    }

    // The clip's length, always shown on a dark tag so it reads over
    // pictures: bottom right on tall rows, beside the name on short ones.
    final dur = TextPainter(
      text: TextSpan(
        text: formatShortDuration(p.clip.durationUs),
        style: textStyle.copyWith(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final tagW = dur.width + 8, tagH = dur.height + 2;
    final showDur = tagW + 8 < rect.width;
    final durBeside = showDur && height < 40;

    // Changed volume: on thin rows (no room for a second line) in front of
    // the name, where a long name can't push it out of sight.
    final volume =
        p.clip.kind == ClipKind.text || (p.clip.volume - 1).abs() < 0.005
        ? null
        : (p.clip.volume <= 0.001
              ? '🔇 muted'
              : '🔊 ${(p.clip.volume * 100).round()} %');
    // Sound effects and the filter, so it's clear which clips have them.
    final fx = p.clip.activeAudioFx;
    final marks = [
      if (fx != null && fx.pitch != 0)
        '♪ ${fx.pitch > 0 ? '+' : ''}${fx.pitch}',
      if (fx != null && fx.hasEq) 'EQ',
      if (fx != null && fx.reverb != null && fx.reverbAmount > 0.001) 'Reverb',
      if (fx != null && fx.delayMs != null && fx.delayAmount > 0.001) 'Echo',
      if (fx != null && fx.noise != null && fx.noiseAmount > 0.001) 'Denoise',
      if (p.clip.gradeParams != null) 'Filter',
    ].join(' ');
    final badges = [?volume, if (marks.isNotEmpty) marks].join('  ·  ');
    final thin = rect.height < 40;
    final name = TextPainter(
      text: TextSpan(
        text: [
          if (thin && badges.isNotEmpty) badges,
          p.clip.name,
          if ((p.clip.speed - 1).abs() > 0.001)
            '${p.clip.speed.toStringAsFixed(p.clip.speed == p.clip.speed.roundToDouble() ? 0 : 2)}×',
        ].join('  ·  '),
        style: textStyle.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, rect.width - 12 - (durBeside ? tagW + 6 : 0)));
    name.paint(canvas, Offset(rect.left + 6, rect.top + 4));

    // Volume (when changed) and reversed / reversing on their own line
    // under the name (in front of it on thin rows), so they show however
    // long the name is.
    if (p.clip.reversed || (badges.isNotEmpty && !thin)) {
      final f = p.clip.reversed ? reverseJobs?.progressFor(p.clip) : null;
      final line = TextPainter(
        text: TextSpan(
          text: [
            if (!thin && badges.isNotEmpty) badges,
            if (p.clip.reversed) _reverseLabel(p.clip),
          ].join('  ·  '),
          style: textStyle.copyWith(
            color: f == null ? Colors.white70 : Colors.amberAccent,
            fontWeight: FontWeight.w600,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(0, rect.width - 12));
      final y = rect.top + 4 + name.height + 1;
      if (y + line.height <= rect.bottom - 2) {
        line.paint(canvas, Offset(rect.left + 6, y));
      }
      if (f != null) {
        final bar = Rect.fromLTWH(rect.left, rect.bottom - 3, rect.width, 3);
        canvas.drawRect(bar, Paint()..color = Colors.black54);
        canvas.drawRect(
          Rect.fromLTWH(bar.left, bar.top, bar.width * f, bar.height),
          Paint()..color = Colors.amberAccent,
        );
      }
    }

    if (showDur) {
      final tag = Rect.fromLTWH(
        rect.right - tagW - 4,
        durBeside ? rect.top + 3 : rect.bottom - tagH - 3,
        tagW,
        tagH,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(tag, const Radius.circular(3)),
        Paint()..color = Colors.black.withValues(alpha: 0.55),
      );
      dur.paint(canvas, Offset(tag.left + 4, tag.top + 1));
    }
    canvas.restore();

    if (selected) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white,
      );
      _paintHandle(
        canvas,
        Rect.fromLTWH(
          rect.left - TimelineView.handleWidth,
          top,
          TimelineView.handleWidth,
          height,
        ),
        isLeft: true,
      );
      _paintHandle(
        canvas,
        Rect.fromLTWH(rect.right, top, TimelineView.handleWidth, height),
        isLeft: false,
      );
    }
  }

  String _reverseLabel(Clip clip) {
    final f = reverseJobs?.progressFor(clip);
    return f == null ? '◀ reversed' : '◀ reversing ${(f * 100).floor()} %';
  }

  /// Draws the loudness outline of a clip, scaled by its volume. Each clip
  /// is scaled so its loudest moment fills the height, and quiet parts are
  /// lifted, so even a quiet clip shows where the sound is.
  void _paintWaveform(
    Canvas canvas,
    Size size,
    ClipPlacement p,
    Rect rect, {
    double alpha = 0.55,
  }) {
    final cache = waveforms;
    final peaks = cache?.peaksFor(p.clip.sourcePath!);
    if (cache == null || peaks == null || peaks.isEmpty) return;
    final a = p.clip.sourceTimeAt(0) ~/ 10000;
    final b = p.clip.sourceTimeAt(p.clip.durationUs) ~/ 10000;
    final loudest = cache.loudestIn(
      p.clip.sourcePath!,
      math.min(a, b),
      math.max(a, b) + 1,
    );
    if (loudest <= 0) return;
    final bar = Paint()..color = Colors.white.withValues(alpha: alpha);
    final mid = rect.center.dy;
    final half = rect.height / 2 - 2;
    final left = math.max(rect.left, 0.0);
    final right = math.min(rect.right, size.width);
    for (var x = left; x < right; x += 3) {
      final offsetUs = _tAt(x, size) - p.startUs;
      final idx = p.clip.sourceTimeAt(offsetUs) ~/ 10000;
      if (idx < 0 || idx >= peaks.length) continue;
      final gain = p.clip.gainAt(offsetUs).clamp(0.0, 1.5);
      final level = math.pow(peaks[idx] / loudest, 0.6).toDouble();
      final h = math.max(1.0, level * half * gain.clamp(0.0, 1.0));
      canvas.drawRect(Rect.fromLTRB(x, mid - h, x + 2, mid + h), bar);
    }
  }

  /// Fills a video clip with picture tiles taken from the right moments.
  void _paintThumbnails(Canvas canvas, Size size, ClipPlacement p, Rect rect) {
    final cache = thumbnails!;
    final media = p.clip.media!;
    final aspect = media.height == 0 ? 16 / 9 : media.width / media.height;
    final tileW = (rect.height * aspect).clamp(24.0, 400.0);
    final paint = Paint()..filterQuality = FilterQuality.low;
    // Tiles are aligned to the clip's start so they don't shimmer while
    // scrolling.
    var x = rect.left;
    if (x < -tileW) x += ((-tileW - x) / tileW).floor() * tileW;
    for (; x < rect.right && x < size.width; x += tileW) {
      final tile = Rect.fromLTWH(x, rect.top, tileW, rect.height);
      final timelineUs = _tAt(x, size).clamp(p.startUs, p.endUs);
      final sourceUs = p.clip.sourceTimeAt(timelineUs - p.startUs);
      // The first tile is the clip's exact first frame; the others come
      // only from the clip's own part of the file.
      final img =
          (x <= rect.left + 0.5 ? cache.firstImageOf(p.clip) : null) ??
          cache.imageAt(
            p.clip.sourcePath!,
            sourceUs,
            fromUs: p.clip.sourceInUs,
            toUs: p.clip.sourceOutUs,
          ) ??
          cache.firstImageOf(p.clip);
      if (img == null) continue;
      // Cover-fit the image into the tile.
      final iw = img.width.toDouble(), ih = img.height.toDouble();
      final scale = math.max(tile.width / iw, tile.height / ih);
      final sw = tile.width / scale, sh = tile.height / scale;
      final src = Rect.fromLTWH((iw - sw) / 2, (ih - sh) / 2, sw, sh);
      canvas.drawImageRect(img, src, tile, paint);
    }
  }

  void _paintHandle(Canvas canvas, Rect r, {required bool isLeft}) {
    final rrect = RRect.fromRectAndCorners(
      r,
      topLeft: isLeft ? const Radius.circular(6) : Radius.zero,
      bottomLeft: isLeft ? const Radius.circular(6) : Radius.zero,
      topRight: isLeft ? Radius.zero : const Radius.circular(6),
      bottomRight: isLeft ? Radius.zero : const Radius.circular(6),
    );
    canvas.drawRRect(rrect, Paint()..color = Colors.white);
    final grip = Paint()
      ..color = Colors.black54
      ..strokeWidth = 1.5;
    final cx = r.center.dx;
    canvas.drawLine(
      Offset(cx - 2, r.center.dy - 7),
      Offset(cx - 2, r.center.dy + 7),
      grip,
    );
    canvas.drawLine(
      Offset(cx + 2, r.center.dy - 7),
      Offset(cx + 2, r.center.dy + 7),
      grip,
    );
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    final x = size.width / 2;
    final paint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    final head = Path()
      ..moveTo(x - 6, 0)
      ..lineTo(x + 6, 0)
      ..lineTo(x, 8)
      ..close();
    canvas.drawPath(head, Paint()..color = colors.primary);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.project != project ||
      old.playheadUs != playheadUs ||
      old.pixelsPerSecond != pixelsPerSecond ||
      !identical(old.scale, scale) ||
      old.selectedClipId != selectedClipId ||
      old.snapUs != snapUs ||
      old.colors != colors ||
      thumbnails != null; // new pictures arrive in the background
}
