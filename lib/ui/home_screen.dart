import 'package:flutter/material.dart';

import '../model/demo.dart';
import '../model/project.dart';
import '../model/timecode.dart';
import 'editor_screen.dart';

/// Version label baked in by the automatic build (see
/// .github/workflows/build.yml). Shows "dev" for local builds.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Projects opened this session. Saving drafts to disk arrives in Stage 1.
  final List<Project> _recent = [];
  int _counter = 0;

  String _newId() => 'p${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  Future<void> _open(Project project) async {
    final result = await Navigator.of(context).push<Project>(
      MaterialPageRoute(builder: (_) => EditorScreen(project: project)),
    );
    if (!mounted) return;
    final updated = result ?? project;
    setState(() {
      _recent.removeWhere((p) => p.id == updated.id);
      _recent.insert(0, updated);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Video Editor',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Chip(
                      label: const Text('4K · HDR · 60 fps'),
                      avatar: Icon(
                        Icons.hdr_on,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _BigAction(
                  icon: Icons.add,
                  title: 'New project',
                  subtitle: 'Start an empty edit',
                  primary: true,
                  onTap: () => _open(Project.empty(id: _newId())),
                ),
                const SizedBox(height: 12),
                _BigAction(
                  icon: Icons.play_circle_outline,
                  title: 'Try the demo project',
                  subtitle: 'Colored placeholder clips to test split, trim, copy and undo',
                  onTap: () => _open(buildDemoProject(_newId())),
                ),
                const SizedBox(height: 28),
                if (_recent.isNotEmpty) ...[
                  Text('Recent', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final p in _recent)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.movie_edit),
                        title: Text(p.name),
                        subtitle: Text(
                          '${p.canvas.label} · ${formatShortDuration(p.durationUs)} · '
                          '${p.mainTrack.clips.length} clips',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(p),
                      ),
                    ),
                  const SizedBox(height: 20),
                ],
                Text(
                  'Version $appVersion · Stage 0 preview build. Real video '
                  'import, playback and export arrive in Stage 1.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: primary ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: primary
                    ? scheme.primary
                    : scheme.secondaryContainer,
                child: Icon(
                  icon,
                  size: 30,
                  color: primary
                      ? scheme.onPrimary
                      : scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
