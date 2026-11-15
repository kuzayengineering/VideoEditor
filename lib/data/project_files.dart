import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';

/// Files the app made for projects and keeps in its own storage: reversed
/// copies of clips, voice-over recordings, ready-made preview copies of
/// transitions and speed changes, timeline pictures and text pictures.
/// They're removed with the project that used them (unless another
/// project still uses the same file, e.g. a duplicate).
class ProjectFiles {
  ProjectFiles(
    this.engine, {
    Future<Directory> Function()? support,
    Future<Directory> Function()? cache,
  }) : _support = support ?? getApplicationSupportDirectory,
       _cache = cache ?? getApplicationCacheDirectory;

  final MediaEngine engine;
  final Future<Directory> Function() _support;
  final Future<Directory> Function() _cache;

  static Iterable<Clip> _clips(Project p) sync* {
    for (final t in [p.mainTrack, ...p.overlayTracks, ...p.audioTracks]) {
      yield* t.clips;
    }
  }

  /// Paths of files the app made that [p] uses.
  static Set<String> ownFilesOf(Project p, String supportPath) => {
    for (final c in _clips(p)) ...[
      if (c.reverseProxy != null) c.reverseProxy!.path,
      if (c.sourcePath != null && _inside(c.sourcePath!, supportPath))
        c.sourcePath!,
    ],
  };

  /// Names of [p]'s ready-made preview copies (transitions, speed changes).
  static Set<String> previewKeysOf(Project p) => {
    for (var i = 0; i < p.mainTrack.clips.length; i++) ...[
      if (i + 1 < p.mainTrack.clips.length && p.transitionUsAfter(i) > 0)
        p.transitionKey(i),
      p.speedKey(i),
    ],
  }..remove('');

  static Set<String> sourcesOf(Project p) => {
    for (final c in _clips(p))
      if (c.sourcePath != null) c.sourcePath!,
  };

  static bool _inside(String path, String dir) =>
      path.startsWith(dir) && path.length > dir.length;

  Future<void> _delete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Removes [deleted]'s files that none of [remaining] uses.
  Future<void> deleteFilesOf(Project deleted, List<Project> remaining) async {
    final support = (await _support()).path;
    final cache = (await _cache()).path;
    final keepFiles = {for (final p in remaining) ...ownFilesOf(p, support)};
    for (final f in ownFilesOf(deleted, support)) {
      if (!keepFiles.contains(f)) await _delete(f);
    }
    final keepKeys = {for (final p in remaining) ...previewKeysOf(p)};
    for (final k in previewKeysOf(deleted)) {
      if (keepKeys.contains(k)) continue;
      await _delete('$cache/transitions/$k.mp4');
      await _delete('$cache/transitions/$k.mp4.part.mp4');
    }
    final keepSources = {for (final p in remaining) ...sourcesOf(p)};
    final gone = sourcesOf(deleted).difference(keepSources);
    if (gone.isNotEmpty) {
      try {
        await engine.deleteThumbnails(gone);
      } catch (_) {}
    }
    try {
      final texts = Directory(
        '${Directory.systemTemp.path}/video_editor_texts_${deleted.id}',
      );
      if (await texts.exists()) await texts.delete(recursive: true);
    } catch (_) {}
  }

  /// Removes reversed copies, voice-overs and preview copies that no saved
  /// project uses any more (left over from trims, deleted clips and older
  /// versions). Call only while no project is open.
  /// Files changed in the last [recent] are always kept (a project's
  /// latest save may still be on its way).
  Future<void> sweep(
    List<Project> all, {
    Duration recent = const Duration(hours: 1),
  }) async {
    final support = (await _support()).path;
    final cache = (await _cache()).path;
    final cutoff = DateTime.now().subtract(recent);
    Future<bool> old(File f) async {
      try {
        return (await f.lastModified()).isBefore(cutoff);
      } catch (_) {
        return false;
      }
    }

    final used = {for (final p in all) ...ownFilesOf(p, support)};
    for (final dir in ['reversed', 'voiceovers']) {
      final d = Directory('$support/$dir');
      if (!await d.exists()) continue;
      await for (final e in d.list()) {
        if (e is File && !used.contains(e.path) && await old(e)) {
          await _delete(e.path);
        }
      }
    }
    final keys = {for (final p in all) ...previewKeysOf(p)};
    final t = Directory('$cache/transitions');
    if (await t.exists()) {
      await for (final e in t.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final key = name.split('.').first;
        if (!keys.contains(key) && await old(e)) await _delete(e.path);
      }
    }
  }
}
