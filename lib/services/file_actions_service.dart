import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/file_entry.dart';

/// Cross-platform shell integration: opening items in other applications and
/// revealing them in the system file manager.
///
/// Mutating operations used to live here too — rename, duplicate, trash — but
/// they now run in the Rust core, which gets progress, cancellation, a real
/// recycle bin on every platform, and collision handling that can't destroy
/// data. What remains is the part that genuinely has to talk to the host OS.
class FileActionsService {
  bool get _isMacOS => !kIsWeb && Platform.isMacOS;
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  /// Opens the entry in the system's default associated app.
  /// macOS: `open <path>`. iOS: presents the system share sheet.
  Future<bool> openInDefaultApp(FileEntry entry) async {
    if (_isMacOS) {
      final r = await Process.run('open', [entry.path]);
      return r.exitCode == 0;
    }
    if (_isIOS) {
      // Share sheet is the iOS equivalent of "Open With".
      final result = await Share.shareXFiles([XFile(entry.path)]);
      return result.status != ShareResultStatus.unavailable;
    }
    return false;
  }

  /// macOS: shows the native "Choose Application" dialog (StandardAdditions
  /// `choose application`) and opens the entry in the picked app.
  /// iOS: presents the share sheet so the user can pick a receiver.
  /// Returns false if the user cancelled or no compatible flow exists.
  Future<bool> openWithChooser(FileEntry entry) async {
    if (_isMacOS) {
      final escaped =
          entry.path.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final script =
          'tell application "Finder" to open POSIX file "$escaped" '
          'using (choose application)';
      final r = await Process.run('osascript', ['-e', script]);
      return r.exitCode == 0;
    }
    return openInDefaultApp(entry);
  }

  /// Copies the entry's absolute path to the system clipboard.
  Future<void> copyPath(FileEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.path));
  }

  /// macOS: reveals the entry in Finder (`open -R`). Returns false on iOS.
  Future<bool> revealInOs(FileEntry entry) async {
    if (_isMacOS) {
      final r = await Process.run('open', ['-R', entry.path]);
      return r.exitCode == 0;
    }
    return false;
  }
}
