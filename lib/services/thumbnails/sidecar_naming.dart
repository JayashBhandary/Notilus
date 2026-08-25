/// Names for thumbnails that live beside the data they describe.
///
/// The Rust side owns the same scheme — see `core/src/api/thumbnail.rs` — and
/// both are pinned to the same test vector. It is duplicated rather than called
/// over the bridge because a listing of 400 files needs 400 names while the
/// listing is being assembled, and 400 async round trips to answer "do I
/// already have this one" would cost more than the decodes it saves.
library;

/// The hidden folder thumbnails live in, beside the data.
const String kSidecarDir = '.thumbs';

/// The one size stored on disk. Every surface downscales from this in memory
/// rather than asking for its own, so a phone at 96px and a desktop at 320px
/// share one file instead of generating two.
const int kSidecarMasterDim = 512;

/// Largest `.thumbs` entry worth reading.
///
/// A `.thumbs` on a shared source is writable by other people. Anything this
/// code wrote is tens of kilobytes; a megabyte-plus entry was not, and is not
/// worth pulling over the network to find out what it is.
const int kMaxSidecarBytes = 2 * 1024 * 1024;

/// The `.thumbs` filename for one directory entry.
///
/// [name] is the entry's own name, never a path — that is the whole point.
/// A key with `/media/jayash/photos` in it means the same drive mounted at
/// `/Volumes/photos` misses every thumbnail on it; a key with only the name,
/// size and time in it travels with the folder.
///
/// [modifiedMs] is rounded down to whole seconds. Sources disagree below that:
/// SMB reports 100-nanosecond ticks, S3's `LastModified` is whole seconds,
/// FAT32 rounds to two. Keeping milliseconds would make a thumbnail written
/// from an SMB mount invisible to the same folder reached over S3.
String sidecarName({
  required String name,
  required int size,
  required int modifiedMs,
  int dim = kSidecarMasterDim,
}) {
  final seconds = _floorDiv(modifiedMs, 1000);
  return '${sidecarPrefix(name)}${size}_${seconds}_$dim.webp';
}

/// The leading, name-only part of a [sidecarName], including its separator.
///
/// Every entry in a `.thumbs` folder starting with this describes the same file
/// name. At most one is current; the others are thumbnails of versions that
/// have since been edited, and are what a sweep deletes.
String sidecarPrefix(String name) => '${fnv1aHex(name.toLowerCase())}_';

/// Whether [entry] is a thumbnail of a version of [name] that no longer exists.
bool isStaleSidecar(String entry, String name, String currentName) =>
    entry != currentName && entry.startsWith(sidecarPrefix(name));

/// FNV-1a, 64-bit, as sixteen lower-case hex digits.
///
/// Must agree byte for byte with `fnv1a_hex` in `core/src/api/thumbnail.rs`, or
/// a thumbnail written by one side is invisible to the other.
///
/// The obvious implementation is wrong here, and was: Dart's integers are
/// signed 64-bit, so `0xFFFFFFFFFFFFFFFF` is `-1` and masking with it does
/// nothing, leaving `toRadixString(16)` to emit a leading minus sign for every
/// hash with its top bit set — half of all inputs. The old cache is full of
/// files called `-be805be934a29fb.png`. Splitting into two 32-bit halves and
/// padding each is what formats the same bits Rust prints.
String fnv1aHex(String value) {
  var h = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  // Hash the UTF-8 bytes, not the UTF-16 code units: Rust hashes bytes, and
  // any name outside ASCII would otherwise disagree across the two.
  for (final byte in _utf8Bytes(value)) {
    h ^= byte;
    h = h * prime;
  }
  final hi = (h >> 32) & 0xFFFFFFFF;
  final lo = h & 0xFFFFFFFF;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

/// UTF-8 bytes of [value], without pulling in a converter — this runs once per
/// listed file, so it stays allocation-light.
List<int> _utf8Bytes(String value) {
  final out = <int>[];
  for (final rune in value.runes) {
    if (rune < 0x80) {
      out.add(rune);
    } else if (rune < 0x800) {
      out..add(0xC0 | (rune >> 6))..add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      out
        ..add(0xE0 | (rune >> 12))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    } else {
      out
        ..add(0xF0 | (rune >> 18))
        ..add(0x80 | ((rune >> 12) & 0x3F))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    }
  }
  return out;
}

/// Floor division, which `~/` is not for negative numerators: `-1500 ~/ 1000`
/// is 1 second short of the truth, putting a pre-epoch file in the same second
/// as one 2 seconds later.
int _floorDiv(int a, int b) {
  final q = a ~/ b;
  return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}
