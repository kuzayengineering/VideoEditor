import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// The Windows version's update check: each time the app starts it asks
/// GitHub (where the releases are) for the newest Windows installer, and
/// if it is newer than this version offers to download and install it.
/// Only the release list is fetched: nothing about the user or their
/// videos is sent.
abstract final class WindowsUpdates {
  static const _releases =
      'https://api.github.com/repos/kuzayengineering/VideoEditor/releases?per_page=100';

  static bool _checked = false;

  /// Checks once per start (quietly does nothing when offline).
  static Future<void> check(BuildContext context, String currentVersion) async {
    if (_checked || !Platform.isWindows || currentVersion == 'dev') return;
    _checked = true;
    final newest = await _newest();
    if (newest == null || !context.mounted) return;
    if (compareVersions(newest.version, currentVersion) <= 0) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update available'),
        content: Text(
          'Video Editor ${newest.version} is available (you have '
          '$currentVersion). Install it now? The app closes, updates and '
          'opens again; your projects are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await _install(context, newest);
  }

  /// Newest published release that has a Windows installer.
  static Future<({String version, String url, int size})?> _newest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(_releases));
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'VideoEditor-updater')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List;
      ({String version, String url, int size})? best;
      for (final r in list.cast<Map<String, dynamic>>()) {
        if (r['draft'] == true || r['prerelease'] == true) continue;
        final tag = (r['tag_name'] as String? ?? '').replaceFirst('v', '');
        for (final a in (r['assets'] as List? ?? const []).cast<Map>()) {
          final name = a['name'] as String? ?? '';
          if (!name.endsWith('-windows-setup.exe')) continue;
          if (best == null || compareVersions(tag, best.version) > 0) {
            best = (
              version: tag,
              url: a['browser_download_url'] as String,
              size: (a['size'] as num?)?.toInt() ?? 0,
            );
          }
        }
      }
      return best;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the installer (with progress), then runs it quietly and
  /// closes the app so it can be replaced.
  static Future<void> _install(
    BuildContext context,
    ({String version, String url, int size}) release,
  ) async {
    final progress = ValueNotifier<double?>(null);
    final error = ValueNotifier<String?>(null);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Downloading ${release.version}'),
        content: ValueListenableBuilder<String?>(
          valueListenable: error,
          builder: (context, e, _) => e != null
              ? Text(e)
              : ValueListenableBuilder<double?>(
                  valueListenable: progress,
                  builder: (context, f, _) => LinearProgressIndicator(value: f),
                ),
        ),
        actions: [
          ValueListenableBuilder<String?>(
            valueListenable: error,
            builder: (context, e, _) => e == null
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
          ),
        ],
      ),
    );
    final client = HttpClient();
    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'VideoEditor-${release.version}-windows-setup.exe',
      );
      final response = await (await client.getUrl(Uri.parse(release.url)))
          .close();
      if (response.statusCode != 200) {
        throw HttpException('error ${response.statusCode}');
      }
      final out = file.openWrite();
      var got = 0;
      final total = release.size > 0 ? release.size : response.contentLength;
      await for (final chunk in response) {
        out.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = (got / total).clamp(0.0, 1.0);
      }
      await out.close();
      if (release.size > 0 && got != release.size) {
        throw const HttpException('the download was incomplete');
      }
      await Process.start(file.path, const [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
      exit(0);
    } catch (e) {
      error.value =
          'The update could not be downloaded ($e). You can also get it '
          'from the GitHub releases page.';
    } finally {
      client.close(force: true);
    }
  }
}

/// Compares "1.2.10" with "1.2.9" number by number (> 0: [a] is newer).
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split(RegExp(r'[.+-]'))) int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
