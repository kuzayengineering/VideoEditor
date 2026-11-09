import 'package:flutter/material.dart';

import '../engine/media_engine.dart';
import '../model/export_settings.dart';
import 'editor_controller.dart';

/// Export settings: resolution, frame rate, quality, HDR/SDR, format, folder.
/// Returns true if the user pressed "Export video".
Future<bool> showExportSheet(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
) async {
  final go = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ExportSheet(controller: c, engine: engine),
  );
  return go ?? false;
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.controller, required this.engine});

  final EditorController controller;
  final MediaEngine engine;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late ExportSettings s = widget.controller.exportSettings;

  void _update(ExportSettings next) {
    setState(() => s = next);
    widget.controller.exportSettings = next;
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.controller.project;
    final canvas = project.canvas;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    Widget section(String title, Widget child, {String? note}) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          child,
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );

    Widget chips<T>(
      List<T> values,
      T selected,
      String Function(T) label,
      void Function(T) onSelect, {
      bool Function(T)? enabled,
    }) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in values)
          ChoiceChip(
            label: Text(label(v)),
            selected: v == selected,
            onSelected: (enabled?.call(v) ?? true) ? (_) => onSelect(v) : null,
          ),
      ],
    );

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text('Export', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              s.summary(canvas),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 20),
            section(
              'Resolution',
              chips(
                ExportResolution.values,
                s.resolution,
                (r) => r.label,
                (r) => _update(s.copyWith(resolution: r)),
              ),
            ),
            section(
              'Frame rate',
              chips(
                ExportSettings.frameRates,
                s.frameRate,
                (f) => '${f.toStringAsFixed(0)} fps',
                (f) => _update(s.copyWith(frameRate: f)),
              ),
              note: s.frameRate > project.frameRate
                  ? 'Higher than the project (${project.frameRate.round()} fps). '
                        'Frames will be repeated unless slow-motion smoothing is on.'
                  : null,
            ),
            section(
              'Color',
              chips(
                DynamicRange.values,
                s.dynamicRange,
                (d) => d.label,
                (d) => _update(s.copyWith(dynamicRange: d)),
              ),
              note: s.dynamicRange.description,
            ),
            section(
              'Quality',
              chips(
                ExportQuality.values,
                s.quality,
                (q) => q.label,
                (q) => _update(s.copyWith(quality: q)),
              ),
              note:
                  'Variable bit rate: about '
                  '${formatBitrate(s.videoBitrateFor(canvas))} on average, '
                  'up to ${formatBitrate(s.peakBitrateFor(canvas))} in busy scenes.',
            ),
            section(
              'Format',
              chips(
                VideoCodec.values,
                s.codec,
                (v) => v.label,
                (v) => _update(s.copyWith(codec: v)),
                enabled: (v) => v.supports(s.dynamicRange),
              ),
              note: s.dynamicRange.isHdr
                  ? 'HDR needs HEVC. H.264 is available for SDR exports.'
                  : 'H.264 plays on almost anything; HEVC gives smaller files.',
            ),
            section(
              'Save to',
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(widget.engine.describeFolder(s.outputFolder)),
                subtitle: Text(
                  s.outputFolder == null
                      ? 'Default folder · tap to choose another'
                      : 'Tap to choose another folder',
                ),
                trailing: s.outputFolder == null
                    ? const Icon(Icons.chevron_right)
                    : IconButton(
                        tooltip: 'Use the default folder',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: () => _update(s.copyWith(resetFolder: true)),
                      ),
                onTap: widget.engine.supportsMedia
                    ? () async {
                        final folder = await widget.engine.pickOutputFolder();
                        if (folder != null && mounted) {
                          _update(s.copyWith(outputFolder: folder));
                        }
                      }
                    : null,
              ),
            ),
            Row(
              children: [
                Icon(Icons.save_outlined, size: 18, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Estimated size: about '
                    '${formatBytes(s.estimatedBytes(canvas, project.durationUs))}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Export video'),
              onPressed: () {
                if (!project.hasMedia) {
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Nothing to export'),
                      content: const Text(
                        'This project has only demo placeholder clips. '
                        'Add your own videos with "Add media" first.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
            ),
          ],
        ),
      ),
    );
  }
}
