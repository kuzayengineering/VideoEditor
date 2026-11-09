import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';

/// The video preview area: the chosen canvas shape on black, with the video
/// (or, in the demo, a colored placeholder) inside it.
class PreviewView extends StatelessWidget {
  const PreviewView({super.key, required this.controller, this.player});

  final EditorController controller;

  /// The real video picture, when the project has real clips.
  final Widget? player;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final project = controller.project;
        final current =
            project.mainClipAt(controller.playheadUs) ??
            (project.mainTrack.clips.isEmpty
                ? null
                : project.placementsOn(project.mainTrack).last);
        final Widget content;
        if (player != null && project.hasMedia) {
          // Size the picture to the current clip's own shape, centred in the
          // canvas: exactly how it will look in the export (black bars where
          // the shapes differ).
          final media = current?.clip.media;
          final aspect = media == null || media.height == 0
              ? project.canvas.value
              : media.width / media.height;
          content = ColoredBox(
            color: Colors.black,
            child: Center(
              child: AspectRatio(aspectRatio: aspect, child: player),
            ),
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
              child: ClipRect(child: content),
            ),
          ),
        );
      },
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
