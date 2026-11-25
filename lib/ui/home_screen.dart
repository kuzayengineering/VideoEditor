import 'dart:io';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../app_services.dart';
import '../data/project_files.dart';
import '../data/project_store.dart';
import '../model/demo.dart';
import '../model/project.dart';
import '../model/timecode.dart';
import 'editor_screen.dart';
import 'settings_screen.dart';
import 'import_media.dart';

/// Version label baked in by the automatic build (see
/// .github/workflows/build.yml). Shows "dev" for local builds.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ProjectSummary> _drafts = const [];
  int _counter = 0;
  late AppServices _services;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _services = AppServices.of(context);
    _reload();
  }

  Future<void> _reload({Project? justClosed}) async {
    final drafts = await _services.store?.list() ?? const <ProjectSummary>[];
    if (mounted) setState(() => _drafts = drafts);
    // No project is open here: clear out files nothing uses any more.
    if (_services.store != null && _services.engine.supportsMedia) {
      try {
        await ProjectFiles(_services.engine)
            .sweep([for (final d in drafts) d.project, ?justClosed]);
      } catch (_) {}
    }
  }

  /// Cover pictures, by video file and moment (made once).
  final Map<String, Future<String?>> _covers = {};

  /// The project's first frame (its first video clip's first frame), made
  /// with the timeline's picture cache, so it is deleted along with the
  /// project's other pictures. A film symbol until it's ready.
  Widget _cover(Project project) {
    final hdr = project.mainTrack.clips.any((c) => c.media?.isHdr ?? false);
    final fallback = Icon(hdr ? Icons.hdr_on : Icons.movie_edit);
    final first = project.mainTrack.clips.where((c) => c.isMedia).firstOrNull;
    if (first == null || !_services.engine.supportsMedia) return fallback;
    final t = first.sourceTimeAt(0);
    final future = _covers.putIfAbsent(
      '${first.sourcePath}@$t',
      () => _services.engine
          .thumbnails(
            first.sourcePath!,
            first.media!,
            [t],
            height: 120,
            exact: true,
          )
          .then((files) => files.firstOrNull)
          .catchError((_) => null),
    );
    return SizedBox(
      width: 64,
      height: 48,
      child: FutureBuilder<String?>(
        future: future,
        builder: (context, snap) {
          final path = snap.data;
          if (path == null) return Center(child: fallback);
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(child: fallback),
                ),
                if (hdr)
                  const Positioned(
                    right: 2,
                    bottom: 2,
                    child: Icon(Icons.hdr_on, size: 16, color: Colors.white),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _newId() => 'p${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  Future<void> _open(Project project, {bool autosave = true}) async {
    final closed = await Navigator.of(context).push<Project>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(project: project, autosave: autosave),
      ),
    );
    if (mounted) await _reload(justClosed: autosave ? closed : null);
  }

  Future<void> _newProject() async {
    final engine = _services.engine;
    if (!engine.supportsMedia) {
      await _open(Project.empty(id: _newId()), autosave: false);
      return;
    }
    final clips = await pickAndReadVideos(context, engine);
    if (clips.isEmpty || !mounted) return;
    final now = DateTime.now();
    final name =
        'Project ${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final project = Project.empty(id: _newId(), name: name).insertMedia(clips);
    await _services.store?.save(project);
    await _open(project);
  }

  /// A full copy of a project (same clips and edits; the video files
  /// themselves aren't copied, both projects use them).
  Future<void> _duplicate(Project p) async {
    final copy = p.duplicated(_newId());
    await _services.store?.save(copy);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Made "${copy.name}".')));
  }

  Future<void> _delete(Project p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${p.name}"?'),
        content: const Text(
          'Only the project is deleted. Your original videos and any '
          'exported videos are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _services.store?.delete(p.id);
    AppSettings.instance.forgetProject(p.id);
    // Its reversed copies, voice-overs, preview copies and pictures too
    // (unless another project uses them).
    final rest = [
      for (final d in _drafts)
        if (d.project.id != p.id) d.project,
    ];
    await ProjectFiles(_services.engine).deleteFilesOf(p, rest);
    await _reload();
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} days ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
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
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset(
                          'assets/branding/logo_512.png',
                          width: 48,
                          height: 48,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Video Editor',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '4K · HDR · 60 fps',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Settings',
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _BigAction(
                    icon: Icons.add,
                    title: 'New project',
                    subtitle: 'Pick videos to start editing',
                    primary: true,
                    onTap: _newProject,
                  ),
                  const SizedBox(height: 28),
                  if (_drafts.isNotEmpty) ...[
                    Text('Projects', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final d in _drafts)
                      Card(
                        child: ListTile(
                          leading: _cover(d.project),
                          title: Text(d.project.name),
                          subtitle: Text(
                            '${d.project.canvas.label} · '
                            '${formatShortDuration(d.project.durationUs)} · '
                            '${d.project.mainTrack.clips.length} clips · '
                            '${_when(d.modified)}',
                          ),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Project options',
                            onSelected: (v) => v == 'copy'
                                ? _duplicate(d.project)
                                : _delete(d.project),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'copy',
                                child: ListTile(
                                  leading: Icon(Icons.copy_outlined),
                                  title: Text('Duplicate'),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(Icons.delete_outline),
                                  title: Text('Delete'),
                                ),
                              ),
                            ],
                          ),
                          onTap: () => _open(d.project),
                        ),
                      ),
                    const SizedBox(height: 20),
                  ],
                  _BigAction(
                    icon: Icons.play_circle_outline,
                    title: 'Try the demo project',
                    subtitle:
                        'Placeholder clips to practise split, trim, '
                        'copy and undo',
                    onTap: () =>
                        _open(buildDemoProject(_newId()), autosave: false),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Version $appVersion',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
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
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: primary ? scheme.onPrimaryContainer : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: primary ? scheme.onPrimaryContainer : null,
                      ),
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
