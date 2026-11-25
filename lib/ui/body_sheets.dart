import 'dart:io';

import 'package:flutter/material.dart';

import '../effects/parts_model.dart';
import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

const _eyeColors = <(String, int)>[
  ('Blue', 0xFF4A90D9),
  ('Ice blue', 0xFF9AD0F5),
  ('Green', 0xFF3FA34D),
  ('Hazel', 0xFF9C7A3C),
  ('Grey', 0xFF9AA5AE),
  ('Amber', 0xFFE0A030),
  ('Violet', 0xFF8E5CC9),
  ('Red', 0xFFD03030),
];

const _clothColors = <int>[
  0xFF111111, // black
  0xFFFFFFFF, // white
  0xFF9E9E9E, // grey
  0xFFE53935, // red
  0xFFEC407A, // pink
  0xFFAB47BC, // purple
  0xFF1E3A8A, // navy
  0xFF29B6F6, // light blue
  0xFF2E7D32, // green
  0xFFFFB300, // yellow
  0xFFD7B899, // nude
  0xFF6D4C41, // brown
];

/// Eye colour: a new iris colour for the people in the selected clip.
Future<void> showEyeColorSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  c.pause();
  return showToolPanel(
    context,
    title: 'Eye colour',
    builder: (context) => _ModelGate(
      c: c,
      models: [DownloadableModel.face],
      intro:
          'Change the colour of people\'s eyes. Only the coloured part '
          'changes, not the pupil, the whites or the eyelids.',
      child: (context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final clip = c.project.placementOf(id)?.clip;
          if (clip == null) return const SizedBox.shrink();
          final e = clip.eyeColor ?? const EyeColor();
          final theme = Theme.of(context);
          void set(EyeColor v) =>
              c.apply(c.project.updateClip(id, (x) => x.copyWith(eyeColor: v)));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('None'),
                    selected: e.color == 0,
                    onSelected: (_) => set(e.copyWith(color: 0)),
                  ),
                  for (final (name, col) in _eyeColors)
                    ChoiceChip(
                      avatar: CircleAvatar(backgroundColor: Color(col)),
                      label: Text(name),
                      selected: e.color == col,
                      onSelected: (_) => set(e.copyWith(color: col)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text('Strength', style: theme.textTheme.titleSmall),
              Slider(
                value: e.strength,
                onChanged: (v) => c.liveEdit(
                  (now) => now.updateClip(
                    id,
                    (x) => x.copyWith(
                      eyeColor: (x.eyeColor ?? const EyeColor()).copyWith(
                        strength: v,
                      ),
                    ),
                  ),
                ),
                onChangeEnd: (_) => c.endLiveEdit(),
              ),
              Text(
                'Works best when faces are fairly large and looking towards '
                'the camera. Exports with eye colour take longer.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Outfit: tight-fitting clothes on bare skin (shirt, gloves, socks,
/// stockings) that follow the body.
Future<void> showOutfitSheet(BuildContext context, EditorController c) {
  final id = c.selectedClipId;
  if (id == null) return Future.value();
  c.pause();
  return showToolPanel(
    context,
    title: 'Outfit',
    builder: (context) => _ModelGate(
      c: c,
      models: [DownloadableModel.pose, DownloadableModel.parts],
      intro:
          'Add tight-fitting clothes where skin is bare: a shirt, gloves, '
          'socks or stockings, which follow the body as it moves.',
      child: (context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final clip = c.project.placementOf(id)?.clip;
          if (clip == null) return const SizedBox.shrink();
          final o = clip.outfit ?? const Outfit();
          final theme = Theme.of(context);
          void set(Outfit v) =>
              c.apply(c.project.updateClip(id, (x) => x.copyWith(outfit: v)));
          void live(Outfit Function(Outfit o) change) => c.liveEdit(
            (now) => now.updateClip(
              id,
              (x) => x.copyWith(outfit: change(x.outfit ?? const Outfit())),
            ),
          );
          Widget colors(String label, int value, Outfit Function(int) pick) =>
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
                          onTap: () => set(pick(0)),
                          child: const Icon(Icons.block, size: 18),
                        ),
                        for (final col in _clothColors)
                          _Swatch(
                            selected: value == col,
                            color: Color(col),
                            onTap: () => set(pick(col)),
                          ),
                      ],
                    ),
                  ),
                ],
              );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              colors('Shirt', o.shirt, (v) => o.copyWith(shirt: v)),
              if (o.shirt != 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final (n, label) in const [
                        (0, 'No sleeves'),
                        (1, 'Short sleeves'),
                        (2, 'Long sleeves'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: o.sleeves == n,
                          onSelected: (_) => set(o.copyWith(sleeves: n)),
                        ),
                    ],
                  ),
                ),
              colors('Gloves', o.gloves, (v) => o.copyWith(gloves: v)),
              colors('Socks', o.socks, (v) => o.copyWith(socks: v)),
              colors('Stockings', o.stockings, (v) => o.copyWith(stockings: v)),
              if (o.stockings != 0) ...[
                const SizedBox(height: 6),
                Text('Stockings reach', style: theme.textTheme.bodySmall),
                Slider(
                  // Left: higher up the thigh; right: just above the knee.
                  min: 0.05,
                  max: 0.9,
                  value: o.stockingTop.clamp(0.05, 0.9),
                  label: o.stockingTop < 0.25
                      ? 'High thigh'
                      : (o.stockingTop < 0.6 ? 'Mid thigh' : 'Above knee'),
                  divisions: 17,
                  onChanged: (v) => live((x) => x.copyWith(stockingTop: v)),
                  onChangeEnd: (_) => c.endLiveEdit(),
                ),
              ],
              const SizedBox(height: 6),
              Text('See-through', style: theme.textTheme.titleSmall),
              Slider(
                max: 0.9,
                value: o.sheer.clamp(0.0, 0.9),
                onChanged: (v) => live((x) => x.copyWith(sheer: v)),
                onChangeEnd: (_) => c.endLiveEdit(),
              ),
              Text(
                'Painted onto bare skin, like a skin-tight garment. Works best '
                'with one person, fairly large in the picture; edges may '
                'shimmer in fast movement. Exports with outfits take longer.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Shows [intro] and a download button until [models] are on the device,
/// then [child].
class _ModelGate extends StatefulWidget {
  const _ModelGate({
    required this.c,
    required this.models,
    required this.intro,
    required this.child,
  });

  final EditorController c;
  final List<DownloadableModel> models;
  final String intro;
  final WidgetBuilder child;

  @override
  State<_ModelGate> createState() => _ModelGateState();
}

class _ModelGateState extends State<_ModelGate> {
  bool? _have;
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.wait([for (final m in widget.models) m.check()]).then((ok) {
      if (mounted) setState(() => _have = ok.every((x) => x));
    });
  }

  int get _bytes => widget.models
      .where((m) => m.path == null)
      .fold(0, (sum, m) => sum + m.bytes);

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final total = _bytes;
      var done = 0;
      for (final m in widget.models) {
        if (m.path != null) continue;
        await m.ensure(
          onProgress: (f) {
            if (mounted) {
              setState(() => _progress = (done + f * m.bytes) / total);
            }
          },
        );
        done += m.bytes;
      }
      widget.c.refreshPreview();
      if (mounted) setState(() => _have = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!Platform.isAndroid) {
      return Text(
        'This works in the phone app for now.',
        style: theme.textTheme.bodyMedium,
      );
    }
    final have = _have;
    if (have == null) return const SizedBox(height: 60);
    if (have) return widget.child(context);
    final mb = (_bytes / 1e6).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.intro}\n\nIt needs a one-time download of $mb MB '
          '(Google\'s MediaPipe models). After that it works offline, on the '
          'phone: your videos are never uploaded.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        if (_progress != null)
          LinearProgressIndicator(value: _progress! > 0 ? _progress : null)
        else
          FilledButton.icon(
            icon: const Icon(Icons.download),
            label: Text('Download ($mb MB)'),
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
