import 'package:flutter/material.dart';

import '../app_settings.dart';

/// The app's options.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.contrast),
              title: const Text('Neutral colours'),
              subtitle: const Text(
                'Shows the app in shades of gray only, so its colours never '
                'influence how you judge or choose the colours in your video.',
              ),
              value: settings.neutralColors,
              onChanged: (v) => settings.neutralColors = v,
            ),
          ],
        ),
      ),
    );
  }
}
