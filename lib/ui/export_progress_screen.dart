import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../engine/media_engine.dart';

/// Shows an export's progress, then where the video was saved and whether
/// the finished file checked out.
class ExportProgressScreen extends StatelessWidget {
  const ExportProgressScreen({super.key, required this.job});

  final ExportJob job;

  Future<void> _confirmCancel(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop exporting?'),
        content: const Text('The partly made video will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (yes == true) await job.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<ExportProgress>(
      stream: job.progress,
      initialData: job.latest,
      builder: (context, snap) {
        final p = snap.data ?? job.latest;
        final busy = !p.finished;
        return PopScope(
          canPop: !busy,
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: !busy,
              title: Text(switch (p.state) {
                ExportState.done => 'Export complete',
                ExportState.failed => 'Export failed',
                ExportState.cancelled => 'Export cancelled',
                _ => 'Exporting',
              }),
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      const SizedBox(height: 24),
                      Center(
                        child: SizedBox(
                          width: 160,
                          height: 160,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CircularProgressIndicator(
                                value: busy
                                    ? (p.fraction > 0 ? p.fraction : null)
                                    : 1,
                                strokeWidth: 10,
                                color: p.state == ExportState.failed
                                    ? theme.colorScheme.error
                                    : null,
                              ),
                              Center(
                                child: busy
                                    ? Text(
                                        '${(p.fraction * 100).floor()}%',
                                        style: theme.textTheme.headlineMedium,
                                      )
                                    : Icon(
                                        p.state == ExportState.done
                                            ? Icons.check_rounded
                                            : Icons.close_rounded,
                                        size: 72,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (busy) ...[
                        Text(
                          p.message ?? 'Preparing…',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'You can switch to other apps or turn the screen '
                          'off. The export keeps going and a notification '
                          'shows its progress.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 28),
                        OutlinedButton.icon(
                          onPressed: () => _confirmCancel(context),
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Stop export'),
                        ),
                      ],
                      if (p.state == ExportState.done) ...[
                        if (p.outputLocation != null)
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: const Text('Saved to'),
                            subtitle: SelectableText(p.outputLocation!),
                          ),
                        if (p.verification != null)
                          ListTile(
                            leading: Icon(
                              p.verification!.ok
                                  ? Icons.verified_outlined
                                  : Icons.warning_amber_rounded,
                              color: p.verification!.ok
                                  ? (AppSettings.instance.neutralColors
                                        ? theme.colorScheme.onSurface
                                        : Colors.greenAccent)
                                  : (AppSettings.instance.neutralColors
                                        ? theme.colorScheme.error
                                        : Colors.orangeAccent),
                            ),
                            title: Text(p.verification!.describe()),
                            subtitle: p.verification!.isHdr == null
                                ? null
                                : Text(
                                    p.verification!.isHdr!
                                        ? 'HDR information is in the file.'
                                        : 'Standard (SDR) video.',
                                  ),
                          ),
                      ],
                      if (p.state == ExportState.failed ||
                          p.state == ExportState.cancelled)
                        SelectableText(
                          p.message ?? '',
                          style: theme.textTheme.bodyMedium,
                        ),
                      if (p.state == ExportState.failed)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Copy the details'),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: p.message ?? ''),
                            ),
                          ),
                        ),
                      if (!busy) ...[
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Back to editing'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
