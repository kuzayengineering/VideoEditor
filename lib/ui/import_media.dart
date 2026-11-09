import 'package:flutter/material.dart';

import '../engine/media_engine.dart';
import '../model/project.dart';

/// Lets the user pick videos, reads each one, and returns them as clips.
/// Files that can't be read are reported, the rest are still added.
Future<List<Clip>> pickAndReadVideos(
  BuildContext context,
  MediaEngine engine,
) async {
  final List<PickedMedia> picked;
  try {
    picked = await engine.pickVideos();
  } catch (e) {
    if (context.mounted) {
      _showError(context, 'Could not open the video picker.\n\n$e');
    }
    return const [];
  }
  if (picked.isEmpty || !context.mounted) return const [];

  final progress = ValueNotifier<int>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (context, done, _) => Row(
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Text('Reading videos… ${done + 1} of ${picked.length}'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  final clips = <Clip>[];
  final failures = <String>[];
  for (var i = 0; i < picked.length; i++) {
    progress.value = i;
    final p = picked[i];
    try {
      final info = await engine.probe(p.source);
      if (info.durationUs <= 0) throw Exception('it has no length');
      clips.add(
        Clip(
          id: 0,
          kind: ClipKind.video,
          name: _niceName(p.displayName),
          sourcePath: p.source,
          media: info,
          sourceDurationUs: info.durationUs,
          sourceInUs: 0,
          sourceOutUs: info.durationUs,
          colorValue: 0xFF263238,
        ),
      );
    } catch (e) {
      failures.add('• ${p.displayName}: $e');
    }
  }
  navigator.pop();
  progress.dispose();

  if (failures.isNotEmpty && context.mounted) {
    _showError(
      context,
      'Some files could not be added:\n\n${failures.join('\n')}',
    );
  }
  return clips;
}

String _niceName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(0, dot) : fileName;
}

void _showError(BuildContext context, String text) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Something went wrong'),
      content: SingleChildScrollView(child: Text(text)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
