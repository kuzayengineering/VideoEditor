import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../engine/media_engine.dart';
import '../model/project.dart';
import '../model/timecode.dart';
import 'canvas_sheet.dart';
import 'audio_preview.dart';
import 'clip_tools.dart';
import 'editor_controller.dart';
import 'export_progress_screen.dart';
import 'export_sheet.dart';
import 'import_media.dart';
import 'preview_view.dart';
import 'reorder_screen.dart';
import 'reverse_jobs.dart';
import 'text_render.dart';
import 'text_sheet.dart';
import 'thumbnail_cache.dart';
import 'timeline_view.dart';
import 'tool_panel.dart';
import 'tools.dart';
import 'transition_sheet.dart';
import 'voiceover_sheet.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.project, this.autosave = true});

  final Project project;

  /// Save changes automatically (off for the demo project).
  final bool autosave;

  @override
  State<EditorScreen> createState() => _EditorHostState();
}

/// Holds the tool panels (shown below the video), so every tool in the
/// editor can open one.
class _EditorHostState extends State<EditorScreen> {
  final _panels = ToolPanelController();

  @override
  void dispose() {
    _panels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ToolPanelScope(
    controller: _panels,
    child: _Editor(project: widget.project, autosave: widget.autosave),
  );
}

class _Editor extends StatefulWidget {
  const _Editor({required this.project, required this.autosave});

  final Project project;
  final bool autosave;

  @override
  State<_Editor> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<_Editor>
    with SingleTickerProviderStateMixin {
  late final EditorController c = EditorController(widget.project);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;

  late AppServices _services;
  MediaEngine get _engine => _services.engine;
  ThumbnailCache? _thumbs;
  WaveformCache? _waves;
  AudioPreviewMixer? _mixer;
  ReverseJobs? _reverses;
  PreviewPlayer? _preview;
  Widget? _previewWidget;
  Timer? _saveTimer;
  Project? _lastSaved;

  @override
  void initState() {
    super.initState();
    c.addListener(_syncTicker);
    c.addListener(_onProjectMaybeChanged);
    _lastSaved = widget.project;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_thumbs != null) return;
    _services = AppServices.of(context);
    _thumbs = ThumbnailCache(_engine)..ensureFor(c.project);
    _waves = WaveformCache(_engine)..ensureFor(c.project);
    _reverses = ReverseJobs(_engine);
    // A saved project may have reversed clips whose copies were never
    // finished (e.g. the app was closed): pick those back up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resumeReverses(c.project);
    });
    if (_engine.supportsMedia) {
      final preview = _engine.createPreview();
      _preview = preview;
      _previewWidget = preview.buildView(context);
      _mixer = AudioPreviewMixer(_engine);
      c.attachPreview(preview, audio: _mixer);
      // Reconnect to an export that is still running (e.g. the app was
      // closed and reopened during an export).
      _engine.runningExport().then((job) {
        if (job != null && mounted) _showProgress(job);
      });
    }
  }

  @override
  void dispose() {
    _flushSave();
    _ticker.dispose();
    c.dispose();
    _thumbs?.dispose();
    _waves?.dispose();
    _mixer?.dispose();
    _reverses?.dispose();
    _preview?.dispose();
    super.dispose();
  }

  void _onProjectMaybeChanged() {
    final project = c.project;
    if (identical(project, _lastSaved) || c.history.inGesture) return;
    _thumbs?.ensureFor(project);
    _waves?.ensureFor(project);
    _resumeReverses(project);
    _renderTransitions(project);
    if (!widget.autosave || _services.store == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _flushSave);
  }

  void _flushSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final project = c.project;
    if (!widget.autosave || identical(project, _lastSaved)) return;
    _lastSaved = project;
    unawaited(_services.store?.save(project));
  }

  Future<void> _addMedia() async {
    c.pause();
    final clips = await pickAndReadVideos(context, _engine);
    if (clips.isEmpty || !mounted) return;
    c.insertMedia(clips);
    _toast(
      clips.length == 1 ? 'Added 1 video' : 'Added ${clips.length} videos',
    );
  }

  /// Adds a text at the playhead (3 seconds, or to the end of the video)
  /// and opens the text editor.
  void _addText() {
    c.pause();
    final start =
        c.playheadUs >= c.project.durationUs && c.project.durationUs > 0
        ? 0
        : c.playheadUs;
    final room = c.project.durationUs - start;
    final length = room >= 1000000 ? room.clamp(1000000, 3000000) : 3000000;
    final project = c.project.addText(
      Clip.text(const TextSpec(), startUs: start, durationUs: length),
    );
    c.apply(project);
    final id = c.project.textTracks
        .expand((t) => t.clips)
        .reduce((a, b) => a.id > b.id ? a : b)
        .id;
    c.select(id);
    showTextSheet(context, c, id);
  }

  Future<void> _reorder(int clipId) async {
    c.pause();
    final order = await Navigator.of(context).push<List<int>>(
      MaterialPageRoute(
        builder: (_) => ReorderScreen(
          project: c.project,
          thumbnails: _thumbs,
          highlightClipId: clipId,
        ),
      ),
    );
    if (order != null) c.apply(c.project.reorderMain(order));
  }

  Future<void> _addMusic() async {
    c.pause();
    final clips = await pickAndReadAudio(context, _engine, c.playheadUs);
    if (clips.isEmpty || !mounted) return;
    var project = c.project;
    for (final clip in clips) {
      project = project.addAudio(clip);
    }
    c.apply(project);
    _toast(
      clips.length == 1
          ? 'Added "${clips.single.name}" at the playhead'
          : 'Added ${clips.length} sounds at the playhead',
    );
  }

  Future<void> _crop() async {
    final sel = c.selected;
    if (sel == null || !sel.clip.isMedia) return;
    c.pause();
    final clip = sel.clip;
    final offset = (c.playheadUs - sel.startUs).clamp(0, clip.durationUs);
    File? frame;
    try {
      final files = await _engine.thumbnails(clip.sourcePath!, clip.media!, [
        clip.sourceTimeAt(offset),
      ], height: 720);
      if (files.first != null) frame = File(files.first!);
    } catch (_) {}
    if (!mounted) return;
    final rect = await Navigator.of(context).push<CropRect>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            CropScreen(clip: clip, frame: frame, canvas: c.project.canvas),
      ),
    );
    if (rect != null) {
      c.updateSelected((x) => x.copyWith(crop: rect));
    }
  }

  Future<void> _toggleReverse() async {
    final sel = c.selected;
    if (sel == null) return;
    c.pause();
    if (sel.clip.reversed) {
      c.updateSelected((x) => x.copyWith(reversed: false));
      return;
    }
    c.updateSelected((x) => x.copyWith(reversed: true));
    final clip = c.project.placementOf(sel.clip.id)?.clip;
    if (clip != null && !clip.reverseReady) {
      _toast(
        'Making the reversed copy in the background. You can keep editing; '
        'the clip plays forwards until it\'s ready.',
      );
      _startReverse(clip);
    }
  }

  /// Starts (or joins) the background reversal for [clip].
  void _startReverse(Clip clip) {
    final jobs = _reverses;
    if (jobs == null) return;
    jobs
        .start(clip)
        .then(
          (proxy) {
            if (!mounted) return;
            c.attachReverseProxy(clip.id, proxy);
          },
          onError: (Object e) {
            if (!mounted) return;
            // Give up on reversing this clip so it isn't retried endlessly.
            c.apply(
              c.project.updateClip(clip.id, (x) => x.copyWith(reversed: false)),
            );
            _alert('Can\'t reverse "${clip.name}"', '$e');
          },
        );
  }

  final Set<String> _transitionsInFlight = {};
  Future<void> _transitionQueue = Future.value();

  static String _reason(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    final text = '$e';
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  /// Pre-renders each transition for the preview, one at a time, in the
  /// background. Until one is ready the preview dips through black.
  void _renderTransitions(Project project) {
    if (!_engine.supportsAllTransitions || !_engine.supportsMedia) return;
    for (var i = 0; i + 1 < project.mainTrack.clips.length; i++) {
      if (project.transitionUsAfter(i) <= 0) continue;
      final key = project.transitionKey(i);
      if (c.transitionFiles.containsKey(key) ||
          !_transitionsInFlight.add(key)) {
        continue;
      }
      final mini = project.transitionPreviewProject(i);
      if (mini == null || !mini.mainTrack.clips.every((x) => x.isMedia)) {
        continue;
      }
      c.setTransitionPreparing(key, true);
      _transitionQueue = _transitionQueue.then((_) async {
        try {
          final path = await _engine.renderPreviewClip(mini, key);
          if (!mounted) return;
          if (path != null) {
            c.addTransitionFile(key, path);
          } else {
            c.setTransitionPreparing(key, false);
          }
        } catch (e) {
          // The preview keeps the dip-through-black stand-in.
          if (mounted) c.setTransitionError(key, _reason(e));
        }
      });
    }
  }

  /// Reversed clips whose copy is missing (e.g. after trimming) get one made
  /// in the background automatically.
  void _resumeReverses(Project project) {
    final jobs = _reverses;
    if (jobs == null || !_engine.supportsMedia) return;
    for (final clip in project.mainTrack.clips) {
      if (clip.isMedia &&
          clip.reversed &&
          !clip.reverseReady &&
          jobs.progressFor(clip) == null) {
        _startReverse(clip);
      }
    }
  }

  /// Before exporting: wait for any reversed copies still being made, with a
  /// progress bar.
  Future<bool> _ensureReversesReady() async {
    final jobs = _reverses;
    final pending = [
      for (final clip in c.project.mainTrack.clips)
        if (clip.isMedia && clip.reversed && !clip.reverseReady) clip,
    ];
    if (pending.isEmpty || jobs == null) return true;
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Finishing reversed clips'),
          content: ListenableBuilder(
            listenable: jobs,
            builder: (context, _) {
              final values = [
                for (final p in pending) jobs.progressFor(p) ?? 1.0,
              ];
              final avg = values.reduce((a, b) => a + b) / values.length;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: avg > 0 ? avg : null),
                  const SizedBox(height: 12),
                  Text(
                    pending.length == 1
                        ? 'Making the backwards copy of "${pending.single.name}"…'
                        : 'Making backwards copies of ${pending.length} clips…',
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    try {
      for (final clip in pending) {
        final proxy = await jobs.start(clip);
        if (!mounted) return false;
        c.attachReverseProxy(clip.id, proxy);
      }
      navigator.pop();
      return true;
    } catch (e) {
      navigator.pop();
      if (mounted) await _alert('Can\'t reverse', '$e');
      return false;
    }
  }

  Future<void> _export() async {
    c.pause();
    if (!await showExportSheet(context, c, _engine) || !mounted) return;
    if (!await _ensureReversesReady() || !mounted) return;
    final problem = await _engine.checkExport(c.project, c.exportSettings);
    if (!mounted) return;
    if (problem != null) {
      await _alert('Can\'t export with these settings', problem);
      return;
    }
    try {
      // Draw the texts at the export size (the same drawing as the preview).
      final dims = c.exportSettings.dimensionsFor(c.project.canvas);
      final textDir = Directory(
        '${Directory.systemTemp.path}/video_editor_texts_${c.project.id}',
      );
      if (await textDir.exists()) await textDir.delete(recursive: true);
      final textImages = await renderTextImages(
        c.project,
        dims.width,
        dims.height,
        textDir,
      );
      if (!mounted) return;
      final job = await _engine.startExport(
        ExportRequest(
          project: c.project,
          settings: c.exportSettings,
          fileName: _exportFileName(c.project.name),
          textImages: textImages,
        ),
      );
      if (mounted) _showProgress(job);
    } catch (e) {
      if (mounted) await _alert('Export could not start', '$e');
    }
  }

  void _showProgress(ExportJob job) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ExportProgressScreen(job: job),
      ),
    );
  }

  static String _exportFileName(String projectName) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final safe = projectName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return '${safe.isEmpty ? 'Video' : safe} '
        '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}${two(now.minute)}.mp4';
  }

  Future<void> _alert(String title, String text) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(text)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

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
        EditorTool(
          'Add media',
          Icons.video_library_outlined,
          stage: 1,
          onTap: _engine.supportsMedia ? _addMedia : null,
        ),
        split,
        EditorTool(
          'Canvas',
          Icons.aspect_ratio,
          stage: 0,
          onTap: () => showCanvasSheet(context, c),
        ),
        EditorTool(
          'Music',
          Icons.library_music_outlined,
          stage: 3,
          onTap: _engine.supportsMedia ? _addMusic : null,
        ),
        EditorTool(
          'Voice-over',
          Icons.mic_none,
          stage: 3,
          onTap: _engine.supportsMedia
              ? () => showVoiceOverSheet(context, c, _engine)
              : null,
        ),
        EditorTool('Text', Icons.text_fields, stage: 4, onTap: _addText),
        const EditorTool(
          'PiP',
          Icons.picture_in_picture_alt_outlined,
          stage: 4,
        ),
        const EditorTool('Filter', Icons.photo_filter_outlined, stage: 5),
        const EditorTool('Captions', Icons.closed_caption_outlined, stage: 7),
        EditorTool(
          'Background',
          Icons.wallpaper,
          stage: 2,
          onTap: () => showBackgroundSheet(context, c, _engine),
        ),
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
      EditorTool(
        'Volume',
        Icons.volume_up_outlined,
        stage: 3,
        onTap: sel.clip.isMedia ? () => showVolumeSheet(context, c) : null,
      ),
      EditorTool(
        'Fade',
        Icons.trending_up,
        stage: 3,
        onTap: sel.clip.isMedia ? () => showFadeSheet(context, c) : null,
      ),
      EditorTool(
        'Speed',
        Icons.speed,
        stage: 2,
        onTap: () => showSpeedSheet(context, c),
      ),
      const EditorTool('Pitch', Icons.multitrack_audio, stage: 6),
    ];
    if (sel.clip.kind == ClipKind.text) {
      return [
        EditorTool(
          'Edit',
          Icons.edit_outlined,
          stage: 4,
          onTap: () => showTextSheet(context, c, sel.clip.id),
        ),
        EditorTool(
          'Animation',
          Icons.animation,
          stage: 4,
          onTap: () => showTextSheet(context, c, sel.clip.id, initialTab: 3),
        ),
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
      ];
    }
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
      EditorTool(
        'Rotate',
        Icons.rotate_90_degrees_cw_outlined,
        stage: 2,
        onTap: sel.clip.isMedia ? c.rotateSelected : null,
      ),
      EditorTool(
        'Mirror',
        Icons.flip,
        stage: 2,
        onTap: sel.clip.isMedia ? c.mirrorSelected : null,
      ),
      EditorTool(
        'Crop',
        Icons.crop,
        stage: 2,
        onTap: sel.clip.isMedia ? _crop : null,
      ),
      EditorTool(
        sel.clip.reversed ? 'Un-reverse' : 'Reverse',
        Icons.settings_backup_restore,
        stage: 2,
        onTap: sel.clip.isMedia ? _toggleReverse : null,
      ),
      EditorTool(
        'Opacity',
        Icons.opacity,
        stage: 2,
        onTap: sel.clip.isMedia ? () => showOpacitySheet(context, c) : null,
      ),
      const EditorTool('Filter', Icons.photo_filter_outlined, stage: 5),
      EditorTool(
        'Transition',
        Icons.compare_arrows,
        stage: 4,
        onTap: () {
          final i = c.project.mainTrack.clips.indexWhere(
            (x) => x.id == sel.clip.id,
          );
          if (i >= 0 && i + 1 < c.project.mainTrack.clips.length) {
            showTransitionSheet(context, c, _engine, i);
          } else {
            _toast(
              'Transitions go between two clips: pick a clip that has '
              'another one after it.',
            );
          }
        },
      ),
      EditorTool(
        'Extract audio',
        Icons.music_video_outlined,
        stage: 3,
        onTap: sel.clip.isMedia && (sel.clip.media?.hasAudio ?? false)
            ? () {
                c.extractAudioOfSelected();
                _toast('The sound is now on its own audio track.');
              }
            : null,
      ),
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
    const SingleActivator(LogicalKeyboardKey.escape): () {
      final panels = ToolPanelScope.maybeOf(context);
      if (panels?.current != null) {
        panels!.close();
      } else {
        c.select(null);
      }
    },
  };

  @override
  Widget build(BuildContext context) {
    final panels = ToolPanelScope.watch(context)!;
    final panel = panels.current;
    return PopScope<Project>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Back closes an open tool first.
        if (panels.current != null) {
          panels.close();
        } else {
          Navigator.of(context).pop(c.project);
        }
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
                      onPressed: _export,
                      child: const Text('Export'),
                    ),
                  ),
                ],
              ),
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, box) => Column(
                    children: [
                      Expanded(
                        child: PreviewView(
                          controller: c,
                          player: _previewWidget,
                          thumbnails: _thumbs,
                          onEditText: (id) => showTextSheet(context, c, id),
                        ),
                      ),
                      _TransportBar(controller: c),
                      const Divider(height: 1),
                      // A tool's settings take the place of the timeline and
                      // toolbar, so they never cover the video.
                      if (panel != null)
                        SizedBox(
                          height: (box.maxHeight - 170).clamp(
                            0.0,
                            (box.maxHeight * 0.5).clamp(240.0, 330.0),
                          ),
                          child: ToolPanelView(
                            key: ObjectKey(panel),
                            panel: panel,
                            onDone: () => panels.close(panel),
                          ),
                        )
                      else ...[
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 230),
                          child: SingleChildScrollView(
                            child: TimelineView(
                              controller: c,
                              thumbnails: _thumbs,
                              waveforms: _waves,
                              onLongPressClip: _reorder,
                              reverseJobs: _reverses,
                              onTransitionTap: (i) =>
                                  showTransitionSheet(context, c, _engine, i),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ToolBar(tools: _tools()),
                      ],
                    ],
                  ),
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
