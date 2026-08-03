import 'dart:io';
import 'dart:typed_data';

/// Transparently gunzips compressed SVG (`.svgz`) payloads.
///
/// Uses `dart:io`'s [gzip] codec — native zlib inside the VM — rather than the
/// pure-Dart inflate from `package:archive`. The Dart decoder ran on whichever
/// isolate called it, which for both the grid thumbnail and the full preview is
/// the UI isolate, so a large SVG cost frame time to decompress.
///
/// Detection is by gzip magic bytes rather than by extension: a `.svg` that is
/// actually gzipped still renders, and a `.svgz` that isn't compressed doesn't
/// throw. A failed inflate falls back to the raw bytes for the same reason —
/// a mislabelled file should render if it can, not error.
Uint8List maybeGunzip(Uint8List raw) {
  if (raw.length < 2 || raw[0] != 0x1F || raw[1] != 0x8B) return raw;
  try {
    final inflated = gzip.decode(raw);
    // A corrupt stream doesn't throw — `gzip.decode` hands back an empty list —
    // so the emptiness *is* the error signal. Without this check a damaged
    // `.svgz` renders as a blank frame instead of falling through to the raw
    // bytes, which at least has a chance of parsing.
    if (inflated.isEmpty) return raw;
    return Uint8List.fromList(inflated);
  } catch (_) {
    return raw;
  }
}

/// Reads [path], gunzipping it if it turns out to be gzip-compressed.
Future<Uint8List> readMaybeGzipped(String path) async =>
    maybeGunzip(await File(path).readAsBytes());
