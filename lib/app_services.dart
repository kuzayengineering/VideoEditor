import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'data/project_store.dart';
import 'engine/engine.dart';

/// Things the whole app shares: the video engine and the saved projects.
class AppServices {
  AppServices({required this.engine, required this.store});

  final MediaEngine engine;

  /// Null when projects can't be saved (e.g. in tests).
  final ProjectStore? store;

  static Future<AppServices> create() async {
    ProjectStore? store;
    try {
      final dir = await getApplicationSupportDirectory();
      store = ProjectStore(
        Directory('${dir.path}${Platform.pathSeparator}projects'),
      );
    } catch (_) {
      store = null;
    }
    return AppServices(engine: createPlatformEngine(), store: store);
  }

  static const AppServices none = _NoServices();

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.services ?? none;
}

class _NoServices implements AppServices {
  const _NoServices();
  @override
  MediaEngine get engine => const NoMediaEngine();
  @override
  ProjectStore? get store => null;
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
