import 'project.dart';
import 'timecode.dart';

/// A project with colored placeholder clips, so the timeline can be tried
/// before real video import exists.
Project buildDemoProject(String id) {
  Clip video(String name, double seconds, int color) {
    final us = (seconds * usPerSecond).round();
    return Clip(
      id: 0,
      kind: ClipKind.video,
      name: name,
      // Pretend each source file is longer than the part used, so trim
      // handles can also be dragged outward.
      sourceDurationUs: us + 4 * usPerSecond,
      sourceInUs: 2 * usPerSecond,
      sourceOutUs: 2 * usPerSecond + us,
      colorValue: color,
    );
  }

  Clip audio(String name, double startSeconds, double seconds, int color) {
    final us = (seconds * usPerSecond).round();
    return Clip(
      id: 0,
      kind: ClipKind.audio,
      name: name,
      sourceDurationUs: us + 10 * usPerSecond,
      sourceInUs: 0,
      sourceOutUs: us,
      startUs: (startSeconds * usPerSecond).round(),
      colorValue: color,
    );
  }

  return Project.empty(id: id, name: 'Demo project', frameRate: 60)
      .appendVideo(video('Beach · HDR', 8, 0xFF3C3C3C))
      .appendVideo(video('Sunset · HDR', 6, 0xFF555555))
      .appendVideo(video('City night', 10, 0xFF2E2E2E))
      .addAudio(audio('Music', 0, 20, 0xFF2E7D32))
      .addAudio(audio('Voice-over', 3, 5, 0xFF1565C0));
}
