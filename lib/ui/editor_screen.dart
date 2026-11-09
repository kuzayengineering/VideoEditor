import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../model/project.dart';
import '../model/timecode.dart';
import 'canvas_sheet.dart';
import 'editor_controller.dart';
import 'export_sheet.dart';
import 'preview_view.dart';
import 'timeline_view.dart';
import 'tools.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.project});

  final Project project;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  late final EditorController c = EditorController(widget.project);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    c.addListener(_syncTicker);
  }

  @override
  void dispose() {
    _ticker.dispose();
    c.dispose();
    super.dispose();
  }

  void _syncTicker() {
    if (c.playing && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!c.playing && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    c.advancePlayback(delta.inMicroseconds);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  void _split() {
    if (!c.splitAtPlayhead()) {
      _toast(
        'Move the playhead inside a clip (not on its very edge) to split it.',
      );
    }
  }

  Future<void> _rename() async {
    final field = TextEditingController(text: c.project.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Project name'),
        content: TextField(
          controller: field,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (name != null) c.rename(name);
  }

  List<EditorTool> _tools() {
    final sel = c.selected;
    final split = EditorTool(
      'Split',
      Icons.content_cut,
      stage: 0,
      onTap: _split,
    );
    if (sel == null) {
      return [
        const EditorTool('Add media', Icons.video_library_outlined, stage: 1),
        split,
        EditorTool(
          'Canvas',
          Icons.aspect_ratio,
          stage: 0,
          onTap: () => showCanvasSheet(context, c),
        ),
        const EditorTool('Music', Icons.library_music_outlined, stage: 3),
        const EditorTool('Voice-over', Icons.mic_none, stage: 3),
        const EditorTool('Text', Icons.text_fields, stage: 4),
        const EditorTool(
          'PiP',
          Icons.picture_in_picture_alt_outlined,
          stage: 4,
        ),
        const EditorTool('Filter', Icons.photo_filter_outlined, stage: 5),
        const EditorTool('Captions', Icons.closed_caption_outlined, stage: 7),
        const EditorTool('Background', Icons.wallpaper, stage: 2),
      ];
    }
    final common = [
      split,
      EditorTool(
        'Copy',
        Icons.copy_outlined,
        stage: 0,
        onTap: c.duplicateSelected,
      ),
      EditorTool(
        'Delete',
        Icons.delete_outline,
        stage: 0,
        onTap: c.deleteSelected,
      ),
      const EditorTool('Volume', Icons.volume_up_outlined, stage: 3),
      const EditorTool('Fade', Icons.trending_up, stage: 3),
      const EditorTool('Speed', Icons.speed, stage: 2),
      const EditorTool('Pitch', Icons.multitrack_audio, stage: 6),
    ];
    if (sel.clip.kind == ClipKind.audio) {
      return [
        ...common,
        const EditorTool('Equalizer', Icons.equalizer, stage: 6),
        const EditorTool('Noise', Icons.noise_aware, stage: 6),
        const EditorTool('Reverb', Icons.surround_sound_outlined, stage: 6),
        const EditorTool('Delay', Icons.repeat, stage: 6),
      ];
    }
    return [
      ...common,
      const EditorTool('Rotate', Icons.rotate_90_degrees_cw_outlined, stage: 2),
      const EditorTool('Mirror', Icons.flip, stage: 2),
      const EditorTool('Crop', Icons.crop, stage: 2),
      const EditorTool('Reverse', Icons.settings_backup_restore, stage: 2),
      const EditorTool('Opacity', Icons.opacity, stage: 2),
      const EditorTool('Filter', Icons.photo_filter_outlined, stage: 5),
      const EditorTool('Transition', Icons.compare_arrows, stage: 4),
      const EditorTool('Extract audio', Icons.music_video_outlined, stage: 3),
      const EditorTool('Cutout', Icons.person_outline, stage: 7),
      const EditorTool('Smooth slo-mo', Icons.slow_motion_video, stage: 7),
      const EditorTool('Equalizer', Icons.equalizer, stage: 6),
      const EditorTool('Noise', Icons.noise_aware, stage: 6),
    ];
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.space): c.togglePlay,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () => c.stepFrame(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () => c.stepFrame(1),
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
        c.redo,
    const SingleActivator(LogicalKeyboardKey.keyS): _split,
    const SingleActivator(LogicalKeyboardKey.keyD, control: true):
        c.duplicateSelected,
    const SingleActivator(LogicalKeyboardKey.delete): c.deleteSelected,
    const SingleActivator(LogicalKeyboardKey.backspace): c.deleteSelected,
    const SingleActivator(LogicalKeyboardKey.escape): () => c.select(null),
  };

  @override
  Widget build(BuildContext context) {
    return PopScope<Project>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(c.project);
      },
      child: CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
          autofocus: true,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Scaffold(
              appBar: AppBar(
                leading: BackButton(
                  onPressed: () => Navigator.of(context).pop(c.project),
                ),
                titleSpacing: 0,
                title: InkWell(
                  onTap: _rename,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      c.project.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                actions: [
                  TextButton.icon(
                    onPressed: () => showCanvasSheet(context, c),
                    icon: const Icon(Icons.aspect_ratio, size: 18),
                    label: Text(c.project.canvas.label),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: FilledButton(
                      onPressed: () => showExportSheet(context, c),
                      child: const Text('Export'),
                    ),
                  ),
                ],
              ),
              body: SafeArea(
                child: Column(
                  children: [
                    Expanded(child: PreviewView(controller: c)),
                    _TransportBar(controller: c),
                    const Divider(height: 1),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 230),
                      child: SingleChildScrollView(
                        child: TimelineView(controller: c),
                      ),
                    ),
                    const Divider(height: 1),
                    ToolBar(tools: _tools()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Time display, undo/redo, frame step and play/pause.
class _TransportBar extends StatelessWidget {
  const _TransportBar({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final fps = c.project.frameRate;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${formatTimecode(c.playheadUs, fps)} / '
                    '${formatTimecode(c.project.durationUs, fps)}',
                    style: textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Text(
                  'min : sec : frame · ${fps.round()} fps',
                  style: textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Undo (Ctrl+Z)',
            onPressed: c.history.canUndo ? c.undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo (Ctrl+Y)',
            onPressed: c.history.canRedo ? c.redo : null,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: 'Back one frame (←)',
            onPressed: () => c.stepFrame(-1),
            icon: const Icon(Icons.skip_previous),
          ),
          IconButton.filled(
            tooltip: c.playing ? 'Pause (Space)' : 'Play (Space)',
            onPressed: c.togglePlay,
            icon: Icon(c.playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Forward one frame (→)',
            onPressed: () => c.stepFrame(1),
            icon: const Icon(Icons.skip_next),
          ),
        ],
      ),
    );
  }
}
