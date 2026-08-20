import 'package:path/path.dart' as p;

/// Notilus addresses remote storage with a virtual path that looks like a URL
/// but is treated as a plain string everywhere else in the app:
///
///     notilus://<connectionId>/<path/inside/the/remote>
///
/// Keeping remote locations inside the same `String path` the local browser
/// already uses is what makes the feature feel native: selection, history,
/// breadcrumbs, the clipboard and drag-and-drop all keep working without a
/// parallel set of models. The only thing that has to change is *who* answers
/// a listing or a byte-copy for a given path, which is decided here.
///
/// Segments are stored decoded (a file really called `a b&c` is one segment
/// `a b&c`); percent-encoding happens only when a provider builds an HTTP URL.
const String kRemoteScheme = 'notilus';
const String _prefix = '$kRemoteScheme://';

/// A virtual path split into the connection it belongs to and the path inside
/// that connection. [path] always starts with `/` and never ends with one
/// (except the root, which is exactly `/`).
class RemoteRef {
  const RemoteRef({required this.connectionId, required this.path});

  final String connectionId;
  final String path;

  bool get isRoot => path == '/';

  /// Path segments, empty at the root.
  List<String> get segments =>
      path == '/' ? const [] : path.substring(1).split('/');

  /// The path with no leading slash — what most object stores want as a key.
  String get key => path == '/' ? '' : path.substring(1);

  @override
  String toString() => VPath.build(connectionId, path);
}

/// Path arithmetic that works for both local paths and `notilus://` ones.
///
/// Every call site that used `package:path` on a *browsed* path goes through
/// here instead: `p.dirname` on Windows would happily hand back
/// `notilus:\\conn\\a`, and `p.join` would glue segments with a backslash.
class VPath {
  const VPath._();

  static bool isRemote(String path) => path.startsWith(_prefix);

  /// Parses a `notilus://` path, or returns null for a local one.
  static RemoteRef? parse(String path) {
    if (!isRemote(path)) return null;
    final rest = path.substring(_prefix.length);
    final slash = rest.indexOf('/');
    final id = slash < 0 ? rest : rest.substring(0, slash);
    if (id.isEmpty) return null;
    final raw = slash < 0 ? '' : rest.substring(slash);
    return RemoteRef(connectionId: id, path: _normalize(raw));
  }

  /// The connection id a path belongs to, or null when it is local.
  static String? connectionOf(String path) => parse(path)?.connectionId;

  static String build(String connectionId, String path) =>
      '$_prefix$connectionId${_normalize(path)}';

  /// The root of a connection — what clicking it in the sidebar navigates to.
  static String root(String connectionId) => build(connectionId, '/');

  static bool isRemoteRoot(String path) => parse(path)?.isRoot ?? false;

  static String _normalize(String raw) {
    var out = raw.replaceAll('\\', '/');
    while (out.contains('//')) {
      out = out.replaceAll('//', '/');
    }
    if (!out.startsWith('/')) out = '/$out';
    if (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static String dirname(String path) {
    final ref = parse(path);
    if (ref == null) return p.dirname(path);
    if (ref.isRoot) return path;
    final cut = ref.path.lastIndexOf('/');
    return build(ref.connectionId, cut <= 0 ? '/' : ref.path.substring(0, cut));
  }

  static String basename(String path) {
    final ref = parse(path);
    if (ref == null) return p.basename(path);
    if (ref.isRoot) return '';
    return ref.path.substring(ref.path.lastIndexOf('/') + 1);
  }

  static String basenameWithoutExtension(String path) {
    final name = basename(path);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  static String extension(String path) {
    final name = basename(path);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }

  static String join(String parent, String child) {
    final ref = parse(parent);
    if (ref == null) return p.join(parent, child);
    final base = ref.isRoot ? '' : ref.path;
    return build(ref.connectionId, '$base/$child');
  }

  /// Display segments, used by the breadcrumb / status bar. The first segment
  /// of a remote path is the connection itself so the chain reads
  /// `S3 › bucket › folder`.
  static List<String> split(String path) {
    final ref = parse(path);
    if (ref == null) return path.isEmpty ? const [] : p.split(path);
    return [ref.connectionId, ...ref.segments];
  }

  /// True when [child] is [parent] or lives under it. Used to refuse a copy of
  /// a folder into itself, on either side of the local/remote line.
  static bool isWithin(String parent, String child) {
    if (parent == child) return true;
    final parentRef = parse(parent);
    final childRef = parse(child);
    if (parentRef == null && childRef == null) {
      return p.isWithin(parent, child);
    }
    if (parentRef == null || childRef == null) return false;
    if (parentRef.connectionId != childRef.connectionId) return false;
    if (parentRef.isRoot) return true;
    return childRef.path.startsWith('${parentRef.path}/');
  }

  static bool sameConnection(String a, String b) {
    final ra = parse(a);
    final rb = parse(b);
    if (ra == null || rb == null) return false;
    return ra.connectionId == rb.connectionId;
  }
}
