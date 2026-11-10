import 'dart:async';

import 'package:flutter/material.dart';

/// A tool's settings, shown in the editor's bottom area (where the timeline
/// and toolbar are) so the video above stays fully visible while you work.
class ToolPanel {
  ToolPanel({
    required this.title,
    required this.builder,
    this.scrollable = true,
  });

  final String title;
  final WidgetBuilder builder;

  /// False when the content sizes itself to the panel (tabs, lists).
  final bool scrollable;

  final Completer<void> _closed = Completer<void>();
}

/// Which panel is open in the editor.
class ToolPanelController extends ChangeNotifier {
  ToolPanel? _current;
  ToolPanel? get current => _current;

  Future<void> open(ToolPanel panel) {
    final old = _current;
    _current = panel;
    if (old != null && !old._closed.isCompleted) old._closed.complete();
    notifyListeners();
    return panel._closed.future;
  }

  /// Closes the open panel (or only [panel], if given and still open).
  void close([ToolPanel? panel]) {
    final p = _current;
    if (p == null || (panel != null && !identical(panel, p))) return;
    _current = null;
    if (!p._closed.isCompleted) p._closed.complete();
    notifyListeners();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}

/// Makes [ToolPanelController] reachable from anywhere in the editor.
class ToolPanelScope extends InheritedNotifier<ToolPanelController> {
  const ToolPanelScope({
    super.key,
    required ToolPanelController controller,
    required super.child,
  }) : super(notifier: controller);

  static ToolPanelController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToolPanelScope>()?.notifier;

  /// Rebuilds [context] when a panel opens or closes.
  static ToolPanelController? watch(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ToolPanelScope>()?.notifier;
}

/// Opens a tool's settings below the video. The future completes when it
/// is closed. Outside the editor (no [ToolPanelScope]) it falls back to a
/// bottom sheet.
Future<void> showToolPanel(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  bool scrollable = true,
}) {
  final panels = ToolPanelScope.maybeOf(context);
  if (panels == null) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.45,
          child: _PanelBody(
            scrollable: scrollable,
            child: Builder(builder: builder),
          ),
        ),
      ),
    );
  }
  return panels.open(
    ToolPanel(title: title, builder: builder, scrollable: scrollable),
  );
}

/// Closes the panel that [context] is in.
void closeToolPanel(BuildContext context) {
  final panels = ToolPanelScope.maybeOf(context);
  if (panels != null) {
    panels.close();
  } else {
    Navigator.maybePop(context);
  }
}

/// The open panel: a title bar with a done tick, and the tool below it.
class ToolPanelView extends StatelessWidget {
  const ToolPanelView({super.key, required this.panel, required this.onDone});

  final ToolPanel panel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: Text(
                    panel.title.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Done',
                  icon: const Icon(Icons.check),
                  onPressed: onDone,
                ),
              ],
            ),
          ),
          Expanded(
            child: _PanelBody(
              scrollable: panel.scrollable,
              child: Builder(builder: panel.builder),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.scrollable, required this.child});

  final bool scrollable;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!scrollable) return child;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: child,
    );
  }
}
