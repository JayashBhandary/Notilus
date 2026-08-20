import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/services/remote/http_util.dart';
import 'package:notilus/services/remote/remote_path.dart';
import 'package:notilus/services/remote/s3_file_system.dart';

void main() {
  group('SigV4', () {
    // AWS publishes this exact case in the "Signing AWS requests" reference:
    // a presigned GET for s3://examplebucket/test.txt, valid 24 hours, signed
    // at 2013-05-24T00:00:00Z with the documented example credentials. If the
    // canonical request, the string to sign or the key derivation is wrong by
    // one byte, the signature below won't match — which makes this one
    // assertion the test for the whole signer.
    test('reproduces the published presigned-URL vector', () async {
      final fs = S3FileSystem(
        connectionId: 'vector',
        region: 'us-east-1',
        bucket: 'examplebucket',
        accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
        secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        clock: () => DateTime.utc(2013, 5, 24),
      );

      final link = await fs.shareLink(
        VPath.build('vector', '/test.txt'),
        expiresIn: const Duration(hours: 24),
      );

      expect(link, startsWith('https://examplebucket.s3.amazonaws.com/test.txt?'));
      final query = Uri.parse(link!).queryParameters;
      expect(query['X-Amz-Algorithm'], 'AWS4-HMAC-SHA256');
      expect(
        query['X-Amz-Credential'],
        'AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request',
      );
      expect(query['X-Amz-Date'], '20130524T000000Z');
      expect(query['X-Amz-Expires'], '86400');
      expect(query['X-Amz-SignedHeaders'], 'host');
      expect(
        query['X-Amz-Signature'],
        'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
      );
      fs.close();
    });

    test('addresses AWS virtual-hosted and self-hosted path-style', () async {
      final aws = S3FileSystem(
        connectionId: 'aws',
        region: 'eu-west-1',
        bucket: 'photos',
        accessKeyId: 'A',
        secretAccessKey: 'B',
      );
      final minio = S3FileSystem(
        connectionId: 'minio',
        region: 'us-east-1',
        bucket: 'photos',
        endpoint: 'http://192.168.1.5:9000',
        accessKeyId: 'A',
        secretAccessKey: 'B',
      );

      expect(
        await aws.shareLink(VPath.build('aws', '/a.jpg')),
        startsWith('https://photos.s3.eu-west-1.amazonaws.com/a.jpg?'),
      );
      // A custom endpoint is assumed path-style, and its port survives into
      // both the URL and the signed host header.
      expect(
        await minio.shareLink(VPath.build('minio', '/a.jpg')),
        startsWith('http://192.168.1.5:9000/photos/a.jpg?'),
      );
      aws.close();
      minio.close();
    });

    test('a key with spaces and symbols is encoded once, and correctly',
        () async {
      final fs = S3FileSystem(
        connectionId: 'enc',
        region: 'us-east-1',
        bucket: 'b',
        accessKeyId: 'A',
        secretAccessKey: 'B',
      );

      final link =
          await fs.shareLink(VPath.build('enc', '/holiday 2019/a+b (1).jpg'));

      expect(link, contains('/holiday%202019/a%2Bb%20%281%29.jpg?'));
      // Slashes stay separators; nothing is double-encoded.
      expect(link, isNot(contains('%252F')));
      fs.close();
    });

    test('folders are keys: a root listing path maps to no object', () async {
      final fs = S3FileSystem(
        connectionId: 'root',
        region: 'us-east-1',
        accessKeyId: 'A',
        secretAccessKey: 'B',
      );
      // Without a fixed bucket the virtual root is the bucket list, which is
      // not a shareable object.
      expect(await fs.shareLink(VPath.root('root')), isNull);
      fs.close();
    });
  });

  group('percent encoding', () {
    test('encodes the characters Uri.encodeComponent leaves alone', () {
      expect(uriEncodeComponent("a!*'()b"), 'a%21%2A%27%28%29b');
      expect(uriEncodeComponent('sp ace'), 'sp%20ace');
      expect(uriEncodeComponent('~-_.'), '~-_.');
      // Non-ASCII goes out as UTF-8 bytes.
      expect(uriEncodeComponent('é'), '%C3%A9');
    });

    test('path encoding keeps separators', () {
      expect(uriEncodePath('/a b/c&d'), '/a%20b/c%26d');
    });
  });
}
