import 'dart:async';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reverse_jobs.dart';
import '../engine/media_engine.dart';
import '../model/project.dart';
import 'editor_controller.dart';
import 'pip_view.dart';
import 'text_overlay_view.dart';
import 'thumbnail_cache.dart';

/// The video preview area: the chosen canvas shape, with the video (or, in
/// the demo, a colored placeholder) inside it.
class PreviewView extends StatelessWidget {
  const PreviewView({
    super.key,
    required this.controller,
    this.player,
    this.thumbnails,
    this.onEditText,
    this.pipPlayers,
    this.pipGestures,
    this.reverseJobs,
  });

  /// Picture in picture (null without real video).
  final PipPlayers? pipPlayers;
  final PipGestures? pipGestures;

  /// Reversed copies being made (shown as a badge on the picture).
  final ReverseJobs? reverseJobs;

  /// Opens the text editor (double-tapping a text in the preview).
  final void Function(int clipId)? onEditText;

  final EditorController controller;

  /// The real video picture, when the project has real clips.
  final Widget? player;

  /// Used for the blurred background.
  final ThumbnailCache? thumbnails;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, thumbnails, reverseJobs]),
      builder: (context, _) {
        final project = controller.project;
        final t = controller.playheadUs;
        var current =
            project.mainClipAt(t) ??
            (project.mainTrack.clips.isEmpty
                ? null
                : project.placementsOn(project.mainTrack).last);
        // During a transition: a pre-rendered one already has the looks and
        // bars baked in; otherwise the outgoing clip shows until halfway.
        final tr = project.transitionAt(t);
        final renderedTransition =
            tr != null &&
            controller.transitionFiles.containsKey(
              project.transitionKey(tr.index),
            );
        if (tr != null &&
            !renderedTransition &&
            t < tr.startUs + tr.durationUs ~/ 2) {
          current = project.placementsOn(project.mainTrack)[tr.index];
        }
        // Dips through black/white (on Windows also the stand-in for a
        // transition that is still being prepared). The Android player
        // draws mixing transitions itself.
        var dip = 0.0;
        var dipColor = Colors.black;
        for (final d in dipsOf(
          project,
          transitionFiles: controller.transitionFiles,
          blend: controller.previewBlendsTransitions,
        )) {
          if (t >= d.startUs && t < d.startUs + d.durationUs) {
            dip = 1 - ((t - d.startUs) / d.durationUs * 2 - 1).abs();
            dipColor = Color(d.color);
          }
        }
        Widget content;
        if (player != null && project.hasMedia) {
          if (controller.previewDrawsEffects) {
            // The player renders the finished frame (bars and all).
            content = ColoredBox(color: Colors.black, child: player);
          } else {
            // A clip playing from its ready-made copy already has its crop,
            // turn and bars: shown as is, like a rendered transition.
            final fromCopy =
                current != null && controller.playsFromCopy(current.clip.id);
            content = _LookPreview(
              project: project,
              placement: renderedTransition || fromCopy ? null : current,
              player: player!,
              thumbnails: thumbnails,
              plainCanvas: renderedTransition || fromCopy,
              original: controller.showsOriginal,
            );
          }
          // The phone's video view resizes a moment after the screen does
          // (a panel opening shrinks the preview): a still of the frame,
          // which resizes with the screen, covers it meanwhile.
          final still = current == null || !current.clip.isMedia
              ? null
              : thumbnails?.imageAt(
                  current.clip.sourcePath!,
                  current.clip.sourceTimeAt(t - current.startUs),
                );
          content = _ResizeGuard(
            cover: _LookPreview(
              project: project,
              placement: current,
              player: still == null
                  ? const ColoredBox(color: Colors.black)
                  : RawImage(image: still, fit: BoxFit.fill),
              thumbnails: thumbnails,
            ),
            child: content,
          );
        } else {
          final placeholder = project.mainClipAt(controller.playheadUs);
          content = DecoratedBox(
            decoration: BoxDecoration(
              color: placeholder == null
                  ? const Color(0xFF111111)
                  : Color(placeholder.clip.colorValue),
            ),
            child: Center(
              child: placeholder == null
                  ? Text(
                      project.mainTrack.clips.isEmpty
                          ? 'Tap "Add media" to add your videos'
                          : 'End of video',
                      style: const TextStyle(color: Colors.white54),
                    )
                  : _Placeholder(clip: placeholder.clip),
            ),
          );
        }
        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(8),
          child: AspectRatio(
            aspectRatio: project.canvas.value,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white12),
              ),
              child: _HoldToCompare(
                controller: controller,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      content,
                      if (pipPlayers != null && pipGestures != null)
                        PipOverlayView(
                          controller: controller,
                          players: pipPlayers!,
                          gestures: pipGestures!,
                          thumbnails: thumbnails,
                        ),
                      if (dip > 0.001)
                        IgnorePointer(
                          child: ColoredBox(
                            color: dipColor.withValues(
                              alpha: dip.clamp(0.0, 1.0),
                            ),
                          ),
                        ),
                      TextOverlayView(
                        controller: controller,
                        onEditText: onEditText ?? (_) {},
                        below: pipGestures,
                      ),
                      if (controller.transitionsPreparing.isNotEmpty &&
                          (reverseJobs?.running.isEmpty ?? true))
                        const Positioned(
                          left: 8,
                          top: 8,
                          child: IgnorePointer(child: _PreparingBadge()),
                        ),
                      if (controller.effectWorking != null &&
                          (reverseJobs?.running.isEmpty ?? true) &&
                          controller.transitionsPreparing.isEmpty)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: IgnorePointer(
                            child: _WorkingBadge(
                              label: controller.effectWorking!,
                            ),
                          ),
                        ),
                      if (controller.effectError != null)
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: _EffectErrorBar(
                            message: controller.effectError!,
                            onClose: controller.dismissEffectError,
                          ),
                        ),
                      if (reverseJobs?.running.isNotEmpty ?? false)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: IgnorePointer(
                            child: _ReversingBadge(
                              running: reverseJobs!.running,
                              current: current == null
                                  ? null
                                  : reverseJobs!.progressFor(current.clip),
                            ),
                          ),
                        ),
                    ],
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

/// Shows the plain video with the current clip's turn, mirror, crop and
/// opacity applied, over the project background — the same look the export
/// produces. The widget structure never changes shape, so the video itself
/// is never rebuilt while scrubbing.
class _LookPreview extends StatelessWidget {
  const _LookPreview({
    required this.project,
    required this.placement,
    required this.player,
    required this.thumbnails,
    this.plainCanvas = false,
    this.original = false,
  });

  /// Shown without the clip's filter (holding the video to compare).
  final bool original;

  /// The player shows a finished frame (bars and all): fill the canvas.
  final bool plainCanvas;

  final Project project;
  final ClipPlacement? placement;
  final Widget player;
  final ThumbnailCache? thumbnails;

  @override
  Widget build(BuildContext context) {
    final clip = placement?.clip;
    final display = plainCanvas || clip == null
        ? (
            width: project.canvas.width.toDouble(),
            height: project.canvas.height.toDouble(),
          )
        : clip.displaySize;
    final crop = clip?.crop ?? CropRect.full;
    final bg = project.background;

    Widget background = ColoredBox(color: Color(bg.colorValue));
    if (bg.blur && clip != null && clip.isMedia && placement != null) {
      final source = clip.sourceTimeAt(0);
      final img = thumbnails?.imageAt(clip.sourcePath!, source);
      if (img != null) {
        background = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(
              clip.flipH ? -1 : 1,
              clip.flipV ? -1 : 1,
              1,
            ),
            child: RotatedBox(
              quarterTurns: clip.rotation,
              child: RawImage(image: img, fit: BoxFit.cover),
            ),
          ),
        );
      } else {
        background = const ColoredBox(color: Colors.black);
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        background,
        Center(
          child: AspectRatio(
            aspectRatio: display.width / display.height,
            child: Opacity(
              opacity: clip?.opacity ?? 1,
              child: LayoutBuilder(
                builder: (context, box) {
                  // The whole turned picture, scaled so the cropped part
                  // fills this box exactly.
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
                            (clip?.flipH ?? false) ? -1 : 1,
                            (clip?.flipV ?? false) ? -1 : 1,
                            1,
                          ),
                          child: RotatedBox(
                            quarterTurns: clip?.rotation ?? 0,
                            child: _graded(original ? null : clip, player),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small "working on it" spinner while parts of the preview are being
/// made in the background.
class _PreparingBadge extends StatelessWidget {
  const _PreparingBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
      ),
      child: const Padding(
        padding: EdgeInsets.all(6),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
      ),
    );
  }
}

/// The clip's filter, as close as a live colour mix can show it (the
/// export uses the exact maths). Android's player draws filters itself.
Widget _graded(Clip? clip, Widget child) {
  final g = clip?.gradeParams;
  if (g == null) return child;
  return ColorFiltered(
    colorFilter: ColorFilter.matrix(gradeMatrix(g)),
    child: child,
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.clip});

  final Clip clip;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_outlined, color: Colors.white70, size: 36),
            const SizedBox(height: 8),
            Text(
              clip.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Demo placeholder clip',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Reversing 42 %" while backwards copies are being made: the clip at the
/// playhead's progress if it is one of them, else the first one's.
/// A look effect (Eye color, Outfit, Recolor) is finding people in the
/// picture: the model is loading, or the phone is catching up.
class _WorkingBadge extends StatelessWidget {
  const _WorkingBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Applying $label…',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _EffectErrorBar extends StatelessWidget {
  const _EffectErrorBar({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
                fontSize: 12,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: Theme.of(context).colorScheme.onErrorContainer,
            onPressed: onClose,
          ),
        ],
      ),
    ),
  );
}

class _ReversingBadge extends StatelessWidget {
  const _ReversingBadge({required this.running, this.current});

  final List<double> running;
  final double? current;

  @override
  Widget build(BuildContext context) {
    final f = current ?? running.first;
    final more = running.length > 1 ? ' (${running.length} clips)' : '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: f > 0 ? f : null,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Reversing ${(f * 100).floor()} %$more',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows [cover] over [child] while this box is changing size, and for a
/// moment after: the phone's video view lags behind size changes, and
/// would show too big or too small meanwhile.
class _ResizeGuard extends StatefulWidget {
  const _ResizeGuard({required this.child, required this.cover});

  final Widget child;
  final Widget cover;

  @override
  State<_ResizeGuard> createState() => _ResizeGuardState();
}

class _ResizeGuardState extends State<_ResizeGuard> {
  Size? _size;
  bool _covered = false;
  Timer? _timer;

  void _sized(Size size) {
    if (_size == null) {
      _size = size;
      return;
    }
    if ((size.width - _size!.width).abs() < 0.5 &&
        (size.height - _size!.height).abs() < 0.5) {
      return;
    }
    _size = size;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _covered = false);
    });
    // Covered from this very frame (this runs while building).
    _covered = true;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _sized(box.biggest);
      return Stack(
        fit: StackFit.expand,
        children: [widget.child, if (_covered) widget.cover],
      );
    },
  );
}

/// While the filter panel is open: holding a finger on the video (without
/// moving it) shows the clip as it was, without its filter, until let go.
class _HoldToCompare extends StatefulWidget {
  const _HoldToCompare({required this.controller, required this.child});

  final EditorController controller;
  final Widget child;

  @override
  State<_HoldToCompare> createState() => _HoldToCompareState();
}

class _HoldToCompareState extends State<_HoldToCompare> {
  Timer? _timer;
  Offset? _down;

  void _end() {
    _timer?.cancel();
    _timer = null;
    _down = null;
    widget.controller.showOriginal(false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    // Raw touches, so the text and picture-in-picture gestures underneath
    // still work as usual.
    behavior: HitTestBehavior.translucent,
    onPointerDown: (e) {
      if (!widget.controller.compareEnabled) return;
      _down = e.localPosition;
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 250), () {
        if (_down != null) widget.controller.showOriginal(true);
      });
    },
    onPointerMove: (e) {
      final d = _down;
      if (d != null &&
          (e.localPosition - d).distance > 12 &&
          !widget.controller.showsOriginal) {
        _end(); // a drag, not a hold
      }
    },
    onPointerUp: (_) => _end(),
    onPointerCancel: (_) => _end(),
    child: widget.child,
  );
}
