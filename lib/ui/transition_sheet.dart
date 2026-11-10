import 'package:flutter/material.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';
import 'editor_controller.dart';

IconData transitionIcon(TransitionKind? k) => switch (k) {
  null => Icons.block,
  TransitionKind.fade => Icons.gradient,
  TransitionKind.fadeBlack => Icons.contrast,
  TransitionKind.slideLeft => Icons.arrow_back,
  TransitionKind.slideRight => Icons.arrow_forward,
  TransitionKind.slideUp => Icons.arrow_upward,
  TransitionKind.slideDown => Icons.arrow_downward,
  TransitionKind.zoom => Icons.zoom_in,
  _ => Icons.compare_arrows,
};

/// Choose how main clip [index] changes into the next one.
Future<void> showTransitionSheet(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
  int index,
) {
  c.pause();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final clips = c.project.mainTrack.clips;
            if (index >= clips.length - 1) return const SizedBox.shrink();
            final current = clips[index].transition;
            final theme = Theme.of(context);
            Widget tile(TransitionKind? k) {
              final selected = current?.kind == k;
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => c.setTransition(
                  index,
                  k == null
                      ? null
                      : TransitionSpec(
                          k,
                          durationUs: current?.durationUs ?? 500000,
                        ),
                ),
                child: Container(
                  width: 84,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(transitionIcon(k)),
                      const SizedBox(height: 6),
                      Text(
                        k?.label ?? 'None',
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              );
            }

            final hasHdr = clips.any((x) => x.media?.isHdr ?? false);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Transition', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    tile(null),
                    for (final k in TransitionKind.values) tile(k),
                  ],
                ),
                if (current != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Length'),
                      Expanded(
                        child: Slider(
                          min: 200000,
                          max: TransitionSpec.maxUs.toDouble(),
                          divisions: 28,
                          value: current.durationUs
                              .clamp(200000, TransitionSpec.maxUs)
                              .toDouble(),
                          onChanged: (v) => c.liveEdit(
                            (b) => b.setTransition(
                              index,
                              current.copyWith(durationUs: v.round()),
                            ),
                          ),
                          onChangeEnd: (_) => c.endLiveEdit(),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${(c.project.transitionUsAfter(index) / 1000000).toStringAsFixed(1)} s',
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'The two clips overlap while it plays, so the video gets '
                    'that much shorter. It can be at most half as long as '
                    'the shorter clip.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (!engine.supportsAllTransitions &&
                      current.kind != TransitionKind.fadeBlack) ...[
                    const SizedBox(height: 8),
                    Text(
                      hasHdr
                          ? 'On Android this shows as "Fade through black" for '
                                'now: Android\'s own tools can\'t blend two HDR '
                                'videos yet. It keeps your HDR intact.'
                          : 'On Android this shows as "Fade through black" for '
                                'now. The Windows version does every type.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.done_all),
                    label: const Text('Use for all cuts'),
                    onPressed: () => c.setAllTransitions(current),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
