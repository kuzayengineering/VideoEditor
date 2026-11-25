import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../captions/speech_models.dart';
import '../effects/parts_model.dart';

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
            const Divider(),
            const _DownloadedModels(),
          ],
        ),
      ),
    );
  }
}

/// The models downloaded for captions and the people effects: their size,
/// and a way to delete each (it is downloaded again if needed).
class _DownloadedModels extends StatefulWidget {
  const _DownloadedModels();

  @override
  State<_DownloadedModels> createState() => _DownloadedModelsState();
}

typedef _Item = ({
  String title,
  String subtitle,
  int bytes,
  Future<void> Function() delete,
});

class _DownloadedModelsState extends State<_DownloadedModels> {
  List<_Item>? _items;
  final _speech = SpeechModelStore();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = <_Item>[];
    for (final m in DownloadableModel.all) {
      if (await m.check()) {
        items.add((
          title: m.label,
          subtitle: 'For ${m.usedFor}',
          bytes: m.bytes,
          delete: m.delete,
        ));
      }
    }
    for (final a in CaptionAccuracy.values) {
      for (final english in [true, false]) {
        final m = SpeechModel.of(a, english: english);
        if (await _speech.pathIfPresent(m) != null) {
          items.add((
            title: 'Speech (${a.label}${english ? ', English' : ''})',
            subtitle: 'For Captions',
            bytes: m.bytes,
            delete: () => _speech.delete(m),
          ));
        }
      }
    }
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    final total = items?.fold<int>(0, (s, i) => s + i.bytes) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.download_done_outlined),
          title: const Text('Downloaded models'),
          subtitle: Text(
            items == null
                ? 'Checking…'
                : items.isEmpty
                ? 'None yet. Captions, Recolour, Eye colour and Outfit download '
                      'theirs the first time they are used.'
                : '${(total / 1e6).toStringAsFixed(0)} MB in all. They work '
                      'offline; deleting one just means it downloads again '
                      'when next needed.',
          ),
        ),
        for (final i in items ?? const <_Item>[])
          ListTile(
            contentPadding: const EdgeInsets.only(left: 72, right: 8),
            title: Text(i.title),
            subtitle: Text(
              '${i.subtitle} · ${(i.bytes / 1e6).toStringAsFixed(1)} MB',
            ),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              onPressed: () async {
                await i.delete();
                await _load();
              },
            ),
          ),
      ],
    );
  }
}
