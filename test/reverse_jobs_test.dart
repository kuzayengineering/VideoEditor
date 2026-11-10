import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/ui/reverse_jobs.dart';

class _FakeEngine implements MediaEngine {
  final List<String> calls = [];
  final Map<String, Completer<void>> gates = {};

  @override
  Future<ReverseProxy> prepareReverse(
    Clip clip, {
    void Function(double fraction)? onProgress,
  }) async {
    calls.add(clip.name);
    onProgress?.call(0.5);
    await (gates[clip.name] ??= Completer<void>()).future;
    if (clip.name == 'bad') throw Exception('cannot');
    return ReverseProxy('${clip.name}.rev', clip.sourceInUs, clip.sourceOutUs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Clip clip(String name) => Clip(
  id: name.hashCode,
  kind: ClipKind.video,
  name: name,
  sourcePath: '$name.mp4',
  media: const MediaInfo(durationUs: 10000000, width: 1920, height: 1080),
  sourceDurationUs: 10000000,
  sourceInUs: 0,
  sourceOutUs: 5000000,
  reversed: true,
);

void main() {
  test(
    'jobs run one at a time, share duplicates, and report progress',
    () async {
      final engine = _FakeEngine();
      final jobs = ReverseJobs(engine);
      final a1 = jobs.start(clip('a'));
      final a2 = jobs.start(clip('a')); // same clip: same job
      final b = jobs.start(clip('b'));
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, ['a']); // b waits its turn
      expect(jobs.progressFor(clip('a')), 0.5);
      expect(jobs.busy, isTrue);

      engine.gates['a']!.complete();
      final p1 = await a1;
      expect(identical(p1, await a2), isTrue);
      expect(p1.path, 'a.rev');
      expect(jobs.progressFor(clip('a')), isNull);

      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, ['a', 'b']);
      engine.gates['b']!.complete();
      expect((await b).path, 'b.rev');
      expect(jobs.busy, isFalse);
    },
  );

  test('a failure is reported and can be retried', () async {
    final engine = _FakeEngine();
    final jobs = ReverseJobs(engine);
    final f = jobs.start(clip('bad'));
    await Future<void>.delayed(Duration.zero);
    engine.gates['bad']!.complete();
    await expectLater(f, throwsException);
    engine.gates.remove('bad');
    jobs.start(clip('bad')).ignore();
    await Future<void>.delayed(Duration.zero);
    expect(engine.calls, ['bad', 'bad']);
  });
}
