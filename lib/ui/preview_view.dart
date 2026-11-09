import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';

/// The video preview area. Until the video engine arrives (Stage 1) it shows
/// the placeholder color of the clip under the playhead, inside a frame of
/// the chosen aspect ratio.
class PreviewView extends StatelessWidget {
  const PreviewView({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final project = controller.project;
        final current = project.mainClipAt(controller.playheadUs);
        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(8),
          child: AspectRatio(
            aspectRatio: project.canvas.value,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: current == null
                    ? const Color(0xFF111111)
                    : Color(current.clip.colorValue),
                border: Border.all(color: Colors.white12),
              ),
              child: Center(
                child: current == null
                    ? Text(
                        project.mainTrack.clips.isEmpty
                            ? 'Add a video to get started'
                            : 'End of video',
                        style: const TextStyle(color: Colors.white54),
                      )
                    : _Placeholder(clip: current.clip),
              ),
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
              'Placeholder · real video preview arrives in Stage 1',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
