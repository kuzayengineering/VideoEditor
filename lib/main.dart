import 'package:flutter/material.dart';

import 'ui/home_screen.dart';

void main() {
  runApp(const VideoEditorApp());
}

class VideoEditorApp extends StatelessWidget {
  const VideoEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Dark theme by default: it's easier to judge video colors against a dark
    // interface, which is why most editors (YouCut included) use one.
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00BFA5),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Video Editor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const HomeScreen(),
    );
  }
}
