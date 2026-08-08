import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/native_core.dart';
import 'services/notification_service.dart';
import 'services/settings_store.dart';
import 'services/tray_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load the P2P transfer backend secrets from the bundled .env asset. Optional
  // so the app still launches (transfer just shows its "set up" hint) when the
  // file is absent — e.g. a fresh checkout before .env is created.
  await dotenv.load(fileName: '.env', isOptional: true);

  // Load the Rust core. Every file operation, search and scan goes through it,
  // so this has to succeed before the first frame can do anything useful.
  await NativeCore.ensureInitialized();

  // Desktop: stand up the window + tray so the app can minimize-to-tray and
  // keep receiving transfers in the background (Phase 8).
  if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    await windowManager.ensureInitialized();

    // One 48px bar on every platform: the OS caption is hidden and the app's
    // own toolbar is the title bar. macOS carries on drawing its traffic
    // lights over the full-size content view; Windows and Linux have no
    // native buttons left, so the toolbar draws its own (see
    // widgets/window_chrome.dart).
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        titleBarStyle: TitleBarStyle.hidden,
        // macOS-only, and already the default — spelled out because hiding the
        // title bar without it would leave that window with no controls at all.
        windowButtonVisibility: true,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );

    final backgroundEnabled = await SettingsStore().getBackgroundReception();
    await TrayService.instance.init(backgroundEnabled: backgroundEnabled);
    await NotificationService.instance.init();
  }

  runApp(const NotilusApp());
}
