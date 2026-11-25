import 'dart:io';

import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// Blend: how a picture-in-picture clip mixes with the picture below.
Future<void> showBlendSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  c.pause();
  return showToolPanel(
    context,
    title: 'Blend',
    builder: (context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final clip = c.project.placementOf(id)?.clip;
        final pip = clip?.pip;
        if (pip == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in PipBlend.values)
                  ChoiceChip(
                    label: Text(b.label),
                    selected: pip.blend == b,
                    onSelected: (_) => c.apply(
                      c.project.updateClip(
                        id,
                        (x) => x.copyWith(pip: pip.copyWith(blend: b)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(pip.blend.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Text(
              'For effects filmed on black (fire, sparks, smoke, light leaks) '
              'use Screen. The preview shows an approximation; the exported '
              'video mixes exactly.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      },
    ),
  );
}

/// Cutout: hides everything but the people. On a picture-in-picture clip
/// the person shows over the clips below; on a main-video clip everything
/// else becomes the project's background colour.
Future<void> showCutoutSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  c.pause();
  return showToolPanel(
    context,
    title: 'Cutout',
    builder: (context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final clip = c.project.placementOf(id)?.clip;
        if (clip == null) return const SizedBox.shrink();
        final pip = clip.pip;
        final on = pip?.cutout ?? clip.cutout;
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Remove background'),
              subtitle: const Text('Keep only the people'),
              value: on,
              onChanged: (v) => c.apply(
                c.project.updateClip(
                  id,
                  (x) => pip != null
                      ? x.copyWith(pip: pip.copyWith(cutout: v))
                      : x.copyWith(cutout: v),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${pip != null ? 'The person shows over the clips below. ' : 'Everything else becomes the background colour (change it with the Background tool). To put the person over other video, add this clip with PiP instead. '}'
              'Works best when the person is fairly close to the camera and '
              'stands out from the background.'
              '${Platform.isAndroid ? '' : ' On Windows the cutout is not '
                        'available yet: the clip shows with its background.'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      },
    ),
  );
}
