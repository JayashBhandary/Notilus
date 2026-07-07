import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

/// Native OS banner notifications (macOS/Windows/Linux). Complements the in-app
/// dialogs surfaced by [TransferRequestGate]: those only appear when the window
/// is visible, whereas these reach the user even when Notilus is minimized to
/// the tray (background reception). Best-effort — never throws into callers.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  bool _inited = false;

  /// Desktop only; a no-op elsewhere (and under `flutter test`).
  static bool get _supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// Call once at startup (after `windowManager.ensureInitialized`).
  Future<void> init() async {
    if (_inited || !_supported) return;
    try {
      await localNotifier.setup(appName: 'Notilus');
      _inited = true;
    } catch (e) {
      debugPrint('Notification setup failed: $e');
    }
  }

  /// Shows an OS banner with [title] and [body]. Silently does nothing if the
  /// platform is unsupported or setup failed.
  Future<void> show(String title, String body) async {
    if (!_inited || !_supported) return;
    try {
      await LocalNotification(title: title, body: body).show();
    } catch (e) {
      debugPrint('Notification show failed: $e');
    }
  }
}
