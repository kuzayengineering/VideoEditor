import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../effects/overlay_effects.dart';
import '../engine/media_engine.dart';
import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// Effects: filmed overlays (fire, sparks, smoke, light leaks...) grouped
/// by kind. Tapping one downloads it (once) and lays it over the whole
/// picture at the playhead, already mixed the right way.
Future<void> showEffectsSheet(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
) {
  c.pause();
  return showToolPanel(
    context,
    title: 'Effects',
    scrollable: false,
    builder: (context) => _EffectsPanel(c: c, engine: engine),
  );
}

class _EffectsPanel extends StatefulWidget {
  const _EffectsPanel({required this.c, required this.engine});
  final EditorController c;
  final MediaEngine engine;

  @override
  State<_EffectsPanel> createState() => _EffectsPanelState();
}

class _EffectsPanelState extends State<_EffectsPanel> {
  late final Future<List<OverlayEffect>> _catalog = OverlayLibrary.instance
      .catalog();
  EffectGroup? _group;
  String? _busyId;
  double _progress = 0;
  String? _error;

  Future<void> _add(OverlayEffect e) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = e.id;
      _progress = 0;
      _error = null;
    });
    try {
      final path = await OverlayLibrary.instance.ensure(
        e,
        onProgress: (f) {
          if (mounted) setState(() => _progress = f);
        },
      );
      final info = await widget.engine.probe(path);
      final c = widget.c;
      final project = c.project;
      // Big enough to cover the whole picture, whatever its shape.
      final canvas = project.canvas.value;
      final clipShape = info.width > 0 && info.height > 0
          ? info.width / info.height
          : 16 / 9;
      final size = math.max(1.0, clipShape / canvas);
      final start = c.playheadUs >= project.durationUs ? 0 : c.playheadUs;
      final clip = Clip(
        id: 0,
        kind: ClipKind.video,
        name: e.title,
        sourcePath: path,
        media: info,
        sourceDurationUs: info.durationUs,
        sourceInUs: 0,
        sourceOutUs: info.durationUs,
        colorValue: 0xFF4E342E,
        volume: 0,
        startUs: start,
        pip: PipLayout(x: 0.5, y: 0.5, size: size, blend: e.blend),
      );
      final id = project.nextId;
      c.apply(project.addOverlay(clip));
      c.select(id);
      if (mounted) Navigator.of(context).maybePop();
    } catch (err) {
      if (mounted) setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<OverlayEffect>>(
      future: _catalog,
      builder: (context, snap) {
        final all = snap.data;
        if (all == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (all.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'The effects library is on its way in an update.',
              style: theme.textTheme.bodyMedium,
            ),
          );
        }
        final groups = [
          for (final g in EffectGroup.values)
            if (all.any((e) => e.group == g)) g,
        ];
        final group = groups.contains(_group) ? _group! : groups.first;
        final shown = all.where((e) => e.group == group).toList();
        return Column(
          children: [
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final g in groups)
                    InkWell(
                      onTap: () => setState(() => _group = g),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Center(
                          child: Text(
                            g.label.toUpperCase(),
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: g == group
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: g == group ? 1 : 0.45,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.1,
                ),
                itemCount: shown.length,
                itemBuilder: (context, i) => _tile(context, shown[i]),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Each effect is downloaded the first time you use it. It '
                'covers the whole picture; trim it, or use Loop to make it '
                'last longer.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, OverlayEffect e) {
    final busy = _busyId == e.id;
    return InkWell(
      onTap: () => _add(e),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (e.thumb != null)
                    Image.asset(e.thumb!, fit: BoxFit.cover)
                  else
                    const ColoredBox(color: Colors.black),
                  if (busy)
                    ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: CircularProgressIndicator(
                          value: _progress > 0 ? _progress : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
