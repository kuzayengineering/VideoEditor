import 'dart:io';

import 'android/android_engine.dart';
import 'ffmpeg/ffmpeg_engine.dart';
import 'media_engine.dart';

export 'media_engine.dart';

/// Picks the video engine for the device the app is running on.
MediaEngine createPlatformEngine() {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return const NoMediaEngine();
  }
  if (Platform.isAndroid) return AndroidMediaEngine();
  if (Platform.isWindows) return FfmpegEngine();
  return const NoMediaEngine();
}
