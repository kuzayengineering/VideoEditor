import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/data/project_files.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

const s = usPerSecond;

class _Engine implements MediaEngine {
  final thumbsDeleted = <String>{};
  @override
  Future<void> deleteThumbnails(Set<String> sources) async =>
      thumbsDeleted.addAll(sources);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root, support, cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('vc_files');
    support = await Directory('${root.path}/support').create();
    cache = await Directory('${root.path}/cache').create();
    await Directory('${support.path}/reversed').create();
    await Directory('${support.path}/voiceovers').create();
    await Directory('${cache.path}/transitions').create();
  });
  tearDown(() => root.delete(recursive: true));

  File make(String path) => File(path)..writeAsStringSync('x');

  Clip video(String name, {ReverseProxy? proxy, bool reversed = false}) => Clip(
    id: 0,
    kind: ClipKind.video,
    name: name,
    sourcePath: '/videos/$name.mp4',
    media: const MediaInfo(durationUs: 10 * s, width: 1920, height: 1080),
    sourceDurationUs: 10 * s,
    sourceInUs: 0,
    sourceOutUs: 4 * s,
    reversed: reversed,
    reverseProxy: proxy,
  );

  test(
    'deleting a project deletes the files made for it, not shared ones',
    () async {
      final mine = make('${support.path}/reversed/mine.mp4');
      final shared = make('${support.path}/reversed/shared.mp4');
      final voice = make('${support.path}/voiceovers/voiceover_1.m4a');
      var p = Project.empty(id: 'p1', frameRate: 30).insertMedia([
        video('a', reversed: true, proxy: ReverseProxy(mine.path, 0, 4 * s)),
        video('b', reversed: true, proxy: ReverseProxy(shared.path, 0, 4 * s)),
      ]);
      p = p.updateClip(p.mainTrack.clips[1].id, (c) => c.copyWith(speed: 0.5));
      p = p.addAudio(
        Clip(
          id: 0,
          kind: ClipKind.audio,
          name: 'Voice-over 1',
          sourcePath: voice.path,
          media: const MediaInfo(durationUs: 3 * s, width: 0, height: 0),
          sourceDurationUs: 3 * s,
          sourceInUs: 0,
          sourceOutUs: 3 * s,
        ),
      );
      final speedCopy = make('${cache.path}/transitions/${p.speedKey(1)}.mp4');
      // Another project uses clip b's reversed copy (and file b).
      final other = Project.empty(id: 'p2', frameRate: 30).insertMedia([
        video('b', reversed: true, proxy: ReverseProxy(shared.path, 0, 4 * s)),
      ]);

      final engine = _Engine();
      await ProjectFiles(
        engine,
        support: () async => support,
        cache: () async => cache,
      ).deleteFilesOf(p, [other]);

      expect(mine.existsSync(), isFalse);
      expect(voice.existsSync(), isFalse);
      expect(speedCopy.existsSync(), isFalse);
      expect(shared.existsSync(), isTrue);
      expect(engine.thumbsDeleted, {'/videos/a.mp4', voice.path});
    },
  );

  test('the sweep removes files no project uses (but not new ones)', () async {
    final used = make('${support.path}/reversed/used.mp4');
    final orphan = make('${support.path}/reversed/old.mp4');
    final oldPreview = make('${cache.path}/transitions/sdeadbeef.mp4');
    final p = Project.empty(id: 'p1', frameRate: 30).insertMedia([
      video('a', reversed: true, proxy: ReverseProxy(used.path, 0, 4 * s)),
    ]);
    final files = ProjectFiles(
      _Engine(),
      support: () async => support,
      cache: () async => cache,
    );
    // Brand new files are left alone (a save may still be on its way)...
    await files.sweep([p]);
    expect(orphan.existsSync(), isTrue);
    // ...older ones go.
    await files.sweep([p], recent: Duration.zero);
    expect(orphan.existsSync(), isFalse);
    expect(oldPreview.existsSync(), isFalse);
    expect(used.existsSync(), isTrue);
  });
}
