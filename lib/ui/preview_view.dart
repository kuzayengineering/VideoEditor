import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';
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
  });

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
        final current =
            project.mainClipAt(controller.playheadUs) ??
            (project.mainTrack.clips.isEmpty
                ? null
                : project.placementsOn(project.mainTrack).last);
        final Widget content;
        if (player != null && project.hasMedia) {
          if (controller.previewDrawsEffects) {
            // The player renders the finished frame (bars and all).
            content = ColoredBox(color: Colors.black, child: player);
          } else {
            content = _LookPreview(
              project: project,
              placement: current,
              player: player!,
              thumbnails: thumbnails,
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
                    TextOverlayView(
                      controller: controller,
                      onEditText: onEditText ?? (_) {},
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
  });

  final Project project;
  final ClipPlacement? placement;
  final Widget player;
  final ThumbnailCache? thumbnails;

  @override
  Widget build(BuildContext context) {
    final clip = placement?.clip;
    final display = clip?.displaySize ?? (width: 16.0, height: 9.0);
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
                            child: player,
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
