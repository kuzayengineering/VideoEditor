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
    // Dark and colourless (shades of gray only), so the interface never
    // tints how the video's colours look or nudges colour choices.
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF808080),
      brightness: Brightness.dark,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
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
