import 'package:flutter/material.dart';

import '../model/project.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// Lets the user pick the video's shape (aspect ratio), including a custom one.
Future<void> showCanvasSheet(BuildContext context, EditorController c) {
  return showToolPanel(
    context,
    title: 'Canvas',
    builder: (context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final r in CanvasRatio.presets)
                _RatioTile(
                  ratio: r,
                  selected: c.project.canvas.sameShapeAs(r),
                  onTap: () => c.setCanvas(r),
                ),
              _RatioTile(
                ratio: CanvasRatio.presets.any(c.project.canvas.sameShapeAs)
                    ? const CanvasRatio('Custom', 1, 1, hint: 'Your own')
                    : c.project.canvas,
                selected: !CanvasRatio.presets.any(
                  c.project.canvas.sameShapeAs,
                ),
                custom: true,
                onTap: () async {
                  final r = await _askCustomRatio(context);
                  if (r != null) c.setCanvas(r);
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<CanvasRatio?> _askCustomRatio(BuildContext context) {
  final w = TextEditingController(text: '2');
  final h = TextEditingController(text: '1');
  return showDialog<CanvasRatio>(
    context: context,
    builder: (context) {
      String? error;
      return StatefulBuilder(
        builder: (context, setState) {
          void submit() {
            final wi = int.tryParse(w.text.trim());
            final hi = int.tryParse(h.text.trim());
            if (wi == null ||
                hi == null ||
                wi <= 0 ||
                hi <= 0 ||
                wi > 10000 ||
                hi > 10000) {
              setState(() => error = 'Enter two whole numbers, like 2 and 1');
              return;
            }
            final ratio = wi / hi;
            if (ratio > 4 || ratio < 0.25) {
              setState(() => error = 'Shape is too extreme (limit 4:1 to 1:4)');
              return;
            }
            Navigator.pop(context, CanvasRatio.custom(wi, hi));
          }

          return AlertDialog(
            title: const Text('Custom shape'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: w,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Width'),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(':', style: TextStyle(fontSize: 22)),
                    ),
                    Expanded(
                      child: TextField(
                        controller: h,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Height'),
                        onSubmitted: (_) => submit(),
                      ),
                    ),
                  ],
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: submit, child: const Text('Use')),
            ],
          );
        },
      );
    },
  );
}

class _RatioTile extends StatelessWidget {
  const _RatioTile({
    required this.ratio,
    required this.selected,
    required this.onTap,
    this.custom = false,
  });

  final CanvasRatio ratio;
  final bool selected;
  final bool custom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const box = 34.0;
    final w = ratio.value >= 1 ? box : box * ratio.value;
    final h = ratio.value >= 1 ? box / ratio.value : box;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            SizedBox(
              height: box,
              child: Center(
                child: custom && ratio.label == 'Custom'
                    ? Icon(Icons.edit_outlined, color: scheme.onSurface)
                    : Container(
                        width: w,
                        height: h,
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.onSurface, width: 2),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              ratio.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              ratio.hint ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
