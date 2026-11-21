import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/export_settings.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';

void main() {
  test('4K follows the canvas shape', () {
    const s = ExportSettings();
    expect(s.dimensionsFor(CanvasRatio.landscape16x9), (
      width: 3840,
      height: 2160,
    ));
    expect(s.dimensionsFor(CanvasRatio.portrait9x16), (
      width: 2160,
      height: 3840,
    ));
    expect(s.dimensionsFor(CanvasRatio.square), (width: 2160, height: 2160));
    final d = s.dimensionsFor(CanvasRatio.cinema21x9);
    expect(d.width.isEven && d.height.isEven, isTrue);
  });

  test('choosing HDR switches H.264 to HEVC', () {
    final sdr = const ExportSettings().copyWith(
      dynamicRange: DynamicRange.sdr,
      codec: VideoCodec.h264,
    );
    expect(sdr.codec, VideoCodec.h264);
    final hdr = sdr.copyWith(dynamicRange: DynamicRange.hlg);
    expect(hdr.codec, VideoCodec.hevc);
    expect(hdr.copyWith(codec: VideoCodec.h264).codec, VideoCodec.hevc);
  });

  test('bit rate and size estimates are sensible for 4K60 HDR', () {
    const s = ExportSettings();
    final bps = s.videoBitrateFor(CanvasRatio.landscape16x9);
    expect(bps, inInclusiveRange(30000000, 50000000));
    expect(s.peakBitrateFor(CanvasRatio.landscape16x9), greaterThan(bps));
    final oneMinute = s.estimatedBytes(
      CanvasRatio.landscape16x9,
      60 * usPerSecond,
    );
    expect(oneMinute, inInclusiveRange(220000000, 400000000));
  });

  test('formatting helpers', () {
    expect(formatBitrate(54700000), '55 Mbps');
    expect(formatBitrate(6200000), '6.2 Mbps');
    expect(formatBytes(1234567890), '1.2 GB');
    expect(formatBytes(350000000), '350 MB');
  });

  test('never more data than the source videos have', () {
    // A 1080p60 HDR phone video at 17 Mbit/s.
    const phone = MediaInfo(
      durationUs: 60 * usPerSecond,
      width: 1080,
      height: 1920,
      frameRate: 60,
      transfer: ColorTransfer.hlg,
      codec: 'hevc',
      videoBitRate: 17000000,
    );
    final p = Project.empty(id: 'p', frameRate: 60).insertMedia([
      Clip(
        id: 0,
        kind: ClipKind.video,
        name: 'PXL_1',
        sourcePath: 'a.mp4',
        media: phone,
        sourceDurationUs: 60 * usPerSecond,
        sourceInUs: 0,
        sourceOutUs: 60 * usPerSecond,
      ),
    ]);
    const settings = ExportSettings(resolution: ExportResolution.p1080);
    final s = settings.copyWith(frameRate: 60);
    // High: 1080 × 1920 × 60 × 0.08 ≈ 10 Mbit/s, under the source's 17.
    expect(
      s.videoBitrateFor(p.canvas, project: p),
      inInclusiveRange(9500000, 10500000),
    );
    // Maximum would be 22 Mbit/s: held to the source's 17.
    final max = s.copyWith(quality: ExportQuality.maximum);
    expect(max.videoBitrateFor(p.canvas, project: p), 17000000);
    // Half the frame rate: half the source's rate.
    expect(
      max.copyWith(frameRate: 30).videoBitrateFor(p.canvas, project: p),
      8500000,
    );
  });

  test('exported files are named after the newest recording', () {
    Clip clip(String name, int? at) => Clip(
      id: 0,
      kind: ClipKind.video,
      name: name,
      sourcePath: '$name.mp4',
      media: MediaInfo(
        durationUs: usPerSecond,
        width: 1920,
        height: 1080,
        createdAtMs: at,
      ),
      sourceDurationUs: usPerSecond,
      sourceInUs: 0,
      sourceOutUs: usPerSecond,
    );
    var p = Project.empty(id: 'p', name: 'Trip').insertMedia([
      clip('PXL_20261112_090000', 1000),
      clip('IMG_20261113_101500', 3000),
      clip('PXL_20261111_080000', 2000),
    ]);
    expect(exportFileName(p), 'KVE_20261113_101500.mp4');
    // No dates: the last clip.
    p = Project.empty(id: 'p')
        .insertMedia([clip('PXL_1', null), clip('IMG_2', null)]);
    expect(exportFileName(p), 'KVE_2.mp4');
    // Not starting with three letters: KVE_ in front.
    p = Project.empty(id: 'p').insertMedia([clip('20261112_0900', null)]);
    expect(exportFileName(p), 'KVE_20261112_0900.mp4');
    // Taken names get a number on the end.
    expect(numberedFileName('KVE_2.mp4', 2), 'KVE_2_2.mp4');
    // A clip picked with the photo picker only knows a number; the real
    // name looked up on the phone is used instead.
    p = Project.empty(id: 'p').insertMedia([clip('1000012345', null)]);
    expect(
      exportFileName(p, realName: 'PXL_20261120_153012345.mp4'),
      'KVE_20261120_153012345.mp4',
    );
  });
}
