/// Time helpers.
///
/// Every time value in the project is stored as a whole number of
/// **microseconds** (millionths of a second). Integers never drift the way
/// decimals do, which matters when cutting on exact frames.
library;

const int usPerSecond = 1000000;

/// Length of one frame in microseconds at [fps].
int frameDurationUs(double fps) => (usPerSecond / fps).round();

/// Index of the frame that is showing at [timeUs].
///
/// Frame start times are rounded to whole microseconds, so a 1 µs tolerance
/// makes sure a frame's own start time is counted as that frame.
int frameIndexAt(int timeUs, double fps) =>
    (((timeUs + 1) * fps) / usPerSecond).floor();

/// Start time of frame number [frame].
int frameStartUs(int frame, double fps) => (frame * usPerSecond / fps).round();

/// Snaps [timeUs] to the nearest frame boundary.
int snapToFrame(int timeUs, double fps) =>
    frameStartUs(((timeUs * fps) / usPerSecond).round(), fps);

/// Formats a time as `MM:SS:FF` (minutes : seconds : frame), the standard
/// editing timecode. Hours are added in front when needed.
String formatTimecode(int timeUs, double fps) {
  if (timeUs < 0) timeUs = 0;
  final fpsInt = fps.round().clamp(1, 1000);
  final totalFrames = frameIndexAt(timeUs, fps);
  final frames = totalFrames % fpsInt;
  final totalSeconds = totalFrames ~/ fpsInt;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  String two(int v) => v.toString().padLeft(2, '0');
  final core = '${two(minutes)}:${two(seconds)}:${two(frames)}';
  return hours > 0 ? '$hours:$core' : core;
}

/// Short human-friendly duration such as `4.5s` or `1:05`.
String formatShortDuration(int durationUs) {
  final seconds = durationUs / usPerSecond;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final whole = seconds.round();
  return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
}
