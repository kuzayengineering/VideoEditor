import 'dart:async';

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
  EditorController(Project project) : history = EditHistory(project);

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
  double _pixelsPerSecond = 60;
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
  bool get previewDrawsEffects =>
      _preview?.drawsEffects(segmentsOf(project)) ?? false;

  AudioPreviewMixer? _audio;

  /// Silences the preview (used while recording a voice-over).
  set previewMuted(bool value) => _audio?.muted = value;

  void attachPreview(PreviewPlayer preview, {AudioPreviewMixer? audio}) {
    _preview = preview;
    _audio = audio?..sync(project);
    _syncPreviewTimeline();
  }

  List<PreviewSegment> _previewSegments = const [];

  void _syncPreviewTimeline() {
    final p = _preview;
    if (p == null) return;
    final segments = segmentsOf(project);
    if (listEquals(segments, _previewSegments)) return;
    _previewSegments = segments;
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
          )
          .then((_) => _seekPreview(exact: true)),
    );
  }

  bool _seekBusy = false;
  int? _pendingSeekUs;
  bool _pendingExact = true;

  /// Moves the player to the playhead. Seeks are queued so that fast
  /// scrubbing never piles up hundreds of requests: only the latest counts.
  void _seekPreview({required bool exact}) {
    final p = _preview;
    if (p == null || !project.hasMedia) return;
    _pendingSeekUs = _playheadUs;
    _pendingExact = exact;
    if (_seekBusy) return;
    _seekBusy = true;
    () async {
      while (_pendingSeekUs != null) {
        final target = _pendingSeekUs!;
        final ex = _pendingExact;
        _pendingSeekUs = null;
        try {
          await p.seek(target, exact: ex);
        } catch (_) {}
      }
      _seekBusy = false;
    }();
  }

  /// Call when a drag on the timeline ends: shows the exact frame.
  void settle() {
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
    _playheadUs = clamped;
    if (!_playing) _seekPreview(exact: exact);
    notifyListeners();
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
    if (usesPreview) unawaited(_preview!.play());
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    if (usesPreview) unawaited(_preview!.pause());
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
    history.apply(next);
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
      _audio?.sync(project);
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

  void rotateSelected() => updateSelected(
    // Turning swaps the crop's sides around with the picture.
    (c) => c.copyWith(
      rotation: c.rotation + 1,
      crop: CropRect(
        1 - c.crop.bottom,
        c.crop.left,
        1 - c.crop.top,
        c.crop.right,
      ),
    ),
  );

  void mirrorSelected() => updateSelected(
    (c) => c.copyWith(
      flipH: !c.flipH,
      crop: CropRect(
        1 - c.crop.right,
        c.crop.top,
        1 - c.crop.left,
        c.crop.bottom,
      ),
    ),
  );

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

  void setBackground(BackgroundFill fill) =>
      _apply(project.withBackground(fill));

  /// Live changes while a slider is being dragged; [endLiveEdit] makes them
  /// one undo step.
  void liveEdit(Project Function(Project base) change) {
    final base = history.beginGesture();
    history.updateGesture(change(base));
    _playheadUs = _playheadUs.clamp(0, project.durationUs);
    notifyListeners();
  }

  void endLiveEdit() {
    if (!history.inGesture) return;
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
    history.updateGesture(next);

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
