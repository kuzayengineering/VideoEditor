import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/data/project_store.dart';
import 'package:video_editor/engine/android/android_engine.dart';
import 'package:video_editor/engine/ffmpeg/mpv_preview.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/export_settings.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

const s = usPerSecond;

Clip media(String path, MediaInfo info) => Clip(
  id: 0,
  kind: ClipKind.video,
  name: path,
  sourcePath: path,
  media: info,
  sourceDurationUs: info.durationUs,
  sourceInUs: 0,
  sourceOutUs: info.durationUs,
);

const pixelHdr = MediaInfo(
  durationUs: 10 * s,
  width: 3840,
  height: 2160,
  frameRate: 59.94,
  transfer: ColorTransfer.hlg,
  bitDepth: 10,
  wideGamut: true,
);

const portraitSdr = MediaInfo(
  durationUs: 4 * s,
  width: 1080,
  height: 1920,
  frameRate: 30,
);

void main() {
  test('first imported video sets frame rate and canvas shape', () {
    final p = Project.empty(
      id: 'x',
      frameRate: 30,
    ).insertMedia([media('a.mp4', pixelHdr)]);
    expect(p.frameRate, 60);
    expect(p.canvas, CanvasRatio.landscape16x9);
    expect(p.hasMedia, isTrue);
    // A later portrait clip doesn't change an existing project.
    final q = p.insertMedia([media('b.mp4', portraitSdr)]);
    expect(q.canvas, CanvasRatio.landscape16x9);
    expect(q.mainTrack.clips.length, 2);
  });

  test('new clips go after the clip under the playhead', () {
    final p = Project.empty(id: 'x')
        .insertMedia([media('a', pixelHdr), media('b', pixelHdr)]);
    expect(p.insertIndexAt(3 * s), 1);
    expect(p.insertIndexAt(0), 1);
    expect(p.insertIndexAt(25 * s), 2);
    final q = p.insertMedia([
      media('c', portraitSdr),
    ], index: p.insertIndexAt(3 * s));
    expect(q.mainTrack.clips.map((c) => c.sourcePath), ['a', 'c', 'b']);
  });

  test('export suggestions follow the footage', () {
    final hdr = Project.empty(id: 'x').insertMedia([media('a', pixelHdr)]);
    final sh = ExportSettings.suggestedFor(hdr);
    expect(sh.resolution, ExportResolution.p2160);
    expect(sh.frameRate, 60);
    expect(sh.dynamicRange, DynamicRange.hlg);

    final sdr = Project.empty(id: 'x').insertMedia([media('b', portraitSdr)]);
    final ss = ExportSettings.suggestedFor(sdr);
    expect(ss.resolution, ExportResolution.p1080);
    expect(ss.frameRate, 30);
    expect(ss.dynamicRange, DynamicRange.sdr);
    expect(ss.dimensionsFor(sdr.canvas), (width: 1080, height: 1920));
  });

  test('media details survive saving and loading', () async {
    final dir = await Directory.systemTemp.createTemp('ve_store_');
    addTearDown(() => dir.delete(recursive: true));
    final store = ProjectStore(dir);
    final p = Project.empty(
      id: 'proj1',
      name: 'Trip',
    ).insertMedia([media('a.mp4', pixelHdr)]);
    await store.save(p);
    final list = await store.list();
    expect(list.single.project.name, 'Trip');
    final clip = list.single.project.mainTrack.clips.single;
    expect(clip.media!.transfer, ColorTransfer.hlg);
    expect(clip.media!.width, 3840);
    await store.delete('proj1');
    expect(await store.list(), isEmpty);
  });

  test('Windows preview playlist (EDL) handles odd file names', () {
    final edl = buildEdl(const [
      PreviewSegment(r'C:\Videos\a, b; c.mp4', 1500000, 4000000),
      PreviewSegment(r'C:\Videos\é.mov', 0, 1000000),
    ]);
    expect(
      edl,
      r'edl://%21%C:\Videos\a, b; c.mp4,1.500000,2.500000;'
      r'%16%C:\Videos\é.mov,0.000000,1.000000',
    );
  });

  test('Android folder names are shown readably', () {
    final e = AndroidMediaEngine();
    expect(e.describeFolder(null), 'Movies / Video Editor');
    expect(
      e.describeFolder(
        'content://com.android.externalstorage.documents/tree/primary%3AMovies%2FTrips',
      ),
      'Movies/Trips',
    );
  });

  test('frame check tolerates rounding only', () {
    const good = ExportVerification(
      expectedFrames: 600,
      actualFrames: 601,
      expectedDurationUs: 0,
      actualDurationUs: 0,
    );
    const bad = ExportVerification(
      expectedFrames: 600,
      actualFrames: 570,
      expectedDurationUs: 0,
      actualDurationUs: 0,
    );
    expect(good.ok, isTrue);
    expect(bad.ok, isFalse);
    expect(bad.describe(), contains('expected 600'));
  });
}
