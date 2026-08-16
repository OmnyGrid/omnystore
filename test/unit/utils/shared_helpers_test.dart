import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnystore/src/storage/cloud_support.dart';
import 'package:omnystore/src/utils/hex.dart';
import 'package:omnystore/src/utils/names.dart';
import 'package:omnystore/src/utils/rfc3986.dart';
import 'package:test/test.dart';

/// Covers the helpers the S3 and GCS backends share.
///
/// They are exercised transitively by the signing and object-storage suites,
/// but a signature mismatch there says nothing about which helper drifted.
/// These tests pin the behaviour both backends depend on.
void main() {
  group('Hex', () {
    test('encodes bytes as lower-case pairs, padding single digits', () {
      expect(Hex.encode([0x00, 0x0f, 0xa0, 0xff]), '000fa0ff');
    });

    test('encodes an empty list as an empty string', () {
      expect(Hex.encode([]), '');
    });

    test('round-trips through tryDecode', () {
      const bytes = [0xde, 0xad, 0xbe, 0xef];
      expect(Hex.tryDecode(Hex.encode(bytes)), bytes);
    });

    test('tryDecode accepts upper case', () {
      expect(Hex.tryDecode('DEADBEEF'), [0xde, 0xad, 0xbe, 0xef]);
    });

    test('tryDecode returns null for an odd length or a non-hex digit', () {
      expect(Hex.tryDecode('abc'), isNull);
      expect(Hex.tryDecode('zz'), isNull);
    });
  });

  group('Rfc3986', () {
    test('leaves the unreserved set alone', () {
      const unreserved =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
          'abcdefghijklmnopqrstuvwxyz'
          '0123456789-._~';
      expect(Rfc3986.encodeComponent(unreserved), unreserved);
    });

    test('escapes the characters Uri.encodeComponent leaves bare', () {
      // The whole reason for a hand-rolled encoder: both signing schemes
      // require these escaped, and Dart's does not escape them.
      expect(Rfc3986.encodeComponent("!*'()"), '%21%2A%27%28%29');
      expect(Uri.encodeComponent("!*'()"), "!*'()");
    });

    test('escapes the path separator in a component', () {
      expect(Rfc3986.encodeComponent('a/b'), 'a%2Fb');
    });

    test('escapes multi-byte UTF-8 one byte at a time', () {
      expect(Rfc3986.encodeComponent('é'), '%C3%A9');
    });

    test('encodePath keeps separators and encodes each segment', () {
      expect(
        Rfc3986.encodePath('releases/v1 0/app.dmg'),
        'releases/v1%200/app.dmg',
      );
    });

    test('canonicalQuery sorts by encoded name, then encoded value', () {
      expect(
        Rfc3986.canonicalQuery({'b': '2', 'a': '1', 'A': '0'}),
        'A=0&a=1&b=2',
      );
    });

    test('canonicalQuery encodes both sides of each pair', () {
      expect(
        Rfc3986.canonicalQuery({'response-content-disposition': 'a b"c'}),
        'response-content-disposition=a%20b%22c',
      );
    });

    test('canonicalQuery is empty for no parameters', () {
      expect(Rfc3986.canonicalQuery(const {}), '');
    });
  });

  group('CloudStorageSupport', () {
    test('normalizePrefix trims both ends and appends one separator', () {
      expect(CloudStorageSupport.normalizePrefix('/artifacts/'), 'artifacts/');
      expect(CloudStorageSupport.normalizePrefix('artifacts'), 'artifacts/');
    });

    test('normalizePrefix leaves an empty prefix empty', () {
      // An empty prefix must not become '/', which would make every key
      // absolute and put the objects in an unnamed top-level folder.
      expect(CloudStorageSupport.normalizePrefix(''), '');
      expect(CloudStorageSupport.normalizePrefix('///'), '');
    });

    test('trimSlashes strips leading and trailing separators only', () {
      expect(CloudStorageSupport.trimSlashes('/a/b/'), 'a/b');
    });

    test('totalSizeOf prefers the total in content-range', () {
      final response = http.StreamedResponse(
        const Stream.empty(),
        206,
        contentLength: 10,
        headers: const {'content-range': 'bytes 0-9/512'},
      );
      expect(CloudStorageSupport.totalSizeOf(response), 512);
    });

    test('totalSizeOf falls back to content-length', () {
      final response = http.StreamedResponse(
        const Stream.empty(),
        200,
        contentLength: 512,
      );
      expect(CloudStorageSupport.totalSizeOf(response), 512);
    });

    test('totalSizeOf ignores an unparseable content-range', () {
      final response = http.StreamedResponse(
        const Stream.empty(),
        206,
        contentLength: 7,
        headers: const {'content-range': 'bytes */*'},
      );
      expect(CloudStorageSupport.totalSizeOf(response), 7);
    });

    test('truncateBody leaves a short body intact', () {
      expect(CloudStorageSupport.truncateBody('nope'), 'nope');
    });

    test('truncateBody caps a long body with an ellipsis', () {
      final truncated = CloudStorageSupport.truncateBody('x' * 500);
      expect(truncated.length, 201);
      expect(truncated, endsWith('…'));
    });
  });

  group('Names.sanitizeForHeader', () {
    test('strips the quote that would break out of the header value', () {
      expect(Names.sanitizeForHeader('a".dmg'), 'a.dmg');
    });

    test('strips backslashes, control characters and DEL', () {
      expect(Names.sanitizeForHeader('a\r\nb\x7fcd\\e.dmg'), 'abcde.dmg');
    });

    test('keeps spaces and other printable characters', () {
      expect(
        Names.sanitizeForHeader('Acme Installer.dmg'),
        'Acme Installer.dmg',
      );
    });

    test('leaves multi-byte characters alone', () {
      expect(Names.sanitizeForHeader('café.dmg'), 'café.dmg');
      expect(utf8.encode(Names.sanitizeForHeader('café.dmg')).length, 9);
    });
  });
}
