import 'package:flutter/foundation.dart';

import '../model/export_settings.dart';
import '../model/history.dart';
import '../model/project.dart';
import '../model/timecode.dart';

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

  ExportSettings exportSettings = const ExportSettings();

  // ---------------------------------------------------------------------------
  // Playhead and playback
  // ---------------------------------------------------------------------------

  void seek(int timeUs) {
    final clamped = timeUs.clamp(0, project.durationUs);
    if (clamped == _playheadUs) return;
    _playheadUs = clamped;
    notifyListeners();
  }

  /// Moves exactly one frame forward (+1) or back (-1).
  void stepFrame(int direction) {
    pause();
    final fps = project.frameRate;
    final frame = frameIndexAt(_playheadUs, fps) + direction;
    seek(frameStartUs(frame < 0 ? 0 : frame, fps));
  }

  void play() {
    if (_playing || project.durationUs == 0) return;
    if (_playheadUs >= project.durationUs) _playheadUs = 0;
    _playing = true;
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    // Land on a whole frame so split points are exact.
    _playheadUs = snapToFrame(
      _playheadUs,
      project.frameRate,
    ).clamp(0, project.durationUs);
    notifyListeners();
  }

  void togglePlay() => _playing ? pause() : play();

  /// Called by the screen on every display refresh while playing.
  void advancePlayback(int elapsedUs) {
    if (!_playing) return;
    final next = _playheadUs + elapsedUs;
    if (next >= project.durationUs) {
      _playheadUs = project.durationUs;
      _playing = false;
    } else {
      _playheadUs = next;
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
    notifyListeners();
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
