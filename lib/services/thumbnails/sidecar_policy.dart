import 'package:path/path.dart' as p;

import '../remote/remote_path.dart';
import 'sidecar_naming.dart';

/// Where a folder's thumbnails belong.
enum ThumbnailHome {
  /// A hidden `.thumbs` beside the data, so anything that reaches the folder
  /// finds the thumbnails already made.
  sidecar,

  /// This machine's own cache directory. Only reached when the folder itself
  /// won't take a write — a read-only drive, a share without write access, a
  /// bucket without `PutObject`.
  central,
}

/// Decides where a folder's thumbnails are written.
///
/// The answer is "beside the data" for everything, including the internal disk.
///
/// The internal disk is not a special case, because "only this machine sees
/// it" is wrong more often than it's right. A folder on this laptop's own disk
/// is what a Notilus SMB share publishes; it's what gets copied to a drive and
/// carried somewhere else; it's what a second machine reaches over SFTP. Every
/// one of those means the work of thumbnailing it is worth keeping where the
/// next reader will find it, and the machine-local cache is unreachable from
/// all of them.
///
/// That is the whole idea: whoever looks first pays once, and everyone after —
/// this machine after a reinstall, another laptop over SMB, a phone on the same
/// share — gets it free.
///
/// The cost is real and accepted: hidden `.thumbs` folders appear in browsed
/// folders, including ones under version control or in a backup set. They are
/// filtered out of every listing Notilus shows, even with hidden files on.
class SidecarPolicy {
  const SidecarPolicy._();

  /// Whether a folder's thumbnails should be written beside it.
  static ThumbnailHome homeFor(String folderPath) =>
      _isInsideSidecar(folderPath) ? ThumbnailHome.central : ThumbnailHome.sidecar;

  /// Whether this folder is itself inside a `.thumbs`.
  ///
  /// The one exclusion. Browsing a `.thumbs` — it is a real folder, and "show
  /// hidden" plus a typed path will get you there — must not start thumbnailing
  /// thumbnails into a `.thumbs/.thumbs`.
  static bool _isInsideSidecar(String folderPath) {
    final segments = VPath.isRemote(folderPath)
        ? folderPath.split('/')
        : p.split(p.normalize(folderPath));
    return segments.any((s) => s == kSidecarDir);
  }
}
