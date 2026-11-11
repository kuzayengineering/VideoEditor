import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_services.dart';
import 'app_settings.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The Windows preview player (mpv). Android uses its own Media3 player.
  if (Platform.isWindows) MediaKit.ensureInitialized();
  await AppSettings.instance.load();
  final services = await AppServices.create();
  runApp(VideoEditorApp(services: services));
}

class VideoEditorApp extends StatelessWidget {
  const VideoEditorApp({super.key, this.services = AppServices.none});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) => _app(AppSettings.instance.neutralColors),
    );
  }

  Widget _app(bool neutral) {
    // Dark theme: it's easier to judge video colours against a dark
    // interface. "Neutral colours" (Settings) makes it shades of gray only,
    // so the interface never tints how the video's colours look.
    final scheme = neutral
        ? ColorScheme.fromSeed(
            seedColor: const Color(0xFF808080),
            brightness: Brightness.dark,
            dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
          )
        : ColorScheme.fromSeed(
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
