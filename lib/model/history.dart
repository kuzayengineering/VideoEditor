import 'project.dart';

/// Undo / redo for a project.
///
/// Because projects are never changed in place, the history is simply a list
/// of earlier versions.
class EditHistory {
  EditHistory(Project initial, {this.limit = 300}) : _current = initial;

  /// How many steps back you can undo.
  final int limit;

  final List<Project> _undo = [];
  final List<Project> _redo = [];
  Project _current;
  Project? _gestureStart;

  Project get current => _current;
  bool get canUndo => _gestureStart == null && _undo.isNotEmpty;
  bool get canRedo => _gestureStart == null && _redo.isNotEmpty;

  /// True while a drag (such as trimming) is in progress.
  bool get inGesture => _gestureStart != null;

  /// Records a finished edit. Edits that change nothing are ignored.
  void apply(Project next) {
    if (identical(next, _current)) return;
    _push(_current);
    _current = next;
  }

  void _push(Project previous) {
    _undo.add(previous);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(_current);
    _current = _undo.removeLast();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_current);
    _current = _redo.removeLast();
  }

  /// Starts a drag. Updates during the drag are shown immediately but only
  /// count as one undo step once [endGesture] is called.
  Project beginGesture() {
    _gestureStart ??= _current;
    return _gestureStart!;
  }

  void updateGesture(Project preview) {
    assert(_gestureStart != null, 'updateGesture called without beginGesture');
    _current = preview;
  }

  void endGesture() {
    final start = _gestureStart;
    if (start == null) return;
    _gestureStart = null;
    if (!identical(start, _current)) _push(start);
  }

  /// Abandons a drag and goes back to how things were before it started.
  void cancelGesture() {
    final start = _gestureStart;
    if (start == null) return;
    _gestureStart = null;
    _current = start;
  }
}
