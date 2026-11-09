import 'package:flutter/material.dart';

import '../model/project.dart';
import '../model/timecode.dart';
import 'thumbnail_cache.dart';

/// Drag clips up or down to change their order. Returns the new order (clip
/// ids), or null if cancelled.
class ReorderScreen extends StatefulWidget {
  const ReorderScreen({
    super.key,
    required this.project,
    this.thumbnails,
    this.highlightClipId,
  });

  final Project project;
  final ThumbnailCache? thumbnails;

  /// The clip that was held down (shown highlighted).
  final int? highlightClipId;

  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends State<ReorderScreen> {
  late final List<Clip> _clips = List.of(widget.project.mainTrack.clips);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Arrange clips'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: () =>
                  Navigator.pop(context, [for (final c in _clips) c.id]),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Hold a clip and drag it to a new place.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: _clips.length,
                onReorderItem: (from, to) => setState(() {
                  _clips.insert(to, _clips.removeAt(from));
                }),
                itemBuilder: (context, i) {
                  final c = _clips[i];
                  final img = c.isMedia
                      ? widget.thumbnails?.imageAt(
                          c.sourcePath!,
                          c.sourceTimeAt(0),
                        )
                      : null;
                  final highlighted = c.id == widget.highlightClipId;
                  return Card(
                    key: ValueKey(c.id),
                    color: highlighted
                        ? theme.colorScheme.primaryContainer
                        : null,
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 96,
                          height: 54,
                          child: img != null
                              ? RotatedBox(
                                  quarterTurns: c.rotation,
                                  child: RawImage(
                                    image: img,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : ColoredBox(color: Color(c.colorValue)),
                        ),
                      ),
                      title: Text(
                        '${i + 1}.  ${c.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(formatShortDuration(c.durationUs)),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
