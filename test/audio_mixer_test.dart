import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor/engine/media_engine.dart';
import 'package:video_editor/model/project.dart';
import 'package:video_editor/model/timecode.dart';
import 'package:video_editor/ui/audio_preview.dart';
import 'package:video_editor/ui/editor_controller.dart';

const s = usPerSecond;

class _Sound implements ClipAudioPlayer {
  _Sound(this.engine);
  final _Engine engine;

  @override
  Future<void> open(String source) async => engine.open++;
  @override
  Future<void> dispose() async => engine.open--;
  @override
  dynamic noSuchMethod(Invocation invocation) async {}
}

class _Engine implements MediaEngine {
  int open = 0;

  @override
  ClipAudioPlayer createAudioPlayer() => _Sound(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preview implements PreviewPlayer {
  @override
  Future<PreviewStatus> status() async => PreviewStatus.idle;

  @override
  Future<void> clearError() async {}

  @override
  bool get gradesLive => false;
  @override
  bool get blendsTransitions => false;
  @override
  bool drawsEffects(List<PreviewSegment> segments) => true;
  @override
  Future<int> position() async => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) async {}
}

Clip sound(int i) => Clip(
  id: 0,
  kind: ClipKind.audio,
  name: 'piece $i',
  sourcePath: 'video.mp4',
  media: const MediaInfo(durationUs: 120 * s, width: 1920, height: 1080),
  sourceDurationUs: 120 * s,
  sourceInUs: i * 10 * s,
  sourceOutUs: (i * 10 + 8) * s,
  startUs: i * 10 * s,
);

void main() {
  test('sound players exist only near the playhead, and none while '
      'exporting', () async {
    var project = Project.empty(id: 'p', frameRate: 30);
    for (var i = 0; i < 12; i++) {
      project = project.addAudio(sound(i));
    }
    final engine = _Engine();
    final mixer = AudioPreviewMixer(engine);
    final c = EditorController(project);
    c.attachPreview(_Preview(), audio: mixer);
    await Future<void>.delayed(Duration.zero);
    // Clips at 0-8 s (and nothing else within 5 s): one player, not twelve.
    expect(mixer.openPlayers, 1);
    expect(engine.open, 1);

    // Move to 66 s: the clip there and the next one starting at 70 s.
    c.seek(66 * s);
    await Future<void>.delayed(Duration.zero);
    expect(mixer.openPlayers, 2);
    expect(engine.open, 2);

    // Exporting: everything closed; afterwards back as before.
    await c.suspendPreview();
    await Future<void>.delayed(Duration.zero);
    expect(engine.open, 0);
    c.resumePreview();
    await Future<void>.delayed(Duration.zero);
    expect(engine.open, 2);
  });
}
