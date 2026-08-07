/// The media categories the sidebar's Media section browses.
///
/// Deliberately UI-free: icons and colours live with the widgets that draw
/// them, so this stays importable from providers, services and tests without
/// dragging shadcn along.
enum MediaKind { images, videos, documents }

/// Canonical extension sets, lowercase and dot-prefixed to match
/// [FileEntry.extension] and the Rust searcher's `allowedExtensions`.
///
/// These are the single source of truth for "what counts as an image" across
/// the app — the Media pages and the Duplicate Finder's type filter both read
/// them, so the two can't drift apart.
const Set<String> kImageExtensions = {
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.heif',
  '.tif', '.tiff', '.ico', '.svg', '.avif',
};

const Set<String> kVideoExtensions = {
  '.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.m4v', '.mpg', '.mpeg',
  '.wmv', '.3gp',
};

const Set<String> kAudioExtensions = {
  '.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wma',
};

const Set<String> kDocumentExtensions = {
  '.pdf', '.doc', '.docx', '.txt', '.md', '.rtf', '.odt', '.pages',
  '.xls', '.xlsx', '.csv', '.ods', '.numbers',
  '.ppt', '.pptx', '.odp', '.key',
  '.epub', '.mobi',
};

extension MediaKindInfo on MediaKind {
  /// Page title and sidebar label.
  String get label {
    switch (this) {
      case MediaKind.images:
        return 'Images';
      case MediaKind.videos:
        return 'Videos';
      case MediaKind.documents:
        return 'Documents';
    }
  }

  String get singularNoun {
    switch (this) {
      case MediaKind.images:
        return 'image';
      case MediaKind.videos:
        return 'video';
      case MediaKind.documents:
        return 'document';
    }
  }

  String get pluralNoun => '${singularNoun}s';

  /// "1 image" / "24 images" — the count line under the page title.
  String countLabel(int n) => '$n ${n == 1 ? singularNoun : pluralNoun}';

  Set<String> get extensions {
    switch (this) {
      case MediaKind.images:
        return kImageExtensions;
      case MediaKind.videos:
        return kVideoExtensions;
      case MediaKind.documents:
        return kDocumentExtensions;
    }
  }
}
