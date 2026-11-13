import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';
import 'audio_preview.dart';
import 'editor_controller.dart';
import 'frame_snap.dart';
import 'thumbnail_cache.dart';

/// Where a picture-in-picture clip sits in a canvas of [box] size: centre,
/// size (before turning) and turn in radians.
({Offset center, Size size, double angle}) pipGeometry(Clip clip, Size box) {
  final pip = clip.pip ?? const PipLayout();
  final d = clip.displaySize;
  final w = pip.size * box.width;
  final h = d.width > 0 ? w * d.height / d.width : w * 9 / 16;
  return (
    center: Offset(pip.x * box.width, pip.y * box.height),
    size: Size(w, h),
    angle: pip.angle * math.pi / 180,
  );
}

/// Keeps one small player per picture-in-picture clip near the playhead, in
/// step with the main preview: paused players show the exact frame,
/// playing ones start and stop as their clips come and go.
class PipPlayers {
  PipPlayers(this.engine, this.c) {
    c.addListener(_sync);
    _sync();
  }

  final MediaEngine engine;
  final EditorController c;
  final Map<int, _Slot> _slots = {};
  final List<OverlayPlayer> _spare = [];
  bool _disposed = false;

  /// The picture of clip [clipId], once its player exists.
  Widget? viewFor(BuildContext context, int clipId) =>
      _slots[clipId]?.view(context);

  void _sync() {
    if (_disposed) return;
    if (c.previewSuspended) {
      // Exporting: close every player (the export needs the decoders).
      for (final slot in _slots.values) {
        slot.retire();
        unawaited(slot.player.dispose());
      }
      _slots.clear();
      for (final p in _spare) {
        unawaited(p.dispose());
      }
      _spare.clear();
      return;
    }
    final project = c.project;
    final t = c.playheadUs;
    final wanted = <int, ClipPlacement>{};
    for (final track in project.overlayTracks) {
      for (final p in project.placementsOn(track)) {
        // The ones showing, plus the next ones (so they start promptly).
        if (p.clip.isMedia && p.endUs > t - 300000 && p.startUs < t + 1500000) {
          wanted[p.clip.id] = p;
        }
      }
    }
    for (final id in _slots.keys.toList()) {
      if (wanted.containsKey(id)) continue;
      final slot = _slots.remove(id)!;
      slot.retire();
      if (_spare.length < 2) {
        _spare.add(slot.player);
      } else {
        unawaited(slot.player.dispose());
      }
    }
    for (final p in wanted.values) {
      var slot = _slots[p.clip.id];
      if (slot == null) {
        final player = _spare.isNotEmpty
            ? _spare.removeLast()
            : engine.createOverlayPlayer();
        if (player == null) continue;
        slot = _slots[p.clip.id] = _Slot(player);
      }
      slot.update(p, t, c.playing, muted: c.previewMuted);
    }
  }

  void dispose() {
    _disposed = true;
    c.removeListener(_sync);
    for (final s in _slots.values) {
      unawaited(s.player.dispose());
    }
    for (final p in _spare) {
      unawaited(p.dispose());
    }
    _slots.clear();
    _spare.clear();
  }
}

class _Slot {
  _Slot(this.player);

  final OverlayPlayer player;
  PreviewSegment? _segment;
  Future<void> _ready = Future.value();
  bool _playing = false;
  int? _seekedTo;
  double? _volume;
  int? _pendingSeek;
  bool _seeking = false;
  Widget? _view;

  Widget view(BuildContext context) => _view ??= player.buildView(context);

  void retire() {
    if (_playing) unawaited(player.pause());
    _playing = false;
  }

  void update(ClipPlacement p, int t, bool playing, {required bool muted}) {
    final seg = PreviewSegment.of(p.clip);
    if (seg != _segment ||
        seg.source != _segment?.source ||
        seg.speed != _segment?.speed) {
      _segment = seg;
      _seekedTo = null;
      _ready = _ready.then((_) => player.open(seg)).catchError((_) {});
    }
    // With sound effects its sound plays from the audio mixer instead.
    final volume = muted || AudioPreviewMixer.hasOwnSound(p.clip)
        ? 0.0
        : p.clip.volume.clamp(0.0, 1.0);
    if (volume != _volume) {
      _volume = volume;
      _ready = _ready.then((_) => player.setVolume(volume)).catchError((_) {});
    }
    final offset = (t - p.startUs).clamp(0, p.clip.durationUs);
    final active = p.contains(t);
    if (playing) {
      if (active && !_playing) {
        _playing = true;
        _ready = _ready
            .then((_) async {
              await player.seek(offset, exact: true);
              await player.play();
            })
            .catchError((_) {});
      } else if (!active && _playing) {
        _playing = false;
        _ready = _ready.then((_) => player.pause()).catchError((_) {});
      }
      _seekedTo = null;
      return;
    }
    if (_playing) {
      _playing = false;
      _ready = _ready.then((_) => player.pause()).catchError((_) {});
    }
    if (_seekedTo != offset) {
      _seekedTo = offset;
      _seekTo(offset);
    }
  }

  /// Seeks to the newest target only (scrubbing sends many).
  void _seekTo(int offset) {
    _pendingSeek = offset;
    if (_seeking) return;
    _seeking = true;
    _ready = _ready
        .then((_) async {
          while (_pendingSeek != null) {
            final target = _pendingSeek!;
            _pendingSeek = null;
            await player.seek(target, exact: true);
          }
          _seeking = false;
        })
        .catchError((_) {
          _seeking = false;
        });
  }
}

/// Moving, resizing and turning picture-in-picture clips on the preview.
/// Also used by the text layer above, for touches that miss every text.
class PipGestures extends ChangeNotifier {
  PipGestures(this.c);

  final EditorController c;

  int? _dragId;
  late PipLayout _start;
  Offset _focalStart = Offset.zero;

  /// Guide lines being snapped to (shown while dragging): centre lines or
  /// frame edges, as fractions of the frame.
  double? snapX;
  double? snapY;

  /// The picture-in-picture clip under [pos] (top-most first).
  ClipPlacement? hit(Offset pos, Size box) {
    for (final p in c.project.overlaysAt(c.playheadUs).reversed) {
      final g = pipGeometry(p.clip, box);
      final d = pos - g.center;
      final a = -g.angle;
      final local = Offset(
        d.dx * math.cos(a) - d.dy * math.sin(a),
        d.dx * math.sin(a) + d.dy * math.cos(a),
      );
      const slop = 12.0;
      if (local.dx.abs() <= g.size.width / 2 + slop &&
          local.dy.abs() <= g.size.height / 2 + slop) {
        return p;
      }
    }
    return null;
  }

  /// A tap: selects the picture under it. Returns false if there is none.
  bool tap(Offset pos, Size box) {
    final p = hit(pos, box);
    if (p == null) {
      if (c.selected?.track.kind == TrackKind.overlay) c.select(null);
      return false;
    }
    c.pause();
    c.select(p.clip.id);
    return true;
  }

  /// Starts moving the picture under the finger(s). False if there is none.
  bool scaleStart(ScaleStartDetails d, Size box) {
    final p = hit(d.localFocalPoint, box);
    if (p == null) {
      _dragId = null;
      return false;
    }
    c.pause();
    c.select(p.clip.id);
    _dragId = p.clip.id;
    _start = p.clip.pip ?? const PipLayout();
    _focalStart = d.localFocalPoint;
    return true;
  }

  void scaleUpdate(ScaleUpdateDetails d, Size box) {
    final id = _dragId;
    if (id == null) return;
    final move = d.localFocalPoint - _focalStart;
    var angle = _start.angle + d.rotation * 180 / math.pi;
    // Snap to level when nearly straight.
    final nearest = (angle / 90).round() * 90.0;
    if ((angle - nearest).abs() < 3) angle = nearest;
    // Snap to the centre lines and the frame's edges.
    final clip = c.project.placementOf(id)?.clip;
    final size = clip == null
        ? Size.zero
        : pipGeometry(
            clip.copyWith(pip: _start.copyWith(size: _start.size * d.scale)),
            box,
          ).size;
    final snap = snapInFrame(
      _start.x + move.dx / box.width,
      _start.y + move.dy / box.height,
      size,
      angle * math.pi / 180,
      box,
    );
    final nx = snap.x, ny = snap.y;
    if ((snap.guideX != null && snap.guideX != snapX) ||
        (snap.guideY != null && snap.guideY != snapY)) {
      HapticFeedback.selectionClick();
    }
    if (snap.guideX != snapX || snap.guideY != snapY) {
      snapX = snap.guideX;
      snapY = snap.guideY;
      notifyListeners();
    }
    final next = _start.copyWith(
      x: nx,
      y: ny,
      size: _start.size * d.scale,
      angle: angle,
    );
    c.liveEdit(
      (base) => base.updateClip(id, (clip) => clip.copyWith(pip: next)),
    );
  }

  void scaleEnd() {
    if (_dragId != null) c.endLiveEdit();
    _dragId = null;
    if (snapX != null || snapY != null) {
      snapX = null;
      snapY = null;
      notifyListeners();
    }
  }
}

/// Draws the picture-in-picture clips on the preview (their players'
/// pictures, placed, sized, turned and faded as in the export) and lets you
/// move them when no text is in the way.
class PipOverlayView extends StatelessWidget {
  const PipOverlayView({
    super.key,
    required this.controller,
    required this.players,
    required this.gestures,
    this.thumbnails,
  });

  final EditorController controller;
  final PipPlayers players;
  final PipGestures gestures;
  final ThumbnailCache? thumbnails;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        return ListenableBuilder(
          listenable: Listenable.merge([c, gestures]),
          builder: (context, _) {
            final shown = c.project.overlaysAt(c.playheadUs);
            final selectedId = c.selected?.clip.id;
            final pictures = <Widget>[
              for (final p in shown)
                _picture(context, p, box, p.clip.id == selectedId, accent),
            ];
            final guides = CustomPaint(
              size: box,
              painter: _GuidesPainter(gestures.snapX, gestures.snapY, accent),
            );
            final stack = Stack(
              children: [
                ...pictures,
                IgnorePointer(child: guides),
              ],
            );
            if (c.project.overlayTracks.isEmpty) {
              return IgnorePointer(child: stack);
            }
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) => gestures.tap(d.localPosition, box),
              onScaleStart: (d) => gestures.scaleStart(d, box),
              onScaleUpdate: (d) => gestures.scaleUpdate(d, box),
              onScaleEnd: (_) => gestures.scaleEnd(),
              child: SizedBox.fromSize(size: box, child: stack),
            );
          },
        );
      },
    );
  }

  Widget _picture(
    BuildContext context,
    ClipPlacement p,
    Size box,
    bool selected,
    Color accent,
  ) {
    final clip = p.clip;
    final g = pipGeometry(clip, box);
    final thumb = clip.isMedia
        ? thumbnails?.imageAt(
            clip.sourcePath!,
            clip.sourceTimeAt(controller.playheadUs - p.startUs),
          )
        : null;
    final video = players.viewFor(context, clip.id);
    Widget picture = Stack(
      fit: StackFit.expand,
      children: [
        if (thumb != null)
          _Look(
            clip: clip,
            child: RawImage(image: thumb, fit: BoxFit.fill),
          )
        else
          ColoredBox(color: Color(clip.colorValue)),
        if (video != null) _Look(clip: clip, child: video),
      ],
    );
    if (clip.opacity < 0.999) {
      picture = Opacity(opacity: clip.opacity, child: picture);
    }
    return Positioned(
      left: g.center.dx - g.size.width / 2,
      top: g.center.dy - g.size.height / 2,
      width: g.size.width,
      height: g.size.height,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: g.angle,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: selected ? Border.all(color: accent, width: 2) : null,
            ),
            child: ClipRect(child: picture),
          ),
        ),
      ),
    );
  }
}

/// The clip's quarter turn, mirror and crop applied to its raw picture, so
/// the cropped part fills the box.
class _Look extends StatelessWidget {
  const _Look({required this.clip, required this.child});

  final Clip clip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final crop = clip.crop;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth / crop.width;
        final h = box.maxHeight / crop.height;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: w,
            maxWidth: w,
            minHeight: h,
            maxHeight: h,
            child: Transform.translate(
              offset: Offset(-crop.left * w, -crop.top * h),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(
                  clip.flipH ? -1 : 1,
                  clip.flipV ? -1 : 1,
                  1,
                ),
                child: RotatedBox(
                  quarterTurns: clip.rotation,
                  child: clip.gradeParams == null
                      ? child
                      : ColorFiltered(
                          colorFilter: ColorFilter.matrix(
                            gradeMatrix(clip.gradeParams!),
                          ),
                          child: child,
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GuidesPainter extends CustomPainter {
  _GuidesPainter(this.x, this.y, this.color);

  final double? x;
  final double? y;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      paintSnapGuides(canvas, size, x, y, color);

  @override
  bool shouldRepaint(_GuidesPainter old) =>
      old.x != x || old.y != y || old.color != color;
}
