import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Phase 8 — background reception. Keeps Notilus running in the system tray so
/// the signaling inbox (`SignalingService`, driven by `TransferController`) stays
/// alive to receive transfer requests even when the window is closed.
///
/// "Close = minimize to tray" while background reception is on; a tray menu (or
/// icon click) brings the window back, and "Quit" really exits. When background
/// reception is off, closing the window quits as usual.
class TrayService with TrayListener, WindowListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  static const _showKey = 'show';
  static const _quitKey = 'quit';

  bool _inited = false;
  bool _quitting = false;

  /// Reflects the user's Settings toggle; governs whether close hides or quits.
  bool backgroundEnabled = true;

  /// Desktop only; a no-op on any other platform (and under `flutter test`).
  static bool get _supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// Windows wants an .ico; macOS/Linux take the PNG (scaled natively).
  static String get _iconPath => (!kIsWeb && Platform.isWindows)
      ? 'assets/icon/tray_icon.ico'
      : 'assets/icon/icon.png';

  /// Call once at startup (after `windowManager.ensureInitialized`).
  Future<void> init({required bool backgroundEnabled}) async {
    if (_inited || !_supported) return;
    _inited = true;
    this.backgroundEnabled = backgroundEnabled;

    // Intercept the window's close button so we can divert it to the tray.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);

    try {
      await trayManager.setIcon(_iconPath);
      await trayManager.setToolTip('Notilus');
      await trayManager.setContextMenu(
        Menu(items: [
          MenuItem(key: _showKey, label: 'Show Notilus'),
          MenuItem.separator(),
          MenuItem(key: _quitKey, label: 'Quit Notilus'),
        ]),
      );
    } catch (e) {
      debugPrint('Tray setup failed: $e');
    }
  }

  /// Brings the window to the foreground (used on incoming requests + tray click).
  Future<void> showWindow() async {
    if (!_inited || !_supported) return;
    try {
      if (!kIsWeb && !Platform.isMacOS) await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('Show window failed: $e');
    }
  }

  Future<void> _quit() async {
    _quitting = true;
    try {
      await trayManager.destroy();
    } catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ── WindowListener ──────────────────────────────────────────────────────
  @override
  void onWindowClose() async {
    if (_quitting) return;
    if (backgroundEnabled) {
      // Tuck away to the tray, off the taskbar/dock where the OS allows it.
      if (!kIsWeb && !Platform.isMacOS) await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    } else {
      await _quit();
    }
  }

  // ── TrayListener ────────────────────────────────────────────────────────
  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _showKey:
        showWindow();
        break;
      case _quitKey:
        _quit();
        break;
    }
  }
}
