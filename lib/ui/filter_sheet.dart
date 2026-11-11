import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';
import 'thumbnail_cache.dart';
import 'tool_panel.dart';

/// The filter for a clip: ready-made looks (with strength) and manual
/// adjustments, shown live; one undo step per change.
Future<void> showFilterSheet(
  BuildContext context,
  EditorController c,
  ThumbnailCache? thumbnails,
) async {
  final id = c.selectedClipId;
  if (id == null) return;
  c.pause();
  await showToolPanel(
    context,
    title: 'Filter',
    scrollable: false,
    builder: (context) =>
        _FilterPanel(c: c, clipId: id, thumbnails: thumbnails),
  );
  c.endLiveEdit();
}

class _FilterPanel extends StatefulWidget {
  const _FilterPanel({
    required this.c,
    required this.clipId,
    required this.thumbnails,
  });

  final EditorController c;
  final int clipId;
  final ThumbnailCache? thumbnails;

  @override
  State<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<_FilterPanel> {
  int _tab = 0;

  EditorController get c => widget.c;

  ColorGrade get _grade =>
      c.project.placementOf(widget.clipId)?.clip.grade ?? const ColorGrade();

  void _set(ColorGrade g, {bool live = false}) {
    Project change(Project base) =>
        base.updateClip(widget.clipId, (x) => x.copyWith(grade: g));
    if (live) {
      c.liveEdit(change);
    } else {
      c.apply(change(c.project));
    }
  }

  /// Gives every video clip (main and picture in picture) this filter.
  void _useForAll() {
    final g = _grade;
    var p = c.project;
    for (final t in [p.mainTrack, ...p.overlayTracks]) {
      for (final clip in t.clips) {
        if (clip.kind == ClipKind.video) {
          p = p.updateClip(clip.id, (x) => x.copyWith(grade: g));
        }
      }
    }
    c.apply(p);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Filter applied to every video clip')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final placement = c.project.placementOf(widget.clipId);
        if (placement == null) return const SizedBox.shrink();
        final g = _grade;
        return Column(
          children: [
            Expanded(
              child: _tab == 0
                  ? _looks(context, placement, g)
                  : _adjust(context, g),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Reset'),
                    onPressed: g.isNeutral
                        ? null
                        : () => _set(const ColorGrade()),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.done_all, size: 18),
                    label: const Text('Use for all'),
                    onPressed: _useForAll,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  for (final (i, label) in const [
                    (0, 'FILTERS'),
                    (1, 'ADJUST'),
                  ])
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _tab = i),
                        child: Center(
                          child: Text(
                            label,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: i == _tab
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurface.withValues(
                                      alpha: 0.45,
                                    ),
                              fontWeight: i == _tab
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _looks(BuildContext context, ClipPlacement p, ColorGrade g) {
    final clip = p.clip;
    final offset = (c.playheadUs - p.startUs).clamp(0, clip.durationUs);
    final base = clip.isMedia
        ? widget.thumbnails?.imageAt(
            clip.sourcePath!,
            clip.sourceTimeAt(offset),
          )
        : null;
    return Column(
      children: [
        SizedBox(
          height: 100,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final preset in FilterPreset.values)
                _Tile(
                  label: preset.label,
                  selected: g.preset == preset,
                  onTap: () => _set(
                    g.copyWith(
                      preset: preset,
                      strength: g.preset == preset ? g.strength : 1,
                    ),
                  ),
                  child: _GradedThumb(
                    base: base,
                    params: preset.params,
                    fallback: Color(clip.colorValue),
                  ),
                ),
            ],
          ),
        ),
        if (g.preset != FilterPreset.none)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const SizedBox(width: 72, child: Text('Strength')),
                Expanded(
                  child: Slider(
                    value: g.strength,
                    onChanged: (v) => _set(g.copyWith(strength: v), live: true),
                    onChangeEnd: (_) => c.endLiveEdit(),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${(g.strength * 100).round()}%'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _adjust(BuildContext context, ColorGrade g) {
    final a = g.adjust;
    Widget row(
      String label,
      double value,
      GradeParams Function(double v) change, {
      double min = -1,
    }) => Row(
      children: [
        SizedBox(width: 96, child: Text(label)),
        Expanded(
          child: Slider(
            min: min,
            max: 1,
            value: value.clamp(min, 1.0),
            onChanged: (v) {
              // Snap to the middle so "no change" is easy to find.
              final snapped = v.abs() < 0.04 ? 0.0 : v;
              _set(g.copyWith(adjust: change(snapped)), live: true);
            },
            onChangeEnd: (_) => c.endLiveEdit(),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text('${(value * 100).round()}', textAlign: TextAlign.end),
        ),
      ],
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      children: [
        row('Brightness', a.brightness, (v) => a.copyWith(brightness: v)),
        row('Contrast', a.contrast, (v) => a.copyWith(contrast: v)),
        row('Shadows', a.shadows, (v) => a.copyWith(shadows: v)),
        row('Highlights', a.highlights, (v) => a.copyWith(highlights: v)),
        row('HDR intensity', a.hdr, (v) => a.copyWith(hdr: v)),
        row('Saturation', a.saturation, (v) => a.copyWith(saturation: v)),
        row('Warmth', a.warmth, (v) => a.copyWith(warmth: v)),
        row('Tint', a.tint, (v) => a.copyWith(tint: v)),
        row('Fade', a.fade, (v) => a.copyWith(fade: v), min: 0),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 84,
          child: Column(
            children: [
              Container(
                width: 84,
                height: 56,
                clipBehavior: ui.Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : Colors.white12,
                    width: selected ? 2.5 : 1,
                  ),
                ),
                child: child,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: selected ? theme.colorScheme.primary : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The clip's own picture with a look applied, using the exact filter
/// maths.
class _GradedThumb extends StatefulWidget {
  const _GradedThumb({
    required this.base,
    required this.params,
    required this.fallback,
  });

  final ui.Image? base;
  final GradeParams params;
  final Color fallback;

  @override
  State<_GradedThumb> createState() => _GradedThumbState();
}

class _GradedThumbState extends State<_GradedThumb> {
  ui.Image? _image;
  ui.Image? _madeFrom;

  @override
  void initState() {
    super.initState();
    _make();
  }

  @override
  void didUpdateWidget(_GradedThumb old) {
    super.didUpdateWidget(old);
    if (old.base != widget.base || old.params != widget.params) _make();
  }

  Future<void> _make() async {
    final base = widget.base;
    if (base == null || identical(base, _madeFrom)) return;
    _madeFrom = base;
    final data = await base.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null || !mounted) return;
    final px = Uint8List.fromList(data.buffer.asUint8List());
    final p = widget.params;
    if (!p.isNeutral) {
      for (var i = 0; i + 3 < px.length; i += 4) {
        final c = applyGrade(p, px[i] / 255, px[i + 1] / 255, px[i + 2] / 255);
        px[i] = (c.r * 255).round().clamp(0, 255);
        px[i + 1] = (c.g * 255).round().clamp(0, 255);
        px[i + 2] = (c.b * 255).round().clamp(0, 255);
      }
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      px,
      base.width,
      base.height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    final img = await done.future;
    if (mounted) setState(() => _image = img);
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      // No picture of the clip yet: its colour, filtered.
      final f = widget.fallback;
      final c = applyGrade(widget.params, f.r, f.g, f.b);
      return ColoredBox(
        color: Color.from(alpha: 1, red: c.r, green: c.g, blue: c.b),
      );
    }
    return RawImage(image: img, fit: BoxFit.cover);
  }
}
