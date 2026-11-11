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

  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}${Platform.pathSeparator}settings.json');
      if (await _file!.exists()) {
        final json = jsonDecode(await _file!.readAsString()) as Map;
        _neutralColors = json['neutralColors'] as bool? ?? false;
      }
    } catch (_) {
      // Defaults.
    }
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode({'neutralColors': _neutralColors}));
    } catch (_) {}
  }
}
