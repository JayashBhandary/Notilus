import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/services/remote/remote_path.dart';
import 'package:notilus/services/remote/xml_lite.dart';

void main() {
  group('VPath', () {
    const conn = 'abc-123';
    final root = VPath.root(conn);
    final folder = VPath.build(conn, '/bucket/photos');

    test('recognises its own scheme and leaves local paths alone', () {
      expect(VPath.isRemote(root), isTrue);
      expect(VPath.isRemote('/home/jay/Documents'), isFalse);
      expect(VPath.isRemote(r'C:\Users\jay'), isFalse);
      expect(VPath.connectionOf(folder), conn);
      expect(VPath.connectionOf('/home/jay'), isNull);
    });

    test('normalises slashes, so a root is always exactly one', () {
      expect(VPath.build(conn, ''), root);
      expect(VPath.build(conn, '/'), root);
      expect(VPath.build(conn, 'bucket//photos/'), folder);
      expect(VPath.parse(root)!.isRoot, isTrue);
      expect(VPath.parse(folder)!.key, 'bucket/photos');
      expect(VPath.parse(folder)!.segments, ['bucket', 'photos']);
    });

    test('dirname stops at the root instead of walking past it', () {
      expect(VPath.dirname(folder), VPath.build(conn, '/bucket'));
      expect(VPath.dirname(VPath.build(conn, '/bucket')), root);
      expect(VPath.dirname(root), root);
    });

    test('basename and join work on names local paths would reject', () {
      final file = VPath.join(folder, 'holiday 2019 (final).jpg');
      expect(VPath.basename(file), 'holiday 2019 (final).jpg');
      expect(VPath.basenameWithoutExtension(file), 'holiday 2019 (final)');
      expect(VPath.extension(file), '.jpg');
      // A leading-dot name is an extension-less file, not an extension.
      expect(VPath.extension(VPath.join(folder, '.env')), '');
    });

    test('join builds paths under the same connection', () {
      expect(VPath.join(root, 'bucket'), VPath.build(conn, '/bucket'));
      expect(VPath.join(folder, 'raw'), VPath.build(conn, '/bucket/photos/raw'));
    });

    test('split puts the connection first so a breadcrumb can name it', () {
      expect(VPath.split(folder), [conn, 'bucket', 'photos']);
      expect(VPath.split(''), isEmpty);
    });

    test('isWithin refuses a copy into itself and never crosses sources', () {
      expect(VPath.isWithin(folder, folder), isTrue);
      expect(VPath.isWithin(folder, VPath.join(folder, 'raw')), isTrue);
      expect(VPath.isWithin(folder, VPath.build(conn, '/bucket/photos-2')),
          isFalse);
      expect(VPath.isWithin(folder, VPath.build('other', '/bucket/photos/raw')),
          isFalse);
      // A remote path is never inside a local one, whatever the strings say.
      expect(VPath.isWithin('/home/jay', VPath.build(conn, '/home/jay/x')),
          isFalse);
    });

    test('sameConnection only holds for two paths on one source', () {
      expect(VPath.sameConnection(root, folder), isTrue);
      expect(VPath.sameConnection(folder, VPath.build('other', '/x')), isFalse);
      expect(VPath.sameConnection('/home/jay', '/home/jay/x'), isFalse);
    });
  });

  group('xml_lite', () {
    test('reads an S3 ListObjectsV2 response', () {
      const body = '''
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>photos</Name>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>trip/beach.jpg</Key>
    <LastModified>2024-05-02T09:31:00.000Z</LastModified>
    <Size>184320</Size>
  </Contents>
  <CommonPrefixes><Prefix>trip/raw/</Prefix></CommonPrefixes>
</ListBucketResult>''';
      final xml = parseXml(body)!;
      expect(xml.name, 'ListBucketResult');
      expect(xml.textOf('IsTruncated'), 'false');
      final contents = xml.findAll('Contents');
      expect(contents, hasLength(1));
      expect(contents.first.textOf('Key'), 'trip/beach.jpg');
      expect(contents.first.textOf('Size'), '184320');
      expect(xml.findAll('CommonPrefixes').first.textOf('Prefix'), 'trip/raw/');
    });

    test('drops namespace prefixes so any DAV server parses the same', () {
      const body = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/files/jay/Notes%20%26%20drafts</d:href>
    <d:propstat><d:prop>
      <d:displayname>Notes &amp; drafts</d:displayname>
      <d:resourcetype><d:collection/></d:resourcetype>
      <d:getlastmodified>Tue, 04 Jun 2024 11:02:31 GMT</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
      final xml = parseXml(body)!;
      final responses = xml.findAllDeep('response');
      expect(responses, hasLength(1));
      final prop = responses.first.findDeep('prop')!;
      expect(prop.deepTextOf('displayname'), 'Notes & drafts');
      expect(prop.findDeep('collection'), isNotNull);
      expect(prop.deepTextOf('getcontentlength'), '');
    });

    test('survives comments, CDATA, attributes and self-closing tags', () {
      const body = '<?xml version="1.0"?><root a="1&gt;0" b=\'x y\'>'
          '<!-- ignore me --><empty/><text><![CDATA[a > b & c]]></text></root>';
      final xml = parseXml(body)!;
      expect(xml.attributes['a'], '1>0');
      expect(xml.attributes['b'], 'x y');
      expect(xml.find('empty'), isNotNull);
      expect(xml.textOf('text'), 'a > b & c');
    });

    test('returns null rather than throwing on non-XML', () {
      expect(parseXml('<html><body>502 Bad Gateway'), isNotNull);
      expect(parseXml('not xml at all'), isNull);
    });

    test('escapes text for request bodies', () {
      expect(xmlEscape('a & b < c'), 'a &amp; b &lt; c');
    });
  });
}
