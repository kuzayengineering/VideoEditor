import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/ffmpeg/ffmpeg_engine.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/missing_files.dart';

const s = usPerSecond;

const trip = MediaInfo(durationUs: 20 * s, width: 1920, height: 1080);
const beach = MediaInfo(durationUs: 7 * s, width: 3840, height: 2160);

Clip video(String name, String source, MediaInfo info) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: name,
  sourcePath: source,
  media: info,
  sourceDurationUs: info.durationUs,
  sourceInUs: 0,
  sourceOutUs: info.durationUs,
);

void main() {
  test('relinking fixes every clip that used the file, on every row', () {
    var p = Project.empty(id: 'p', frameRate: 30).insertMedia([
      video('Trip', 'old/trip.mp4', trip),
      video('Beach', 'beach.mp4', beach),
    ]);
    p = p.splitAt(5 * s); // two clips from trip.mp4
    p = p.extractAudio(p.mainTrack.clips.first.id); // and its sound
    expect(p.mediaSources['old/trip.mp4']!.length, 3);

    p = p.relinkSource('old/trip.mp4', 'new/trip.mp4');
    expect(p.mediaSources.containsKey('old/trip.mp4'), isFalse);
    expect(p.mediaSources['new/trip.mp4']!.length, 3);
    expect(p.mediaSources['beach.mp4'], ['Beach']);
  });

  test('missing files are matched by name, checked by length', () async {
    const missing = [
      MissingFile('content://old/1', ['Trip', 'Trip (sound)'], trip),
      MissingFile('content://old/2', ['Beach'], beach),
    ];
    final files = [
      const PickedMedia('content://new/a', 'Other.mp4'),
      // Same name, different recording: not it.
      const PickedMedia('content://new/b', 'Beach.mp4'),
      const PickedMedia('content://new/c', 'TRIP.MP4'),
      // Renamed, but the same length and size.
      const PickedMedia('content://new/d', 'IMG_0042.mov'),
    ];
    final infos = {
      'content://new/a': const MediaInfo(
        durationUs: 3 * s,
        width: 1,
        height: 1,
      ),
      'content://new/b': const MediaInfo(
        durationUs: 60 * s,
        width: 1,
        height: 1,
      ),
      'content://new/c': trip,
      'content://new/d': beach,
    };
    final found = await matchMissing(
      missing,
      files,
      (src) async => infos[src]!,
    );
    expect(found, {
      'content://old/1': 'content://new/c',
      'content://old/2': 'content://new/d',
    });
  });

  test('Windows: missing files are noticed and found in a folder', () async {
    final dir = await Directory.systemTemp.createTemp('vc_missing');
    addTearDown(() => dir.delete(recursive: true));
    final here = File('${dir.path}/a.mp4')..writeAsStringSync('x');
    final sub = Directory('${dir.path}/moved/deeper')
      ..createSync(recursive: true);
    File('${sub.path}/trip.MP4').writeAsStringSync('x');
    File('${sub.path}/notes.txt').writeAsStringSync('x');

    final engine = FfmpegEngine(ffmpegPath: 'ffmpeg', ffprobePath: 'ffprobe');
    final gone = '${dir.path}/trip.mp4';
    expect(await engine.missingSources([here.path, gone]), {gone});
    final files = await engine.mediaFilesIn(dir.path);
    expect(files.map((f) => f.displayName).toSet(), {'a.mp4', 'trip.MP4'});
  });
}
