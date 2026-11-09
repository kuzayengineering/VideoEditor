import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_services.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The Windows preview player (mpv). Android uses its own Media3 player.
  if (Platform.isWindows) MediaKit.ensureInitialized();
  final services = await AppServices.create();
  runApp(VideoEditorApp(services: services));
}

class VideoEditorApp extends StatelessWidget {
  const VideoEditorApp({super.key, this.services = AppServices.none});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    // Dark theme by default: it's easier to judge video colors against a dark
    // interface, which is why most editors (YouCut included) use one.
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00BFA5),
      brightness: Brightness.dark,
    );
    return AppScope(
      services: services,
      child: MaterialApp(
        title: 'Video Editor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: scheme,
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF121212),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
