/// A very small, forgiving XML reader.
///
/// Both of the wire formats this feature needs — S3's ListObjectsV2 response
/// and WebDAV's PROPFIND multistatus — are XML, and neither needs anything
/// beyond "walk elements by local name and read their text". Pulling in a full
/// XML package for that would add a dependency for two response shapes, so
/// this parses the subset those two use: elements, attributes, text, CDATA,
/// comments, the prolog and a DOCTYPE. Namespaces are dropped — `d:href` and
/// `href` are the same node here, which is exactly what a DAV client wants,
/// since servers disagree about the prefix.
class XmlNode {
  XmlNode(this.name, {Map<String, String>? attributes})
      : attributes = attributes ?? const {};

  /// Local name: the part after any `prefix:`.
  final String name;
  final Map<String, String> attributes;
  final List<XmlNode> children = [];
  final StringBuffer _text = StringBuffer();

  String get text => _text.toString().trim();

  /// Direct children with the given local name.
  List<XmlNode> findAll(String name) =>
      [for (final c in children) if (c.name == name) c];

  XmlNode? find(String name) {
    for (final c in children) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// First descendant (any depth) with the given local name.
  XmlNode? findDeep(String name) {
    for (final c in children) {
      if (c.name == name) return c;
      final hit = c.findDeep(name);
      if (hit != null) return hit;
    }
    return null;
  }

  /// All descendants (any depth) with the given local name.
  List<XmlNode> findAllDeep(String name) {
    final out = <XmlNode>[];
    void walk(XmlNode node) {
      for (final c in node.children) {
        if (c.name == name) out.add(c);
        walk(c);
      }
    }

    walk(this);
    return out;
  }

  /// Text of the first direct child with this name, or '' when absent.
  String textOf(String name) => find(name)?.text ?? '';

  /// Text of the first descendant with this name, or '' when absent.
  String deepTextOf(String name) => findDeep(name)?.text ?? '';
}

/// Parses [source], returning the document element, or null when the input
/// isn't XML at all (an HTML error page from a proxy, say).
XmlNode? parseXml(String source) {
  final parser = _XmlParser(source);
  try {
    return parser.parse();
  } catch (_) {
    return null;
  }
}

class _XmlParser {
  _XmlParser(this.src);

  final String src;
  int pos = 0;

  XmlNode? parse() {
    final stack = <XmlNode>[];
    XmlNode? root;
    while (pos < src.length) {
      final lt = src.indexOf('<', pos);
      if (lt < 0) break;
      if (lt > pos && stack.isNotEmpty) {
        stack.last._text.write(_decode(src.substring(pos, lt)));
      }
      pos = lt;

      if (_startsWith('<!--')) {
        _skipTo('-->', 3);
        continue;
      }
      if (_startsWith('<![CDATA[')) {
        final end = src.indexOf(']]>', pos);
        final stop = end < 0 ? src.length : end;
        if (stack.isNotEmpty) {
          stack.last._text.write(src.substring(pos + 9, stop));
        }
        pos = end < 0 ? src.length : end + 3;
        continue;
      }
      if (_startsWith('<?') || _startsWith('<!')) {
        _skipTo('>', 1);
        continue;
      }
      if (_startsWith('</')) {
        final end = src.indexOf('>', pos);
        if (end < 0) break;
        pos = end + 1;
        if (stack.isNotEmpty) stack.removeLast();
        if (stack.isEmpty) return root;
        continue;
      }

      // An opening (possibly self-closing) tag.
      final end = _findTagEnd(pos);
      if (end < 0) break;
      final body = src.substring(pos + 1, end);
      pos = end + 1;
      final selfClosing = body.endsWith('/');
      final inner = selfClosing ? body.substring(0, body.length - 1) : body;
      final node = _element(inner);
      if (stack.isEmpty) {
        root ??= node;
      } else {
        stack.last.children.add(node);
      }
      if (!selfClosing) stack.add(node);
    }
    return root;
  }

  bool _startsWith(String token) => src.startsWith(token, pos);

  void _skipTo(String token, int skip) {
    final end = src.indexOf(token, pos + skip);
    pos = end < 0 ? src.length : end + token.length;
  }

  /// The index of the `>` closing the tag opened at [start], skipping any
  /// `>` that sits inside a quoted attribute value.
  int _findTagEnd(int start) {
    var quote = 0;
    for (var i = start + 1; i < src.length; i++) {
      final c = src.codeUnitAt(i);
      if (quote != 0) {
        if (c == quote) quote = 0;
        continue;
      }
      if (c == 0x22 || c == 0x27) {
        quote = c;
        continue;
      }
      if (c == 0x3E) return i;
    }
    return -1;
  }

  XmlNode _element(String body) {
    var i = 0;
    while (i < body.length && !_isSpace(body.codeUnitAt(i))) {
      i++;
    }
    final name = _local(body.substring(0, i));
    final attrs = <String, String>{};
    final rest = body.substring(i);
    final re = RegExp(r'''([\w:.\-]+)\s*=\s*("([^"]*)"|'([^']*)')''');
    for (final m in re.allMatches(rest)) {
      attrs[_local(m.group(1)!)] = _decode(m.group(3) ?? m.group(4) ?? '');
    }
    return XmlNode(name, attributes: attrs);
  }

  static bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  static String _local(String raw) {
    final colon = raw.indexOf(':');
    return colon < 0 ? raw : raw.substring(colon + 1);
  }
}

String _decode(String raw) {
  if (!raw.contains('&')) return raw;
  return raw.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|\w+);'), (m) {
    final body = m.group(1)!;
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final code = int.tryParse(body.substring(2), radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      final code = int.tryParse(body.substring(1));
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      default:
        return m.group(0)!;
    }
  });
}

/// Escapes text for inclusion in an XML body (WebDAV PROPFIND requests).
String xmlEscape(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
