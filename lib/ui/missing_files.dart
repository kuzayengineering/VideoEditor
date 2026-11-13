import 'package:flutter/material.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';
import 'editor_controller.dart';
import 'import_media.dart';

/// A media file the project uses that can't be opened any more.
class MissingFile {
  const MissingFile(this.source, this.clipNames, this.media);

  final String source;
  final List<String> clipNames;
  final MediaInfo? media;

  /// What to call it: the name of (most of) its clips.
  String get name => clipNames.isEmpty ? 'A file' : clipNames.first;
}

/// The files of [project] that can't be opened.
Future<List<MissingFile>> findMissing(
  MediaEngine engine,
  Project project,
) async {
  final sources = project.mediaSources;
  if (sources.isEmpty) return const [];
  final missing = await engine.missingSources(sources.keys);
  MediaInfo? mediaOf(String s) {
    for (final t in [
      project.mainTrack,
      ...project.overlayTracks,
      ...project.audioTracks,
    ]) {
      for (final c in t.clips) {
        if (c.sourcePath == s) return c.media;
      }
    }
    return null;
  }

  return [
    for (final s in missing)
      MissingFile(s, sources[s]!.toSet().toList(), mediaOf(s)),
  ];
}

/// The clip name a file of [fileName] would have had ("Trip.MP4" → "trip"),
/// for comparing.
String _key(String name) {
  var n = name.toLowerCase().trim();
  // Extracted sound is called "<video> (sound)".
  if (n.endsWith(' (sound)')) n = n.substring(0, n.length - 8);
  return n;
}

/// Whether [info] is the same recording as [want] (length within a
/// second, same picture size).
bool sameRecording(MediaInfo? want, MediaInfo info) {
  if (want == null) return true;
  if ((want.durationUs - info.durationUs).abs() > 1000000) return false;
  if (want.hasVideo &&
      (want.width != info.width || want.height != info.height)) {
    // A turned phone video can report its size either way round.
    return want.width == info.height && want.height == info.width;
  }
  return true;
}

/// Finds each of [missing] among [files] (a folder's contents): by name,
/// checked by length and size; if the name changed, by length and size
/// alone. Returns old source → new source.
Future<Map<String, String>> matchMissing(
  List<MissingFile> missing,
  List<PickedMedia> files,
  Future<MediaInfo> Function(String source) probe,
) async {
  final found = <String, String>{};
  final used = <String>{};
  final probed = <String, MediaInfo?>{};
  Future<MediaInfo?> info(String source) async {
    if (probed.containsKey(source)) return probed[source];
    try {
      return probed[source] = await probe(source);
    } catch (_) {
      return probed[source] = null;
    }
  }

  // By name first.
  for (final m in missing) {
    final names = {for (final n in m.clipNames) _key(n)};
    for (final f in files) {
      if (used.contains(f.source)) continue;
      if (!names.contains(_key(niceFileName(f.displayName)))) continue;
      final i = await info(f.source);
      if (i != null && sameRecording(m.media, i)) {
        found[m.source] = f.source;
        used.add(f.source);
        break;
      }
    }
  }
  // Renamed: by length and picture size (a few dozen files at most).
  final rest = [
    for (final m in missing)
      if (!found.containsKey(m.source) && m.media != null) m,
  ];
  if (rest.isNotEmpty) {
    var tried = 0;
    for (final f in files) {
      if (rest.isEmpty || tried >= 60) break;
      if (used.contains(f.source)) continue;
      tried++;
      final i = await info(f.source);
      if (i == null) continue;
      for (final m in rest) {
        if ((m.media!.durationUs - i.durationUs).abs() <= 50000 &&
            sameRecording(m.media, i)) {
          found[m.source] = f.source;
          used.add(f.source);
          rest.remove(m);
          break;
        }
      }
    }
  }
  return found;
}

/// The strip shown above the video while files are missing.
class MissingFilesBar extends StatelessWidget {
  const MissingFilesBar({
    super.key,
    required this.missing,
    required this.onFind,
  });

  final List<MissingFile> missing;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = missing.length;
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.link_off, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                n == 1
                    ? '"${missing.first.name}" can\'t be found (moved, renamed '
                          'or deleted).'
                    : '$n files can\'t be found (moved, renamed or deleted).',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onFind, child: const Text('Find')),
          ],
        ),
      ),
    );
  }
}

/// Asks for the folder the missing files are in now, finds them there and
/// points every clip that used them at the new place (one undo step).
/// Returns the files still missing afterwards.
Future<List<MissingFile>> findMovedFiles(
  BuildContext context,
  EditorController c,
  MediaEngine engine,
  List<MissingFile> missing,
) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        missing.length == 1
            ? 'Find the missing file'
            : 'Find the missing files',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in missing)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '• ${m.name}'
                  '${m.clipNames.length > 1 ? ' (${m.clipNames.length} clips)' : ''}',
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'Choose the folder they are in now. Its subfolders are searched '
              'too, and every clip using a file is fixed.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Choose folder'),
        ),
      ],
    ),
  );
  if (go != true) return missing;
  final folder = await engine.pickSearchFolder();
  if (folder == null || !context.mounted) return missing;

  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(content: Text('Looking…'), duration: Duration(seconds: 30)),
  );
  Map<String, String> found = const {};
  try {
    final files = await engine.mediaFilesIn(folder);
    found = await matchMissing(missing, files, engine.probe);
  } catch (_) {}
  messenger.hideCurrentSnackBar();
  if (found.isNotEmpty) {
    var p = c.project;
    for (final e in found.entries) {
      p = p.relinkSource(e.key, e.value);
    }
    c.apply(p);
  }
  final left = [
    for (final m in missing)
      if (!found.containsKey(m.source)) m,
  ];
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        found.isEmpty
            ? 'Not found in that folder.'
            : left.isEmpty
            ? 'Found. All clips are connected again.'
            : 'Found ${found.length} of ${missing.length}. '
                  '${left.length} still missing.',
      ),
    ),
  );
  return left;
}
