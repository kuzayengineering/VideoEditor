import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The app's own preferences (Settings screen), saved on the device.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  /// Shades of gray only, so the interface never tints how the video's
  /// colours look or nudges colour choices. Off: the usual teal accents.
  bool get neutralColors => _neutralColors;
  bool _neutralColors = false;
  set neutralColors(bool value) {
    if (value == _neutralColors) return;
    _neutralColors = value;
    notifyListeners();
    _save();
  }

  /// Each project's timeline zoom (pixels per second), by project id, so
  /// a project opens zoomed as it was left.
  final Map<String, double> _zooms = {};

  double? timelineZoomOf(String projectId) => _zooms[projectId];

  void setTimelineZoom(String projectId, double pixelsPerSecond) {
    if (_zooms[projectId] == pixelsPerSecond) return;
    _zooms[projectId] = pixelsPerSecond;
    // Pinching changes it many times a second: save once it settles.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _save);
  }

  void forgetProject(String projectId) {
    if (_zooms.remove(projectId) != null) _save();
  }

  Timer? _saveTimer;
  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}${Platform.pathSeparator}settings.json');
      if (await _file!.exists()) {
        final json = jsonDecode(await _file!.readAsString()) as Map;
        _neutralColors = json['neutralColors'] as bool? ?? false;
        final zooms = json['timelineZoom'];
        if (zooms is Map) {
          for (final e in zooms.entries) {
            final v = e.value;
            if (e.key is String && v is num) {
              _zooms[e.key as String] = v.toDouble();
            }
          }
        }
      }
    } catch (_) {
      // Defaults.
    }
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    try {
      await f.writeAsString(
        jsonEncode({'neutralColors': _neutralColors, 'timelineZoom': _zooms}),
      );
    } catch (_) {}
  }
}
