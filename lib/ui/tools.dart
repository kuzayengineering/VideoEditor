import 'package:flutter/material.dart';

/// A button in the bottom tool bar.
///
/// [stage] is the plan stage (see docs/PLAN.md) in which the tool starts
/// working. Tools from later stages are shown dimmed so the layout can be
/// judged now; tapping them explains when they arrive.
class EditorTool {
  const EditorTool(this.label, this.icon, {required this.stage, this.onTap});

  final String label;
  final IconData icon;
  final int stage;
  final VoidCallback? onTap;

  bool get available => onTap != null;
}

/// Horizontally scrolling row of tool buttons, like YouCut's.
class ToolBar extends StatelessWidget {
  const ToolBar({super.key, required this.tools});

  final List<EditorTool> tools;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: tools.length,
        separatorBuilder: (_, _) => const SizedBox(width: 2),
        itemBuilder: (context, i) {
          final tool = tools[i];
          final color = tool.available
              ? scheme.onSurface
              : scheme.onSurface.withValues(alpha: 0.38);
          return Tooltip(
            message: tool.available
                ? tool.label
                : '${tool.label} — arrives in Stage ${tool.stage}',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap:
                  tool.onTap ??
                  () {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            '${tool.label} arrives in Stage ${tool.stage} of the plan.',
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                  },
              child: SizedBox(
                width: 68,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(tool.icon, color: color, size: 24),
                    const SizedBox(height: 6),
                    Text(
                      tool.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
