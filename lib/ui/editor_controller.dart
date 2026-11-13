import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/media_engine.dart';
import '../model/export_settings.dart';
import '../model/history.dart';
import '../model/project.dart';
import '../model/timecode.dart';
import 'audio_preview.dart';

/// Holds everything the editor screen shows: the project (with undo/redo),
/// the playhead position, the selected clip and the timeline zoom.
class EditorController extends ChangeNotifier {
  EditorController(Project project)
    : history = EditHistory(project.withAnchorsRecorded());

  final EditHistory history;

  Project get project => history.current;

  int _playheadUs = 0;
  int get playheadUs => _playheadUs;

  int? _selectedClipId;
  int? get selectedClipId => _selectedClipId;
  ClipPlacement? get selected =>
      _selectedClipId == null ? null : project.placementOf(_selectedClipId!);

  bool _playing = false;
  bool get playing => _playing;

  /// Timeline zoom: how many screen pixels one second takes up.
  // Zoomed out a little by default, so a swipe covers more time.
  double _pixelsPerSecond = 32;
  double get pixelsPerSecond => _pixelsPerSecond;
  static const minPixelsPerSecond = 4.0;
  static const maxPixelsPerSecond = 2400.0;

  ExportSettings? _exportSettings;

  /// Export choices. Until the user changes them, they're suggested from the
  /// clips (e.g. 4K 60 fps HLG for Pixel HDR video).
  ExportSettings get exportSettings =>
      _exportSettings ??= ExportSettings.suggestedFor(project);
  set exportSettings(ExportSettings value) => _exportSettings = value;

  // ---------------------------------------------------------------------------
  // Real video preview
  // ---------------------------------------------------------------------------

  PreviewPlayer? _preview;

  /// True when a real video player is showing the edit (instead of the demo
  /// placeholders).
  bool get usesPreview => _preview != null && project.hasMedia;

  /// True if the preview player draws clip effects itself (Android with
  /// effects); otherwise the screen draws them around the video.
  bool get previewDrawsEffects {
    final p = _preview;
    if (p == null) return false;
    final blend = p.blendsTransitions;
    // A player that mixes transitions plays the whole finished picture.
    if (blend && blendLayersOf(project) != null) return true;
    return p.drawsEffects(segmentsOf(project, blend: blend));
  }

  /// True if the preview player draws mixing transitions itself (Android).
  bool get previewBlendsTransitions => _preview?.blendsTransitions ?? false;

  AudioPreviewMixer? _audio;

  /// Silences the preview (used while recording a voice-over).
  set previewMuted(bool value) {
    _previewMuted = value;
    _audio?.muted = value;
    notifyListeners();
  }

  /// True while an export runs: the preview's players are closed so the
  /// export can have the phone's video decoders.
  bool get previewSuspended => _previewSuspended;
  bool _previewSuspended = false;

  Future<void> suspendPreview() async {
    if (_previewSuspended) return;
    pause();
    _previewSuspended = true;
    _audio?.suspend();
    notifyListeners();
    try {
      await _preview?.suspend();
    } catch (_) {}
  }

  void resumePreview() {
    if (!_previewSuspended) return;
    _previewSuspended = false;
    _audio?.resume(project, _playheadUs);
    // Build the player again from scratch.
    _previewSegments = const [];
    _previewShape = null;
    _syncPreviewTimeline();
    notifyListeners();
  }

  bool get previewMuted => _previewMuted;
  bool _previewMuted = false;

  void attachPreview(PreviewPlayer preview, {AudioPreviewMixer? audio}) {
    _preview = preview;
    // Paused: ready for quick scrubbing and frame stepping.
    unawaited(preview.setScrubbing(true));
    _audio = audio?..sync(project, _playheadUs);
    _syncPreviewTimeline();
  }

  List<PreviewSegment> _previewSegments = const [];

  /// Pre-rendered transitions for the preview, by [Project.transitionKey].
  final Map<String, String> transitionFiles = {};

  /// Transitions being prepared for the preview right now (by key).
  final Set<String> transitionsPreparing = {};

  /// Why a transition's preview couldn't be prepared (by key).
  final Map<String, String> transitionErrors = {};

  void setTransitionPreparing(String key, bool preparing) {
    final changed = preparing
        ? transitionsPreparing.add(key)
        : transitionsPreparing.remove(key);
    if (changed) notifyListeners();
  }

  void setTransitionError(String key, String message) {
    transitionErrors[key] = message;
    transitionsPreparing.remove(key);
    notifyListeners();
  }

  /// A pre-rendered transition finished: play it in the preview.
  void addTransitionFile(String key, String path) {
    transitionsPreparing.remove(key);
    if (transitionFiles[key] == path) return;
    transitionFiles[key] = path;
    _syncPreviewTimeline();
    notifyListeners();
  }

  BlendLayers? _previewBlends;

  /// What the preview player was last built from, leaving out filter
  /// values (those can change live, without rebuilding).
  String? _previewShape;

  /// Everything about [segments] except the filter values (whether a clip
  /// has a filter still counts: adding the first one needs a rebuild).
  static String _shapeOf(List<PreviewSegment> segments) => jsonEncode([
    for (final s in segments)
      {
        ...s.toMap()
          ..remove('grade')
          ..remove('transfer')
          ..remove('clipId'),
        'graded': s.clip?.gradeParams != null,
      },
  ]);

  static Map<int, List<double>> _gradesOf(List<PreviewSegment> segments) => {
    for (final s in segments)
      if (s.clip?.gradeParams != null) s.clip!.id: s.clip!.gradeParams!.values,
  };

  /// During a slider drag: if only filter values changed, update them in
  /// the player straight away (no rebuild). Other changes wait for the end.
  void _liveGrades() {
    final p = _preview;
    if (p == null || !p.gradesLive || _previewShape == null) return;
    final segments = segmentsOf(
      project,
      transitionFiles: transitionFiles,
      blend: p.blendsTransitions,
    );
    final shape = _shapeOf(segments);
    if (shape == _previewShape) {
      unawaited(p.setGrades(_gradesOf(segments)));
      return;
    }
    // A clip got (or lost) its filter: rebuild once, then it's live.
    String strip(String s) =>
        s.replaceAll(RegExp(r',"graded":(true|false)'), '');
    if (strip(shape) == strip(_previewShape!)) _syncPreviewTimeline();
  }

  void _syncPreviewTimeline() {
    final p = _preview;
    if (p == null) return;
    final blend = p.blendsTransitions;
    final segments = segmentsOf(
      project,
      transitionFiles: transitionFiles,
      blend: blend,
    );
    final blends = blend ? blendLayersOf(project) : null;
    if (listEquals(segments, _previewSegments) && blends == _previewBlends) {
      return;
    }
    final shape = _shapeOf(segments);
    if (p.gradesLive && shape == _previewShape && blends == _previewBlends) {
      // Only filter values changed: no rebuild needed.
      _previewSegments = segments;
      unawaited(p.setGrades(_gradesOf(segments)));
      return;
    }
    _previewShape = shape;
    _previewSegments = segments;
    _previewBlends = blends;
    final canvas = project.canvas;
    final long = 1920.0;
    final cw = canvas.value >= 1 ? long : long * canvas.value;
    final ch = canvas.value >= 1 ? long / canvas.value : long;
    unawaited(
      p
          .setTimeline(
            segments,
            canvasWidth: (cw / 2).round() * 2,
            canvasHeight: (ch / 2).round() * 2,
            blends: blends,
          )
          .then((_) => _seekPreview(exact: true)),
    );
  }

  bool _seekBusy = false;
  int? _pendingSeekUs;
  bool _pendingExact = true;
  int _pendingToleranceUs = 0;

  // How fast the timeline is being dragged (timeline time per real second),
  // to choose between exact frames (slow) and key frames (fast).
  final _dragClock = Stopwatch()..start();
  int? _lastDragAtUs;
  double _dragSpeed = 0;
  Timer? _restTimer;

  /// Moves the player to the playhead. Seeks are queued so that fast
  /// scrubbing never piles up hundreds of requests: only the latest counts.
  void _seekPreview({required bool exact, int toleranceUs = 0}) {
    final p = _preview;
    if (p == null || !project.hasMedia) return;
    _pendingSeekUs = _playheadUs;
    _pendingExact = exact;
    _pendingToleranceUs = toleranceUs;
    if (_seekBusy) return;
    _seekBusy = true;
    () async {
      while (_pendingSeekUs != null) {
        final target = _pendingSeekUs!;
        final ex = _pendingExact;
        final tol = _pendingToleranceUs;
        _pendingSeekUs = null;
        try {
          await p.seek(target, exact: ex, toleranceUs: tol);
        } catch (_) {}
      }
      _seekBusy = false;
    }();
  }

  /// Call when a drag on the timeline ends: shows the exact frame.
  void settle() {
    _restTimer?.cancel();
    _dragSpeed = 0;
    if (!_playing) _seekPreview(exact: true);
  }

  // ---------------------------------------------------------------------------
  // Playhead and playback
  // ---------------------------------------------------------------------------

  /// Moves the playhead (e.g. while scrubbing). The preview follows quickly;
  /// call [settle] afterwards for the exact frame.
  void seek(int timeUs, {bool exact = false}) {
    final clamped = timeUs.clamp(0, project.durationUs);
    if (clamped == _playheadUs) return;
    final moved = (clamped - _playheadUs).abs();
    _playheadUs = clamped;
    _audio?.follow(project, _playheadUs);
    if (!_playing) {
      if (exact) {
        _seekPreview(exact: true);
      } else {
        _seekPreview(exact: false, toleranceUs: _scrubTolerance(moved));
        // Finger resting (still held down): show the exact frame.
        _restTimer?.cancel();
        _restTimer = Timer(const Duration(milliseconds: 120), () {
          _dragSpeed = 0;
          _lastDragAtUs = null;
          if (!_playing) _seekPreview(exact: true);
        });
      }
    }
    notifyListeners();
  }

  /// How far from the asked-for frame a scrubbing jump may land, from how
  /// fast the playhead is moving: none when slow (exact frames), up to a
  /// second when fast (key frames, which show at once).
  int _scrubTolerance(int movedUs) {
    final now = _dragClock.elapsedMicroseconds;
    final last = _lastDragAtUs;
    _lastDragAtUs = now;
    if (last == null || now - last > 250000) {
      // A new drag: start from exact frames.
      _dragSpeed = 0;
      return 0;
    }
    final dt = math.max(8000, now - last);
    final speed = movedUs / dt; // timeline seconds per real second
    _dragSpeed = 0.6 * _dragSpeed + 0.4 * speed;
    // Up to 3× real time: exact. Faster: a tenth of a second's worth of
    // movement, at most one second.
    if (_dragSpeed < 3) return 0;
    return (_dragSpeed * 100000).round().clamp(0, 1000000);
  }

  /// Moves exactly one frame forward (+1) or back (-1).
  void stepFrame(int direction) {
    pause();
    final fps = project.frameRate;
    final frame = frameIndexAt(_playheadUs, fps) + direction;
    seek(frameStartUs(frame < 0 ? 0 : frame, fps), exact: true);
  }

  void play() {
    if (_playing || project.durationUs == 0) return;
    if (_playheadUs >= project.durationUs - project.frameUs) {
      _playheadUs = 0;
      _seekPreview(exact: true);
    }
    _playing = true;
    if (usesPreview) {
      unawaited(_preview!.setScrubbing(false));
      unawaited(_preview!.play());
    }
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    if (usesPreview) {
      unawaited(_preview!.pause());
      unawaited(_preview!.setScrubbing(true));
    }
    _audio?.stopAll();
    // Land on a whole frame so split points are exact.
    _playheadUs = snapToFrame(
      _playheadUs,
      project.frameRate,
    ).clamp(0, project.durationUs);
    _seekPreview(exact: true);
    notifyListeners();
  }

  void togglePlay() => _playing ? pause() : play();

  /// Called by the screen on every display refresh while playing.
  void advancePlayback(int elapsedUs) {
    if (!_playing) return;
    if (usesPreview) {
      _followPlayer(elapsedUs);
      return;
    }
    final next = _playheadUs + elapsedUs;
    if (next >= project.durationUs) {
      _playheadUs = project.durationUs;
      _playing = false;
    } else {
      _playheadUs = next;
    }
    notifyListeners();
  }

  bool _polling = false;

  /// While playing, the playhead follows the real player's position (with a
  /// smooth estimate in between answers).
  void _followPlayer(int elapsedUs) {
    _playheadUs = (_playheadUs + elapsedUs).clamp(0, project.durationUs);
    _audio?.update(project, _playheadUs, _playing, _preview);
    if (!_polling) {
      _polling = true;
      _preview!.position().then(
        (pos) {
          _polling = false;
          if (!_playing) return;
          _playheadUs = pos.clamp(0, project.durationUs);
          if (_playheadUs >= project.durationUs - project.frameUs) {
            _playheadUs = project.durationUs;
            pause();
          }
          notifyListeners();
        },
        onError: (Object _) {
          _polling = false;
        },
      );
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Zoom and selection
  // ---------------------------------------------------------------------------

  void setZoom(double pixelsPerSecond) {
    final z = pixelsPerSecond.clamp(minPixelsPerSecond, maxPixelsPerSecond);
    if (z == _pixelsPerSecond) return;
    _pixelsPerSecond = z;
    notifyListeners();
  }

  void select(int? clipId) {
    if (clipId == _selectedClipId) return;
    _selectedClipId = clipId;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Edits
  // ---------------------------------------------------------------------------

  /// Records an edit made elsewhere (one undo step).
  void apply(Project next) => _apply(next);

  void _apply(Project next) {
    // Sound, text and picture-in-picture stay with their video frames.
    history.apply(settleLayers(project, next));
    _afterChange();
  }

  void _afterChange() {
    if (_selectedClipId != null &&
        project.placementOf(_selectedClipId!) == null) {
      _selectedClipId = null;
    }
    _playheadUs = _playheadUs.clamp(0, project.durationUs);
    if (!history.inGesture) {
      _syncPreviewTimeline();
      _audio?.sync(project, _playheadUs);
      _audio?.stopAll();
    }
    notifyListeners();
  }

  /// Adds imported clips after the clip under the playhead.
  void insertMedia(List<Clip> clips) {
    if (clips.isEmpty) return;
    final wasEmpty = project.mainTrack.clips.isEmpty;
    _apply(
      project.insertMedia(clips, index: project.insertIndexAt(_playheadUs)),
    );
    if (wasEmpty) _exportSettings = null; // re-suggest from the new clips
  }

  /// Splits the selected clip at the playhead (or the main clip under the
  /// playhead if nothing is selected). Returns false if there was nothing to
  /// split there.
  bool splitAtPlayhead() {
    pause();
    final t = snapToFrame(_playheadUs, project.frameRate);
    final sel = selected;
    final target = sel != null && sel.contains(t) ? sel.clip.id : null;
    final next = project.splitAt(t, clipId: target);
    if (identical(next, project)) return false;
    _apply(next);
    return true;
  }

  void duplicateSelected() {
    final id = _selectedClipId;
    if (id == null) return;
    _apply(project.duplicateClip(id));
  }

  void deleteSelected() {
    final id = _selectedClipId;
    if (id == null) return;
    _apply(project.deleteClip(id));
  }

  void setCanvas(CanvasRatio canvas) => _apply(project.withCanvas(canvas));

  // ---------------------------------------------------------------------------
  // Clip adjustments (Stage 2)
  // ---------------------------------------------------------------------------

  /// Changes the selected clip (one undo step).
  void updateSelected(Clip Function(Clip c) change) {
    final id = _selectedClipId;
    if (id == null) return;
    _apply(project.updateClip(id, change));
  }

  void rotateSelected() => updateSelected((c) {
    // Turning swaps the crop's sides around with the picture.
    CropRect turn(CropRect r) =>
        CropRect(1 - r.bottom, r.left, 1 - r.top, r.right);
    final next = c.copyWith(
      rotation: c.rotation + 1,
      crop: turn(c.crop),
      fillFrom: c.fillFrom == null ? null : turn(c.fillFrom!),
    );
    // A clip that fills the frame is cut again for its new shape.
    return next.fills ? next.filled(project.canvas.value) : next;
  });

  void mirrorSelected() => updateSelected((c) {
    CropRect flip(CropRect r) =>
        CropRect(1 - r.right, r.top, 1 - r.left, r.bottom);
    return c.copyWith(
      flipH: !c.flipH,
      crop: flip(c.crop),
      fillFrom: c.fillFrom == null ? null : flip(c.fillFrom!),
    );
  });

  /// Fill frame: the selected clip covers the whole frame (the edges that
  /// don't fit are cut off). Fit frame: the whole picture shows, with bars
  /// or background around it.
  void toggleFillSelected() => updateSelected(
    (c) => c.fills ? c.fitted() : c.filled(project.canvas.value),
  );

  /// Sets the selected clip's crop. When it is the only video, the frame
  /// takes the new shape too (one undo step); returns whether it did.
  bool cropSelected(CropRect rect) {
    final id = _selectedClipId;
    if (id == null) return false;
    var next = project.updateClip(
      id,
      (x) => x.copyWith(crop: rect, clearFill: true),
    );
    final only =
        next.mainTrack.clips.length == 1 && next.mainTrack.clips.first.id == id;
    if (only) {
      next = next.withCanvas(Project.shapeOf(next.mainTrack.clips.first));
    }
    _apply(next);
    return only;
  }

  /// Gives the frame the selected clip's shape.
  void matchCanvasToSelected() {
    final clip = selected?.clip;
    if (clip == null) return;
    setCanvas(Project.shapeOf(clip));
  }

  /// Moves the selected video clip's sound to an audio track.
  void extractAudioOfSelected() {
    final id = _selectedClipId;
    if (id == null) return;
    _apply(project.extractAudio(id));
  }

  /// A reversed copy finished: give it to the clip (if it still wants it).
  void attachReverseProxy(int clipId, ReverseProxy proxy) {
    final next = project.updateClip(
      clipId,
      (x) => x.reversed && proxy.covers(x.sourceInUs, x.sourceOutUs)
          ? x.copyWith(reverseProxy: proxy)
          : x,
    );
    if (identical(next, project)) return;
    history.replaceCurrent(next);
    _afterChange();
  }

  /// Sets (or removes) the transition after main clip [index].
  void setTransition(int index, TransitionSpec? spec) =>
      _apply(project.setTransition(index, spec));

  /// The same transition between every pair of clips.
  void setAllTransitions(TransitionSpec? spec) {
    var p = project;
    for (var i = 0; i + 1 < p.mainTrack.clips.length; i++) {
      p = p.setTransition(i, spec);
    }
    _apply(p);
  }

  void setBackground(BackgroundFill fill) =>
      _apply(project.withBackground(fill));

  /// Live changes while a slider is being dragged; [endLiveEdit] makes them
  /// one undo step.
  void liveEdit(Project Function(Project base) change) {
    final base = history.beginGesture();
    history.updateGesture(settleLayers(base, change(base)));
    _playheadUs = _playheadUs.clamp(0, project.durationUs);
    notifyListeners();
    _liveGrades();
    // Sound-effect sliders are heard straight away.
    _audio?.sync(project, _playheadUs);
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _restTimer?.cancel();
    super.dispose();
  }

  void endLiveEdit() {
    // (A tool panel can close after the editor has gone.)
    if (_disposed || !history.inGesture) return;
    history.endGesture();
    _afterChange();
  }

  void cancelLiveEdit() {
    if (!history.inGesture) return;
    history.cancelGesture();
    _afterChange();
  }

  void rename(String name) => _apply(project.renamed(name));

  void undo() {
    history.undo();
    _afterChange();
  }

  void redo() {
    history.redo();
    _afterChange();
  }

  // ---------------------------------------------------------------------------
  // Trimming by dragging a clip's edge
  // ---------------------------------------------------------------------------

  int? _trimClipId;
  bool _trimStart = false;
  int _trimPlayheadStart = 0;

  void beginTrim(int clipId, {required bool start}) {
    pause();
    history.beginGesture();
    _trimClipId = clipId;
    _trimStart = start;
    _trimPlayheadStart = _playheadUs;
  }

  /// [deltaUs] is the total drag distance since [beginTrim], in timeline time.
  void updateTrim(int deltaUs) {
    final id = _trimClipId;
    if (id == null) return;
    final base = history.beginGesture();
    final snapped = snapToFrame(deltaUs, base.frameRate);
    final next = _trimStart
        ? base.trimStart(id, snapped)
        : base.trimEnd(id, snapped);
    history.updateGesture(settleLayers(base, next));

    // When the start of a main-track clip is trimmed, everything after it
    // slides left. Moving the playhead back by the same amount keeps the
    // dragged edge under your finger.
    final before = base.placementOf(id);
    final after = next.placementOf(id);
    if (_trimStart &&
        before != null &&
        after != null &&
        before.track.kind == TrackKind.main) {
      final shortenedBy = before.clip.durationUs - after.clip.durationUs;
      _playheadUs = (_trimPlayheadStart - shortenedBy).clamp(
        0,
        next.durationUs,
      );
    } else {
      _playheadUs = _playheadUs.clamp(0, next.durationUs);
    }
    notifyListeners();
  }

  void endTrim() {
    if (_trimClipId == null) return;
    _trimClipId = null;
    history.endGesture();
    _afterChange();
  }
}
