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
    expect(bps, inInclusiveRange(40000000, 70000000));
    expect(s.peakBitrateFor(CanvasRatio.landscape16x9), greaterThan(bps));
    final oneMinute = s.estimatedBytes(
      CanvasRatio.landscape16x9,
      60 * usPerSecond,
    );
    expect(oneMinute, inInclusiveRange(300000000, 550000000));
  });

  test('formatting helpers', () {
    expect(formatBitrate(54700000), '55 Mbps');
    expect(formatBitrate(6200000), '6.2 Mbps');
    expect(formatBytes(1234567890), '1.2 GB');
    expect(formatBytes(350000000), '350 MB');
  });
}
