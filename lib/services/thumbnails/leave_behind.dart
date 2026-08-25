import 'dart:async';

import '../../models/file_entry.dart';
import '../thumbnail_service.dart';
import 'sidecar_thumbnails.dart';

/// Leaves a thumbnail in [entry]'s own folder, made from a local copy of it.
///
/// This is the moment the whole scheme turns on. A file on a share or in a
/// bucket cannot be thumbnailed by browsing past it — that would mean pulling
/// every byte of every file in the folder. But the instant its bytes are here
/// for some *other* reason, because the user previewed it or downloaded it, a
/// thumbnail costs one decode of data already paid for. Writing it back into
/// the source's `.thumbs` is what means the next machine to open that folder —
/// a phone, a second laptop, an SMB client that isn't Notilus at all — sees the
/// file without anyone opening it again.
///
/// [entry] must be the file at its **source**: its name, size and time are what
/// the thumbnail is keyed on, so a machine that finds it later recognises it.
/// [localPath] is where the bytes happen to be sitting — the download cache,
/// the copy just pasted onto this disk. Passing the local copy as [entry] would
/// key the thumbnail on the temporary file and nobody would ever find it.
///
/// Never throws and never worth awaiting for correctness: the user asked for a
/// preview or a download, and neither the wait nor a failure belongs in front
/// of that.
Future<void> leaveThumbnailBeside(FileEntry entry, String localPath) async {
  try {
    // An image the codec can open goes straight through.
    if (await SidecarThumbnails.instance.generateFromFile(entry, localPath) !=
        null) {
      return;
    }
    // Everything else — a PDF, a video, an office document — needs its own
    // renderer first, and those only work on a real file. Which is exactly
    // what is sitting at [localPath], so this is the one moment a cloud PDF
    // can be thumbnailed at all.
    final local = FileEntry(
      path: localPath,
      name: entry.name,
      isDirectory: false,
      size: entry.size,
      modified: entry.modified,
    );
    final service = ThumbnailService.instance;
    if (!service.hasRenderedPreview(local) &&
        !service.hasEmbeddedPreview(local)) {
      return;
    }
    final rendered = await service.renderedThumbnail(local);
    if (rendered == null) return;
    // Stored under the *source* file's identity, not the local copy's.
    await SidecarThumbnails.instance
        .generateFromBytes(entry, await rendered.readAsBytes());
  } catch (_) {
    // No renderer on this machine, or the source won't take writes. What the
    // user actually asked for is unaffected either way.
  }
}
