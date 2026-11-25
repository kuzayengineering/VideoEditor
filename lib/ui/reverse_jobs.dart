import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';

/// Makes reversed copies in the background, one at a time, so editing can
/// carry on meanwhile. Each copy is identified by its file and range, so
/// asking twice for the same thing just waits for the first request.
class ReverseJobs extends ChangeNotifier {
  ReverseJobs(this.engine);

  final MediaEngine engine;
  final Map<String, _Job> _jobs = {};
  Future<void> _queue = Future.value();
  bool _disposed = false;

  static String keyOf(Clip c) =>
      '${c.sourcePath}|${c.sourceInUs}|${c.sourceOutUs}';

  /// 0.0–1.0 while the copy for [c] is being made, otherwise null.
  double? progressFor(Clip c) {
    final job = _jobs[keyOf(c)];
    return job == null || job.done ? null : job.progress;
  }

  bool get busy => _jobs.values.any((j) => !j.done);

  /// The progress of every copy still being made (0.0–1.0 each).
  List<double> get running => [
    for (final j in _jobs.values)
      if (!j.done) j.progress,
  ];

  /// Starts (or joins) making the reversed copy for [c].
  Future<ReverseProxy> start(Clip c) {
    final key = keyOf(c);
    final existing = _jobs[key];
    if (existing != null && !existing.failed) return existing.completer.future;
    final job = _Job();
    // Errors are reported to whoever asked; don't also flag them as unhandled.
    job.completer.future.ignore();
    _jobs[key] = job;
    notifyListeners();
    _queue = _queue.then((_) async {
      try {
        final proxy = await engine.prepareReverse(
          c,
          onProgress: (f) {
            job.progress = f;
            if (!_disposed) notifyListeners();
          },
        );
        job.done = true;
        job.completer.complete(proxy);
      } catch (e) {
        job.done = true;
        job.failed = true;
        job.completer.completeError(e);
      }
      if (!_disposed) notifyListeners();
    });
    return job.completer.future;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _Job {
  final completer = Completer<ReverseProxy>();
  double progress = 0;
  bool done = false;
  bool failed = false;
}
