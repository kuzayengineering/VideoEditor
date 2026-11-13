import 'project.dart';

/// The exported video's name: the newest recording among the main video's
/// clips (by the date it was recorded; else the last clip), with its first
/// three letters (such as PXL or IMG) replaced by KVE:
/// "PXL_20261112_093015123" → "KVE_20261112_093015123.mp4".
String exportFileName(Project project) {
  final media = [
    for (final c in project.mainTrack.clips)
      if (c.isMedia) c,
  ];
  final dated = [
    for (final c in media)
      if (c.media!.createdAtMs != null) c,
  ];
  Clip? pick;
  if (dated.isNotEmpty) {
    pick = dated.reduce(
      (a, b) => b.media!.createdAtMs! >= a.media!.createdAtMs! ? b : a,
    );
  } else if (media.isNotEmpty) {
    pick = media.last;
  }
  var stem = pick?.name.trim() ?? '';
  stem = stem.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (stem.isEmpty) {
    final safe = project.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    stem = safe.isEmpty ? 'Video' : safe;
    return 'KVE_$stem.mp4';
  }
  if (RegExp(r'^[A-Za-z]{3}').hasMatch(stem)) {
    return 'KVE${stem.substring(3)}.mp4';
  }
  return 'KVE_$stem.mp4';
}

/// [fileName] with a number on the end of its name, for when that name is
/// already taken: "KVE_1.mp4", 2 → "KVE_1_2.mp4".
String numberedFileName(String fileName, int n) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final ext = dot > 0 ? fileName.substring(dot) : '';
  return '${stem}_$n$ext';
}
