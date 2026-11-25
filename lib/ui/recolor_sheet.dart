import 'dart:io';

import 'package:flutter/material.dart';

import '../effects/parts_model.dart';
import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

const _colors = <int>[
  0xFFE53935, // red
  0xFFFF7043, // copper
  0xFFFFB300, // gold
  0xFFFFF176, // blonde
  0xFF8D6E63, // brown
  0xFF212121, // black
  0xFFFFFFFF, // white / silver
  0xFFEC407A, // pink
  0xFFAB47BC, // purple
  0xFF3949AB, // blue
  0xFF29B6F6, // light blue
  0xFF26A69A, // teal
  0xFF43A047, // green
];

/// Recolour: new colours for the hair, skin or clothes of the people in the
/// selected clip, found by an on-device model (downloaded once).
Future<void> showRecolorSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  c.pause();
  return showToolPanel(
    context,
    title: 'Recolor',
    builder: (context) => _RecolorPanel(c: c, clipId: id),
  );
}

class _RecolorPanel extends StatefulWidget {
  const _RecolorPanel({required this.c, required this.clipId});
  final EditorController c;
  final int clipId;

  @override
  State<_RecolorPanel> createState() => _RecolorPanelState();
}

class _RecolorPanelState extends State<_RecolorPanel> {
  bool? _have;
  double? _progress;
  String? _error;

  EditorController get c => widget.c;

  @override
  void initState() {
    super.initState();
    PartsModel.instance.check().then((ok) {
      if (mounted) setState(() => _have = ok);
    });
  }

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      await PartsModel.instance.ensure(
        onProgress: (f) {
          if (mounted) setState(() => _progress = f);
        },
      );
      c.refreshPreview();
      if (mounted) setState(() => _have = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  void _set(PartColors p) => c.apply(
    c.project.updateClip(widget.clipId, (x) => x.copyWith(partColors: p)),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!Platform.isAndroid) {
      return Text(
        'Recolor works in the phone app for now.',
        style: theme.textTheme.bodyMedium,
      );
    }
    if (_have == null) return const SizedBox(height: 60);
    if (_have == false) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Change the color of hair, skin or clothes. It needs a one-time '
            'download of 16 MB (Google\'s MediaPipe model). After that it '
            'works offline, on the phone: your videos are never uploaded.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          if (_progress != null)
            LinearProgressIndicator(value: _progress! > 0 ? _progress : null)
          else
            FilledButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('Download (16 MB)'),
              onPressed: _download,
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      );
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final clip = c.project.placementOf(widget.clipId)?.clip;
        if (clip == null) return const SizedBox.shrink();
        final p = clip.partColors ?? const PartColors();
        Widget row(String label, int value, PartColors Function(int) change) =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Text(label, style: theme.textTheme.titleSmall),
                ),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _Swatch(
                        selected: value == 0,
                        onTap: () => _set(change(0)),
                        child: const Icon(Icons.block, size: 18),
                      ),
                      for (final col in _colors)
                        _Swatch(
                          selected: value == col,
                          color: Color(col),
                          onTap: () => _set(change(col)),
                        ),
                    ],
                  ),
                ),
              ],
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('Hair', p.hair, (v) => p.copyWith(hair: v)),
            row('Clothes', p.clothes, (v) => p.copyWith(clothes: v)),
            row('Skin', p.skin, (v) => p.copyWith(skin: v)),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Strength', style: theme.textTheme.titleSmall),
            ),
            Slider(
              value: p.strength,
              onChanged: (v) => c.liveEdit(
                (now) => now.updateClip(
                  widget.clipId,
                  (x) => x.copyWith(
                    partColors: (x.partColors ?? const PartColors()).copyWith(
                      strength: v,
                    ),
                  ),
                ),
              ),
              onChangeEnd: (_) => c.endLiveEdit(),
            ),
            Text(
              'Found by an on-device model, frame by frame: works best when '
              'people are fairly large in the picture. Previews and exports '
              'with recoloring take longer.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.selected,
    required this.onTap,
    this.color,
    this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Color? color;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.white24,
            width: selected ? 3 : 1,
          ),
        ),
        child: child,
      ),
    ),
  );
}
