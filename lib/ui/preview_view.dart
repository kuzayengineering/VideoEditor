import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
  });

  /// Picture in picture (null without real video).
  final PipPlayers? pipPlayers;
  final PipGestures? pipGestures;

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
      listenable: Listenable.merge([controller, thumbnails]),
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
        final Widget content;
        if (player != null && project.hasMedia) {
          if (controller.previewDrawsEffects) {
            // The player renders the finished frame (bars and all).
            content = ColoredBox(color: Colors.black, child: player);
          } else {
            // A clip playing from its ready-made copy already has its crop,
            // turn and bars: shown as is, like a rendered transition.
            final fromCopy =
                current != null && controller.playsFromCopy(current.index);
            content = _LookPreview(
              project: project,
              placement: renderedTransition || fromCopy ? null : current,
              player: player!,
              thumbnails: thumbnails,
              plainCanvas: renderedTransition || fromCopy,
            );
          }
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
                    if (controller.transitionsPreparing.isNotEmpty)
                      const Positioned(
                        left: 8,
                        top: 8,
                        child: IgnorePointer(child: _PreparingBadge()),
                      ),
                  ],
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
  });

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
                            child: _graded(clip, player),
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
