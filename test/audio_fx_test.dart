import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/model/project.dart';

void main() {
  test('no effects: nothing to do', () {
    expect(AudioFx.none.isNeutral, isTrue);
    expect(AudioFx.none.ffmpegFilters(), isNull);
  });

  test('equalizer curve: each band peaks at its own gain', () {
    final fx = AudioFx(eq: EqPreset.bass.gains);
    expect(fx.eqResponseDb(60), greaterThan(5));
    expect(fx.eqResponseDb(8000).abs(), lessThan(0.5));
    const one = AudioFx(eq: [0, 0, 0, 6, 0, 0, 0]);
    expect(one.eqResponseDb(1000), closeTo(6, 0.01));
  });

  test('FFmpeg filters in order: pitch, equalizer, delay, reverb', () {
    final fx = AudioFx(
      pitch: 12,
      eq: const [0, 0, 0, 3, 0, 0, 0],
      delayMs: 250,
      reverb: ReverbKind.room,
    );
    final f = fx.ffmpegFilters()!;
    expect(f, startsWith('asetrate=96000.000,aresample=48000,atempo=0.500000'));
    expect(f, contains('equalizer=f=1000:t=q:w=1.00:g=3.00'));
    expect(f.indexOf('aecho=1:1:250.0|500.0|750.0|1000.0'), greaterThan(0));
    expect('aecho'.allMatches(f).length, 2);
  });

  test('saved with the clip', () {
    final fx = AudioFx(
      pitch: -3,
      eq: EqPreset.voice.gains,
      reverb: ReverbKind.church,
      reverbAmount: 0.6,
      delayMs: 400,
    );
    final clip = Clip(
      id: 1,
      kind: ClipKind.audio,
      name: 'a',
      sourceDurationUs: 1000000,
      sourceInUs: 0,
      sourceOutUs: 1000000,
      audioFx: fx,
    );
    final back = Clip.fromJson(
      (jsonDecode(jsonEncode(clip.toJson())) as Map).cast<String, Object?>(),
    );
    expect(back.audioFx, fx);
    final m = fx.toEngineMap();
    expect(m['pitch'], closeTo(0.8409, 0.0001));
    expect((m['delayTaps'] as List).length, 4);
    expect((m['reverbTaps'] as List).length, 11);
  });

  test('noise reduction filters for each kind', () {
    expect(const AudioFx(noise: NoiseKind.hiss).isNeutral, isFalse);
    expect(
      const AudioFx(noise: NoiseKind.hiss, noiseAmount: 0).isNeutral,
      isTrue,
    );

    final hiss = const AudioFx(noise: NoiseKind.hiss, noiseAmount: 0.5);
    expect(hiss.ffmpegFilters(), startsWith('afftdn=nr=12.0'));
    final m = hiss.toEngineMap()['noise'] as Map;
    expect(m['denoiseDb'], closeTo(12, 1e-9));
    expect(m['filters'], isEmpty);

    final hum = const AudioFx(noise: NoiseKind.hum).ffmpegFilters()!;
    expect('bandreject'.allMatches(hum).length, 6);
    expect(hum, isNot(contains('afftdn')));

    final wind = const AudioFx(noise: NoiseKind.wind).ffmpegFilters()!;
    expect(wind, startsWith('highpass=f=150'));
    expect(wind, contains('afftdn'));

    final breath = const AudioFx(noise: NoiseKind.breath).ffmpegFilters()!;
    expect(breath, contains('agate'));
    final b =
        const AudioFx(noise: NoiseKind.breath).toEngineMap()['noise'] as Map;
    expect(b['gateRangeDb'], greaterThan(0));

    // Noise comes first, before pitch and equalizer.
    final all = const AudioFx(
      noise: NoiseKind.road,
      pitch: 2,
      eq: [0, 0, 0, 3, 0, 0, 0],
    ).ffmpegFilters()!;
    expect(all.indexOf('afftdn'), lessThan(all.indexOf('asetrate')));
    expect(all.indexOf('asetrate'), lessThan(all.indexOf('equalizer=f=1000')));
  });

  test('noise settings saved with the clip', () {
    const fx = AudioFx(noise: NoiseKind.wind, noiseAmount: 0.3);
    final back = AudioFx.fromJson(
      (jsonDecode(jsonEncode(fx.toJson())) as Map).cast<String, Object?>(),
    );
    expect(back, fx);
  });
}
