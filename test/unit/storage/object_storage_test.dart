import 'dart:convert';
import 'dart:io';

import 'package:omnystore/omnystore.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/harness.dart';

void main() {
  group('ByteRange', () {
    test('renders and parses an HTTP range header', () {
      expect(ByteRange(0, 1023).toHeaderValue(), 'bytes=0-1023');
      expect(ByteRange.from(500).toHeaderValue(), 'bytes=500-');

      expect(ByteRange.parseHeader('bytes=0-1023'), ByteRange(0, 1023));
      expect(ByteRange.parseHeader('bytes=500-'), ByteRange(500));
      expect(ByteRange.parseHeader(' bytes=10-20 '), ByteRange(10, 20));
    });

    test('ignores a header it cannot satisfy rather than rejecting it', () {
      // RFC 9110: an unsatisfiable Range must be ignored and the full
      // representation served, not answered with an error.
      expect(ByteRange.parseHeader(null), isNull);
      expect(ByteRange.parseHeader('bytes=-500'), isNull);
      expect(ByteRange.parseHeader('bytes=0-10,20-30'), isNull);
      expect(ByteRange.parseHeader('items=0-10'), isNull);
      expect(ByteRange.parseHeader('bytes=20-10'), isNull);
    });

    test('rejects a malformed range built in code', () {
      expect(() => ByteRange(-1), throwsA(isA<ValidationException>()));
      expect(() => ByteRange(10, 5), throwsA(isA<ValidationException>()));
    });

    test('computes the served length, clamped to the object', () {
      expect(ByteRange(0, 9).lengthFor(100), 10);
      expect(ByteRange(90, 200).lengthFor(100), 10);
      expect(ByteRange.from(95).lengthFor(100), 5);
      expect(ByteRange.from(100).lengthFor(100), 0);
    });

    test('renders content-range against the real object size', () {
      expect(ByteRange(6, 10).toContentRange(11), 'bytes 6-10/11');
      expect(ByteRange.from(6).toContentRange(11), 'bytes 6-10/11');
      expect(ByteRange(0, 999).toContentRange(11), 'bytes 0-10/11');
    });

    test('detects a range past the end', () {
      expect(ByteRange.from(100).isUnsatisfiableFor(100), isTrue);
      expect(ByteRange.from(99).isUnsatisfiableFor(100), isFalse);
      expect(ByteRange.from(0).isUnsatisfiableFor(0), isFalse);
    });

    test('has value equality', () {
      expect(ByteRange(1, 2), ByteRange(1, 2));
      expect(ByteRange(1, 2).hashCode, ByteRange(1, 2).hashCode);
      expect(ByteRange(1, 2), isNot(ByteRange(1, 3)));
    });
  });

  group('StorageKeys', () {
    test('lays out a readable hierarchy', () {
      expect(
        StorageKeys.forAsset(
          organization: 'acme',
          package: 'omnyagent',
          version: '1.2.0',
          filename: 'agent-linux-x64.tar.gz',
        ),
        'orgs/acme/packages/omnyagent/1.2.0/agent-linux-x64.tar.gz',
      );
    });

    test('nests prefixes so a release delete is a prefix delete', () {
      const organization = 'acme';
      const package = 'omnyagent';
      final key = StorageKeys.forAsset(
        organization: organization,
        package: package,
        version: '1.2.0',
        filename: 'agent.tar.gz',
      );

      expect(
        key,
        startsWith(
          StorageKeys.releasePrefix(
            organization: organization,
            package: package,
            version: '1.2.0',
          ),
        ),
      );
      expect(
        key,
        startsWith(
          StorageKeys.packagePrefix(
            organization: organization,
            package: package,
          ),
        ),
      );
      expect(key, startsWith(StorageKeys.organizationPrefix(organization)));
    });

    test('accepts a normalised relative key', () {
      expect(
        StorageKeys.requireSafe('orgs/acme/packages/a/1.0.0/x.tar.gz'),
        isNotEmpty,
      );
    });

    test('rejects a key that could escape its root', () {
      for (final key in [
        '',
        '/absolute',
        r'back\slash',
        'double//slash',
        'a/../b',
        './a',
        'a/./b',
      ]) {
        expect(
          () => StorageKeys.requireSafe(key),
          throwsA(isA<ValidationException>()),
          reason: key,
        );
      }
    });
  });

  /// The contract every [ObjectStorage] must satisfy, run against each backend.
  ///
  /// Written once and applied to both bundled implementations, so a test that
  /// passes in memory is testing the same semantics a real deployment gets —
  /// and so a future backend can be validated by adding one line here.
  void objectStorageContract(
    String label,
    Future<ObjectStorage> Function() open, {
    Future<void> Function(ObjectStorage storage)? dispose,
  }) {
    group('$label (ObjectStorage contract)', () {
      late ObjectStorage storage;

      setUp(() async => storage = await open());
      tearDown(() async {
        await (dispose?.call(storage) ?? storage.close());
      });

      Stream<List<int>> bytesOf(String text) => Stream.value(utf8.encode(text));

      test('stores and reads an object back', () async {
        final stored = await storage.put('a/b/c.txt', bytesOf('hello'));

        expect(stored.key, 'a/b/c.txt');
        expect(stored.sizeBytes, 5);
        expect(stored.sha256, Checksums.sha256OfString('hello'));

        final reader = await storage.get('a/b/c.txt');
        expect(await readAsString(reader.stream), 'hello');
        expect(reader.length, 5);
        expect(reader.isPartial, isFalse);
      });

      test('computes the checksum while streaming, across chunks', () async {
        final stored = await storage.put(
          'chunked.bin',
          Stream.fromIterable([
            utf8.encode('one'),
            utf8.encode('two'),
            utf8.encode('three'),
          ]),
        );

        expect(stored.sizeBytes, 11);
        expect(stored.sha256, Checksums.sha256OfString('onetwothree'));
      });

      test(
        'verifies a declared checksum and stores nothing on mismatch',
        () async {
          await expectLater(
            storage.put(
              'bad.bin',
              bytesOf('actual'),
              expectedSha256: Checksums.sha256OfString('expected'),
            ),
            throwsA(isA<ChecksumMismatchException>()),
          );

          // A corrupted artifact must never become downloadable.
          expect(await storage.exists('bad.bin'), isFalse);
        },
      );

      test('verifies a declared length', () async {
        await expectLater(
          storage.put('short.bin', bytesOf('12345'), length: 99),
          throwsA(isA<ValidationException>()),
        );
        expect(await storage.exists('short.bin'), isFalse);
      });

      test('accepts a matching declared length and checksum', () async {
        final stored = await storage.put(
          'good.bin',
          bytesOf('payload'),
          length: 7,
          expectedSha256: Checksums.sha256OfString('payload'),
          contentType: 'application/gzip',
        );

        expect(stored.sizeBytes, 7);
        expect(stored.contentType, 'application/gzip');
      });

      test('serves a byte range', () async {
        await storage.put('ranged.txt', bytesOf('hello world'));

        final reader = await storage.get('ranged.txt', range: ByteRange(6, 10));
        expect(await readAsString(reader.stream), 'world');
        expect(reader.length, 5);
        expect(reader.isPartial, isTrue);
        expect(reader.range, ByteRange(6, 10));
      });

      test('serves an open-ended range', () async {
        await storage.put('ranged.txt', bytesOf('hello world'));

        final reader = await storage.get(
          'ranged.txt',
          range: ByteRange.from(6),
        );
        expect(await readAsString(reader.stream), 'world');
      });

      test('clamps a range that runs past the end', () async {
        await storage.put('ranged.txt', bytesOf('hello'));

        final reader = await storage.get('ranged.txt', range: ByteRange(3, 99));
        expect(await readAsString(reader.stream), 'lo');
      });

      test('rejects a range that starts past the end', () async {
        await storage.put('ranged.txt', bytesOf('hello'));

        await expectLater(
          storage.get('ranged.txt', range: ByteRange.from(99)),
          throwsA(isA<ValidationException>()),
        );
      });

      test('reports a missing key as not found, not an empty stream', () async {
        await expectLater(
          storage.get('nope.txt'),
          throwsA(isA<AssetNotFoundException>()),
        );
        expect(await storage.head('nope.txt'), isNull);
        expect(await storage.exists('nope.txt'), isFalse);
      });

      test('head reports size and checksum', () async {
        await storage.put('x.txt', bytesOf('hello'));

        final head = await storage.head('x.txt');
        expect(head!.sizeBytes, 5);
        expect(head.sha256, Checksums.sha256OfString('hello'));
      });

      test('replaces an existing object', () async {
        await storage.put('x.txt', bytesOf('first'));
        await storage.put('x.txt', bytesOf('second-and-longer'));

        final reader = await storage.get('x.txt');
        expect(await readAsString(reader.stream), 'second-and-longer');
      });

      test('delete is idempotent', () async {
        await storage.put('x.txt', bytesOf('data'));

        await storage.delete('x.txt');
        expect(await storage.exists('x.txt'), isFalse);
        // Deleting what is not there is a success, per the contract.
        await storage.delete('x.txt');
      });

      test('lists keys in order, filtered by prefix', () async {
        await storage.put('orgs/acme/b.txt', bytesOf('b'));
        await storage.put('orgs/acme/a.txt', bytesOf('a'));
        await storage.put('orgs/globex/c.txt', bytesOf('c'));

        expect(await storage.list(), [
          'orgs/acme/a.txt',
          'orgs/acme/b.txt',
          'orgs/globex/c.txt',
        ]);
        expect(await storage.list(prefix: 'orgs/acme/'), [
          'orgs/acme/a.txt',
          'orgs/acme/b.txt',
        ]);
        expect(await storage.list(limit: 2), [
          'orgs/acme/a.txt',
          'orgs/acme/b.txt',
        ]);
        expect(await storage.list(prefix: 'nothing/'), isEmpty);
      });

      test('rejects an unsafe key on every entry point', () async {
        await expectLater(
          storage.put('../escape', bytesOf('x')),
          throwsA(isA<ValidationException>()),
        );
        await expectLater(
          storage.get('../escape'),
          throwsA(isA<ValidationException>()),
        );
        await expectLater(
          storage.delete('/absolute'),
          throwsA(isA<ValidationException>()),
        );
      });

      test('reports usage consistently with what it holds', () async {
        final before = await storage.usedBytes();
        await storage.put('x.bin', bytesOf('0123456789'));
        final after = await storage.usedBytes();

        if (before != null && after != null) {
          expect(after, greaterThanOrEqualTo(before + 10));
        }
      });
    });
  }

  objectStorageContract(
    'MemoryObjectStorage',
    () async => MemoryObjectStorage(),
  );

  objectStorageContract(
    'LocalObjectStorage',
    () async {
      final dir = await Directory.systemTemp.createTemp('omnystore_objects_');
      return LocalObjectStorage.fromDirectory(dir);
    },
    dispose: (storage) async {
      await storage.close();
      final root = (storage as LocalObjectStorage).root;
      if (root.existsSync()) await root.delete(recursive: true);
    },
  );

  group('MemoryObjectStorage specifics', () {
    test('cannot presign, so callers stream instead', () async {
      final storage = MemoryObjectStorage();
      await storage.put('x.txt', Stream.value(utf8.encode('data')));

      expect(storage.supportsPresignedUrls, isFalse);
      expect(await storage.presignedUrl('x.txt'), isNull);
    });

    test('refuses to grow past its cap', () async {
      // Without a cap a long-lived embedded store would grow until the process
      // was killed — a silent leak that only shows up in production.
      final storage = MemoryObjectStorage(maxTotalBytes: 16);

      await storage.put('a', Stream.value(List.filled(10, 1)));
      await expectLater(
        storage.put('b', Stream.value(List.filled(10, 1))),
        throwsA(isA<StorageException>()),
      );
    });

    test('replacing an object does not double-count its bytes', () async {
      final storage = MemoryObjectStorage(maxTotalBytes: 16);

      await storage.put('a', Stream.value(List.filled(10, 1)));
      await storage.put('a', Stream.value(List.filled(12, 1)));

      expect(await storage.usedBytes(), 12);
    });

    test('a reader keeps its bytes when the key is replaced', () async {
      final storage = MemoryObjectStorage();
      await storage.put('x.txt', Stream.value(utf8.encode('original')));

      final reader = await storage.get('x.txt', range: ByteRange(0, 3));
      await storage.put('x.txt', Stream.value(utf8.encode('replaced!!!')));

      expect(await readAsString(reader.stream), 'orig');
    });
  });

  group('LocalObjectStorage specifics', () {
    test('lays artifacts out as a browsable tree', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        await storage.put(
          'orgs/acme/packages/omnyagent/1.0.0/agent.tar.gz',
          Stream.value(utf8.encode('payload')),
        );

        final file = File(
          p.join(
            dir.path,
            'orgs',
            'acme',
            'packages',
            'omnyagent',
            '1.0.0',
            'agent.tar.gz',
          ),
        );
        expect(file.existsSync(), isTrue);
        expect(file.readAsStringSync(), 'payload');
      });
    });

    test('records the checksum in a sidecar', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        await storage.put('x.txt', Stream.value(utf8.encode('data')));

        final sidecar = File(
          p.join(dir.path, 'x.txt${LocalObjectStorage.metadataSuffix}'),
        );
        expect(sidecar.existsSync(), isTrue);
        expect(
          jsonDecode(sidecar.readAsStringSync())['sha256'],
          Checksums.sha256OfString('data'),
        );
      });
    });

    test('degrades to an unknown checksum if the sidecar is corrupt', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        await storage.put('x.txt', Stream.value(utf8.encode('data')));
        File(
          p.join(dir.path, 'x.txt${LocalObjectStorage.metadataSuffix}'),
        ).writeAsStringSync('{corrupt');

        // A broken sidecar must not make a readable artifact undownloadable.
        final head = await storage.head('x.txt');
        expect(head!.sizeBytes, 4);
        expect(head.sha256, isNull);
        expect(await readAsString((await storage.get('x.txt')).stream), 'data');
      });
    });

    test('hides sidecars and partial files from listings', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        await storage.put('x.txt', Stream.value(utf8.encode('data')));
        File(
          p.join(dir.path, 'stale${LocalObjectStorage.temporarySuffix}.1'),
        ).writeAsStringSync('junk');

        expect(await storage.list(), ['x.txt']);
      });
    });

    test('leaves nothing behind when an upload fails verification', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);

        await expectLater(
          storage.put(
            'x.txt',
            Stream.value(utf8.encode('actual')),
            expectedSha256: Checksums.sha256OfString('expected'),
          ),
          throwsA(isA<ChecksumMismatchException>()),
        );

        // Neither the object nor a stray temp file.
        expect(
          dir.listSync(recursive: true).whereType<File>().toList(),
          isEmpty,
        );
      });
    });

    test('does not expose a partially written object', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        await storage.put('x.txt', Stream.value(utf8.encode('original')));

        // A failed replacement leaves the previous version intact, because the
        // rename into place only happens after the last byte verifies.
        await expectLater(
          storage.put(
            'x.txt',
            Stream.value(utf8.encode('replacement')),
            expectedSha256: Checksums.sha256OfString('something else'),
          ),
          throwsA(isA<ChecksumMismatchException>()),
        );

        expect(
          await readAsString((await storage.get('x.txt')).stream),
          'original',
        );
      });
    });

    test('sweeps stale partial files', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        final stale = File(
          p.join(dir.path, 'a${LocalObjectStorage.temporarySuffix}.1'),
        )..writeAsStringSync('junk');
        stale.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 3)),
        );

        expect(await storage.sweepIncomplete(), 1);
        expect(stale.existsSync(), isFalse);
      });
    });

    test('keeps recent partial files, which may be in flight', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        File(
          p.join(dir.path, 'a${LocalObjectStorage.temporarySuffix}.1'),
        ).writeAsStringSync('in progress');

        expect(await storage.sweepIncomplete(), 0);
      });
    });

    test('prunes empty directories after a delete', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        await storage.put(
          'orgs/acme/packages/a/1.0.0/x.txt',
          Stream.value(utf8.encode('data')),
        );

        await storage.delete('orgs/acme/packages/a/1.0.0/x.txt');

        expect(Directory(p.join(dir.path, 'orgs')).existsSync(), isFalse);
      });
    });

    test('guesses a content type from the extension', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);
        // Written directly, so there is no sidecar to read it from.
        File(p.join(dir.path, 'agent.tar.gz')).writeAsStringSync('x');

        expect(
          (await storage.head('agent.tar.gz'))!.contentType,
          'application/gzip',
        );
      });
    });

    test('refuses a key that resolves outside the root', () async {
      await withTempDir((dir) async {
        final storage = LocalObjectStorage.fromDirectory(dir);

        await expectLater(
          storage.put('../outside.txt', Stream.value(utf8.encode('x'))),
          throwsA(isA<ValidationException>()),
        );
      });
    });
  });
}
