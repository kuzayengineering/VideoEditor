import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';
import '../model/transition_math.dart';
import '../app_settings.dart';
import 'editor_controller.dart';
import 'tool_panel.dart';

/// The small icon on the timeline's transition button.
IconData transitionIcon(TransitionKind? k) {
  if (k == null) return Icons.block;
  if (k.gl) {
    return switch (k.group) {
      TransitionGroup.slide => Icons.east,
      TransitionGroup.wipe => Icons.vertical_split_outlined,
      TransitionGroup.shape => Icons.category_outlined,
      TransitionGroup.threeD => Icons.view_in_ar_outlined,
      TransitionGroup.light => Icons.flare,
      TransitionGroup.warp => Icons.waves,
      TransitionGroup.glitch => Icons.broken_image_outlined,
      TransitionGroup.basic => Icons.gradient,
    };
  }
  return switch (k) {
    TransitionKind.fade => Icons.gradient,
    TransitionKind.fadeBlack => Icons.contrast,
    TransitionKind.fadeWhite => Icons.wb_sunny_outlined,
    TransitionKind.dissolve => Icons.grain,
    TransitionKind.pixelize => Icons.grid_on,
    TransitionKind.zoom => Icons.zoom_in,
    TransitionKind.slideLeft ||
    TransitionKind.coverLeft ||
    TransitionKind.revealLeft ||
    TransitionKind.wipeLeft ||
    TransitionKind.softLeft => Icons.arrow_back,
    TransitionKind.slideRight ||
    TransitionKind.coverRight ||
    TransitionKind.revealRight ||
    TransitionKind.wipeRight ||
    TransitionKind.softRight => Icons.arrow_forward,
    TransitionKind.slideUp ||
    TransitionKind.coverUp ||
    TransitionKind.revealUp ||
    TransitionKind.wipeUp ||
    TransitionKind.softUp => Icons.arrow_upward,
    TransitionKind.slideDown ||
    TransitionKind.coverDown ||
    TransitionKind.revealDown ||
    TransitionKind.wipeDown ||
    TransitionKind.softDown => Icons.arrow_downward,
    TransitionKind.cornerTopLeft => Icons.north_west,
    TransitionKind.cornerTopRight => Icons.north_east,
    TransitionKind.cornerBottomLeft => Icons.south_west,
    TransitionKind.cornerBottomRight => Icons.south_east,
    TransitionKind.clock => Icons.schedule,
    TransitionKind.circleOpen ||
    TransitionKind.circleClose ||
    TransitionKind.iris => Icons.circle_outlined,
    TransitionKind.box => Icons.crop_square,
    TransitionKind.doorsOpen || TransitionKind.doorsClose => Icons.door_sliding,
    TransitionKind.splitOpen ||
    TransitionKind.splitClose => Icons.horizontal_split,
    _ => Icons.gradient,
  };
}

/// Choose how main clip [index] changes into the next one. Opens below the
/// video, and plays the cut each time a type is picked.
Future<void> showTransitionSheet(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
  int index,
) {
  c.pause();
  return showToolPanel(
    context,
    title: 'Transition',
    scrollable: false,
    builder: (context) => _TransitionPanel(c: c, index: index),
  );
}

class _TransitionPanel extends StatefulWidget {
  const _TransitionPanel({required this.c, required this.index});

  final EditorController c;
  final int index;

  @override
  State<_TransitionPanel> createState() => _TransitionPanelState();
}

class _TransitionPanelState extends State<_TransitionPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();
  late TransitionGroup _group = _current?.kind.group ?? TransitionGroup.basic;

  /// Start playing the loop once this transition's preview is ready.
  bool _playWhenReady = false;

  EditorController get c => widget.c;
  TransitionSpec? get _current {
    final clips = c.project.mainTrack.clips;
    return widget.index < clips.length ? clips[widget.index].transition : null;
  }

  @override
  void initState() {
    super.initState();
    c.addListener(_watch);
    // Show the transition, repeating, as soon as it's ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loopCut(play: _current != null);
    });
  }

  @override
  void dispose() {
    c.removeListener(_watch);
    c.setCustomLoop(null);
    _loop.dispose();
    super.dispose();
  }

  /// Repeats from just before the cut to just after the transition; with
  /// [play], starts once the transition's preview is ready.
  void _loopCut({required bool play}) {
    final placements = c.project.placementsOn(c.project.mainTrack);
    if (widget.index + 1 >= placements.length) return;
    final start = placements[widget.index + 1].startUs;
    final d = c.project.transitionUsAfter(widget.index);
    final from = math.max(0, start - 700000);
    c.setCustomLoop((from, start + d + 500000));
    c.pause();
    c.seek(from, exact: true);
    _playWhenReady = play;
    _armedAt = DateTime.now();
    _watch();
    // (In case nothing is being prepared for it at all.)
    Timer(const Duration(milliseconds: 1200), () {
      if (mounted) _watch();
    });
  }

  DateTime _armedAt = DateTime.now();

  /// The transition's preview is ready (or couldn't be made).
  bool get _ready {
    if (_current == null || c.transitionsLive(c.project)) return true;
    final key = c.project.transitionKey(widget.index);
    return c.transitionFiles.containsKey(key) ||
        c.transitionErrors.containsKey(key) ||
        (!c.transitionsPreparing.contains(key) &&
            DateTime.now().difference(_armedAt).inMilliseconds > 1000);
  }

  void _watch() {
    if (_playWhenReady && _ready && !c.playing) {
      _playWhenReady = false;
      // (Not from inside the controller's own notification.)
      Future.microtask(() {
        if (mounted) c.play();
      });
    }
  }

  void _pick(TransitionKind? k) {
    final current = _current;
    c.setTransition(
      widget.index,
      k == null
          ? null
          : TransitionSpec(k, durationUs: current?.durationUs ?? 800000),
    );
    _loopCut(play: k != null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final clips = c.project.mainTrack.clips;
        if (widget.index >= clips.length - 1) return const SizedBox.shrink();
        final current = _current;
        final kinds = TransitionKind.values
            .where((k) => k.group == _group)
            .toList();
        return Column(
          children: [
            SizedBox(
              height: 104,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _Tile(
                    label: 'None',
                    selected: current == null,
                    onTap: () => _pick(null),
                    child: const Center(
                      child: Icon(Icons.block, color: Colors.white54),
                    ),
                  ),
                  for (final k in kinds)
                    _Tile(
                      label: k.label,
                      selected: current?.kind == k,
                      onTap: () => _pick(k),
                      child: _Thumb(kind: k, loop: _loop),
                    ),
                ],
              ),
            ),
            if (current != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Text('Length'),
                    Expanded(
                      child: Slider(
                        min: 200000,
                        max: TransitionSpec.maxUs.toDouble(),
                        divisions: 28,
                        value: current.durationUs
                            .clamp(200000, TransitionSpec.maxUs)
                            .toDouble(),
                        onChanged: (v) => c.liveEdit(
                          (b) => b.setTransition(
                            widget.index,
                            current.copyWith(durationUs: v.round()),
                          ),
                        ),
                        onChangeEnd: (_) {
                          c.endLiveEdit();
                          _loopCut(play: true);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${(c.project.transitionUsAfter(widget.index) / 1000000).toStringAsFixed(1)} s',
                      ),
                    ),
                  ],
                ),
              )
            else
              const SizedBox(height: 48),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(child: _status(context, current)),
                  TextButton.icon(
                    icon: const Icon(Icons.done_all, size: 18),
                    label: const Text('Use for all'),
                    onPressed: () => c.setAllTransitions(current),
                  ),
                ],
              ),
            ),
            const Spacer(),
            const Divider(height: 1),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final g in TransitionGroup.values)
                    InkWell(
                      onTap: () => setState(() => _group = g),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Center(
                          child: Text(
                            g.label.toUpperCase(),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: g == _group
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurface.withValues(
                                      alpha: 0.45,
                                    ),
                              fontWeight: g == _group
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
}

extension on _TransitionPanelState {
  /// Whether the preview of this transition is ready, being made, or failed.
  Widget _status(BuildContext context, TransitionSpec? current) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    if (current == null) {
      return Text('Pick how this clip changes into the next.', style: small);
    }
    final key = c.project.transitionKey(widget.index);
    final error = c.transitionErrors[key];
    if (error != null) {
      return InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Why the preview failed'),
            content: SingleChildScrollView(child: SelectableText(error)),
            actions: [
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: error)),
                child: const Text('Copy'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
        child: Text(
          'The preview couldn\'t be made, so it shows a fade through black '
          'here. Tap for details.',
          style: small?.copyWith(
            color: theme.colorScheme.error,
            decoration: TextDecoration.underline,
          ),
        ),
      );
    }
    if (c.transitionsPreparing.contains(key)) {
      return Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Preparing the preview… it shows a fade through black until '
              'it\'s ready.',
              style: small,
            ),
          ),
        ],
      );
    }
    if (current.kind.gl && !Platform.isAndroid) {
      return Text(
        'On Windows this one exports as a simpler stand-in '
        '(${current.kind.ffmpegName}); the phone app makes it exactly.',
        style: small,
      );
    }
    if (c.transitionFiles.containsKey(key)) {
      return Text(
        'Preview ready. The clips overlap while it plays, so the video '
        'gets that much shorter.',
        style: small,
      );
    }
    return Text(
      'The clips overlap while it plays, so the video gets that much shorter.',
      style: small,
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
                  color: Colors.white10,
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
                maxLines: 2,
                textAlign: TextAlign.center,
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

/// A looping little picture of the transition between two sample scenes.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.kind, required this.loop});

  final TransitionKind kind;
  final Animation<double> loop;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ui.Image>>(
      future: TransitionThumbnails.framesFor(kind),
      builder: (context, snap) {
        final frames = snap.data;
        if (frames == null) return const SizedBox.expand();
        return AnimatedBuilder(
          animation: loop,
          builder: (context, _) {
            // Hold the first scene, play the transition, hold the second.
            final x = ((loop.value - 0.2) / 0.6).clamp(0.0, 1.0);
            final i = (x * (frames.length - 1)).round();
            return RawImage(image: frames[i], fit: BoxFit.cover);
          },
        );
      },
    );
  }
}

/// Makes (once) the frames of each transition's little preview.
class TransitionThumbnails {
  static const width = 96, height = 64, frameCount = 24;
  static final _cache = <TransitionKind, Future<List<ui.Image>>>{};
  static bool? _cacheNeutral;

  static Uint8List _renderFor((int, bool) a) => renderFrames(a.$1, gray: a.$2);

  static Future<List<ui.Image>> framesFor(TransitionKind kind) {
    // Remade in colour or gray when the setting changes.
    if (_cacheNeutral != AppSettings.instance.neutralColors) {
      _cache.clear();
      _cacheNeutral = AppSettings.instance.neutralColors;
    }
    if (kind.gl) return _cache.putIfAbsent(kind, () => _strip(kind));
    return _cache.putIfAbsent(kind, () async {
      final bytes = await compute(_renderFor, (
        kind.index,
        AppSettings.instance.neutralColors,
      ));
      final images = <ui.Image>[];
      final size = width * height * 4;
      for (var f = 0; f < frameCount; f++) {
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          Uint8List.sublistView(bytes, f * size, (f + 1) * size),
          width,
          height,
          ui.PixelFormat.rgba8888,
          done.complete,
        );
        images.add(await done.future);
      }
      return images;
    });
  }

  /// A gl-transition's frames, cut from its picture strip.
  static Future<List<ui.Image>> _strip(TransitionKind kind) async {
    final data = await rootBundle.load(
      'assets/transitions/${kind.glName}.webp',
    );
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final strip = (await codec.getNextFrame()).image;
    final rgba = (await strip.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    final stripW = strip.width;
    strip.dispose();
    final gray = AppSettings.instance.neutralColors;
    final images = <ui.Image>[];
    for (var f = 0; f < frameCount; f++) {
      final px = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        final from = (y * stripW + f * width) * 4;
        px.setRange(y * width * 4, (y + 1) * width * 4, rgba, from);
      }
      if (gray) {
        for (var i = 0; i < px.length; i += 4) {
          final v = (0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2])
              .round()
              .clamp(0, 255);
          px[i] = v;
          px[i + 1] = v;
          px[i + 2] = v;
        }
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        px,
        width,
        height,
        ui.PixelFormat.rgba8888,
        done.complete,
      );
      images.add(await done.future);
    }
    return images;
  }

  /// RGBA bytes of every frame (runs in the background).
  @visibleForTesting
  static Uint8List renderFrames(int kindIndex, {bool gray = false}) {
    final kind = TransitionKind.values[kindIndex];
    final out = Uint8List(width * height * 4 * frameCount);
    const Rgb white = (r: 1, g: 1, b: 1), black = (r: 0, g: 0, b: 0);
    var o = 0;
    for (var f = 0; f < frameCount; f++) {
      final t = f / (frameCount - 1);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final u = (x + 0.5) / width, v = (y + 0.5) / height;
          final c = kind.isDip
              ? dipPixel(
                  u,
                  v,
                  t,
                  kind == TransitionKind.fadeWhite ? white : black,
                  _sunset,
                  _sea,
                )
              : transitionPixel(
                  kind.code,
                  u,
                  v,
                  t,
                  width.toDouble(),
                  height.toDouble(),
                  _sunset,
                  _sea,
                );
          if (gray) {
            // Shades of gray, like the rest of the interface.
            final y = ((0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) * 255)
                .round()
                .clamp(0, 255);
            out[o++] = y;
            out[o++] = y;
            out[o++] = y;
          } else {
            out[o++] = (c.r * 255).round().clamp(0, 255);
            out[o++] = (c.g * 255).round().clamp(0, 255);
            out[o++] = (c.b * 255).round().clamp(0, 255);
          }
          out[o++] = 255;
        }
      }
    }
    return out;
  }

  /// Sample scene 1: an orange sky with a sun over dark hills.
  static Rgb _sunset(double u, double v) {
    final hill = 0.72 + 0.08 * math.sin(u * 7);
    if (v > hill) return (r: 0.25, g: 0.12, b: 0.18);
    final dx = (u - 0.32) * 1.5, dy = v - 0.42;
    if (dx * dx + dy * dy < 0.025) return (r: 1, g: 0.93, b: 0.55);
    return (r: 1, g: 0.55 - 0.25 * v, b: 0.25 + 0.3 * v);
  }

  /// Sample scene 2: a blue sea with a white sail.
  static Rgb _sea(double u, double v) {
    if (v > 0.6) return (r: 0.05, g: 0.3 + 0.2 * (1 - v), b: 0.55);
    final inSail =
        u > 0.58 &&
        u < 0.78 &&
        v > 0.18 &&
        v < 0.6 &&
        (u - 0.58) < (v - 0.18) * 0.5;
    if (inSail) return (r: 1, g: 1, b: 1);
    return (r: 0.55 + 0.3 * v, g: 0.78 + 0.1 * v, b: 0.95);
  }
}
