import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:notilus/src/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

/// Loads the Rust core into the Dart test VM.
///
/// Tests don't run inside the Flutter app bundle, so the library the app links
/// at build time isn't on the loader path. This opens the `cargo build` output
/// directly, which means the Dart-side tests exercise the same code the app
/// ships rather than a stand-in.
///
/// Returns false when the library hasn't been built yet, so a suite can skip
/// instead of failing with an unrelated FFI error. Build it with:
///
/// ```text
/// cargo build --manifest-path core/Cargo.toml
/// ```
class NativeTestSupport {
  static bool? _available;

  /// True once the core is loaded and callable.
  static Future<bool> ensureLoaded() async {
    if (_available != null) return _available!;

    final library = _locate();
    if (library == null) {
      _available = false;
      return false;
    }
    try {
      await NotilusCore.init(
        externalLibrary: ExternalLibrary.open(library),
      );
      _available = true;
    } catch (_) {
      // Already initialised by an earlier suite in the same VM, or the library
      // is unloadable. Probe rather than guess.
      _available = NotilusCore.instance.initialized;
    }
    return _available!;
  }

  /// Whether the library is on disk, decided synchronously.
  ///
  /// `skip:` is evaluated while a suite is being *registered*, before any
  /// `setUpAll` has run — so a flag set by [ensureLoaded] is still false at
  /// that point and every test would skip. This is the check to use there.
  static bool get isBuilt => _locate() != null;

  /// Finds the built dynamic library for this platform, preferring release.
  static String? _locate() {
    final name = Platform.isWindows
        ? 'notilus_core.dll'
        : Platform.isMacOS
            ? 'libnotilus_core.dylib'
            : 'libnotilus_core.so';

    // Tests run from the project root.
    for (final profile in const ['release', 'debug']) {
      final candidate = p.join('core', 'target', profile, name);
      if (File(candidate).existsSync()) return p.absolute(candidate);
    }
    return null;
  }

  /// Message explaining a skip, so a skipped suite says why.
  static const skipReason =
      'Rust core not built — run `cargo build --manifest-path core/Cargo.toml`';
}
