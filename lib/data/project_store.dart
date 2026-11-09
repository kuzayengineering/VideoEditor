import 'dart:convert';
import 'dart:io';

import '../model/project.dart';

/// A saved project as listed on the home screen.
class ProjectSummary {
  const ProjectSummary(this.project, this.modified);

  final Project project;
  final DateTime modified;
}

/// Saves projects ("drafts") as small JSON files in the app's private folder.
///
/// Writes go to a temporary file first and are then renamed into place, so a
/// crash or power loss mid-save can never leave a half-written project.
class ProjectStore {
  ProjectStore(this.directory);

  final Directory directory;

  File _fileFor(String id) => File('${directory.path}/$id.json');

  Future<void> save(Project project) async {
    await directory.create(recursive: true);
    final target = _fileFor(project.id);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent(' ').convert(project.toJson()),
      flush: true,
    );
    await temp.rename(target.path);
  }

  Future<Project?> load(String id) async {
    final f = _fileFor(id);
    if (!await f.exists()) return null;
    return _read(f);
  }

  Future<Project?> _read(File f) async {
    try {
      final json = jsonDecode(await f.readAsString());
      return Project.fromJson((json as Map).cast<String, Object?>());
    } catch (_) {
      return null; // Unreadable or from a newer version: skip it.
    }
  }

  /// All saved projects, most recently changed first.
  Future<List<ProjectSummary>> list() async {
    if (!await directory.exists()) return [];
    final result = <ProjectSummary>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final project = await _read(entity);
      if (project == null) continue;
      result.add(ProjectSummary(project, await entity.lastModified()));
    }
    result.sort((a, b) => b.modified.compareTo(a.modified));
    return result;
  }

  Future<void> delete(String id) async {
    final f = _fileFor(id);
    if (await f.exists()) await f.delete();
  }
}
