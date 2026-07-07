import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/notification_service.dart';
import 'services/settings_store.dart';
import 'services/tray_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop: stand up the window + tray so the app can minimize-to-tray and
  // keep receiving transfers in the background (Phase 8).
  if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    final backgroundEnabled = await SettingsStore().getBackgroundReception();
    await TrayService.instance.init(backgroundEnabled: backgroundEnabled);
    await NotificationService.instance.init();
  }

  runApp(const NotilusApp());
}
