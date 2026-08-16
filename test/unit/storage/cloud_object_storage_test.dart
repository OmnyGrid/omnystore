import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

import '../../support/fake_object_stores.dart';
import '../../support/harness.dart';
import '../../support/test_rsa_key.dart';

/// The cloud backends' own behaviour, beyond the shared `ObjectStorage`
/// contract: how they address a bucket, how they page a listing, what they do
/// with an error status, and which headers they actually put on the wire.
void main() {
  /// One generated key for the service-account token-exchange test.
  late final TestServiceAccountKey serviceAccount;
  setUpAll(() => serviceAccount = TestServiceAccountKey.generate());

  Stream<List<int>> bytesOf(String text) => Stream.value(utf8.encode(text));

  group('S3ObjectStorage', () {
    late FakeS3 fake;
    late S3ObjectStorage storage;

    S3ObjectStorage open({
      String prefix = '',
      bool usePathStyle = false,
      Uri? endpoint,
      String? storageClass,
      String? serverSideEncryption,
      int pageSize = 1000,
    }) {
      fake = FakeS3(usePathStyle: usePathStyle, pageSize: pageSize);
      return storage = S3ObjectStorage(
        bucket: 'test-bucket',
        region: 'eu-west-1',
        prefix: prefix,
        endpoint: endpoint,
        usePathStyle: usePathStyle,
        storageClass: storageClass,
        serverSideEncryption: serverSideEncryption,
        credentials: StaticAwsCredentialsProvider.of(
          accessKeyId: 'AKIAEXAMPLE',
          secretAccessKey: 'secret',
        ),
        httpClient: fake.client,
      );
    }

    tearDown(() => storage.close());

    group('addressing', () {
      test('uses virtual-host style by default', () async {
        await open().put('a/b.txt', bytesOf('x'));

        expect(
          fake.requests.single.url.host,
          'test-bucket.s3.eu-west-1.amazonaws.com',
        );
        expect(fake.requests.single.url.path, '/a/b.txt');
      });

      test('puts the bucket in the path when asked', () async {
        await open(usePathStyle: true).put('a/b.txt', bytesOf('x'));

        expect(fake.requests.single.url.host, 's3.eu-west-1.amazonaws.com');
        expect(fake.requests.single.url.path, '/test-bucket/a/b.txt');
      });

      test('honours a custom endpoint with a port', () async {
        await open(
          usePathStyle: true,
          endpoint: Uri.parse('https://minio.internal:9000'),
        ).put('a/b.txt', bytesOf('x'));

        final url = fake.requests.single.url;
        expect(url.host, 'minio.internal');
        expect(url.port, 9000);
        expect(url.path, '/test-bucket/a/b.txt');
      });

      test(
        'applies the prefix to the stored key, not the caller key',
        () async {
          final s3 = open(prefix: 'registry');
          await s3.put('a/b.txt', bytesOf('x'));

          // On the wire the object is prefixed…
          expect(fake.objects.keys, ['registry/a/b.txt']);
          // …but the caller never sees it.
          expect(await s3.list(), ['a/b.txt']);
          expect((await s3.head('a/b.txt'))!.key, 'a/b.txt');
        },
      );

      test('normalises a prefix given with stray slashes', () async {
        await open(prefix: '/registry/').put('a.txt', bytesOf('x'));

        expect(fake.objects.keys, ['registry/a.txt']);
      });
    });

    group('request shape', () {
      test('signs every request', () async {
        await open().put('a.txt', bytesOf('x'));

        final headers = fake.requests.single.headers;
        expect(headers['authorization'], startsWith('AWS4-HMAC-SHA256 '));
        expect(headers['x-amz-date'], isNotNull);
        expect(headers['x-amz-content-sha256'], isNotNull);
      });

      test('streams a known-length body without hashing it up front', () async {
        await open().put('a.txt', bytesOf('hello'), length: 5);

        // A signed streaming upload cannot hash the body in advance, and S3
        // permits UNSIGNED-PAYLOAD over HTTPS precisely for this.
        expect(
          fake.requests.single.headers['x-amz-content-sha256'],
          'UNSIGNED-PAYLOAD',
        );
      });

      test('sends the storage class and encryption when configured', () async {
        await open(
          storageClass: 'INTELLIGENT_TIERING',
          serverSideEncryption: 'aws:kms',
        ).put('a.txt', bytesOf('x'));

        final headers = fake.requests.single.headers;
        expect(headers['x-amz-storage-class'], 'INTELLIGENT_TIERING');
        expect(headers['x-amz-server-side-encryption'], 'aws:kms');
      });

      test('sends caller metadata as x-amz-meta headers', () async {
        await open().put(
          'a.txt',
          bytesOf('x'),
          metadata: {'assetName': 'agent.tar.gz', 'releaseId': 'rel-1'},
        );

        expect(fake.objects['a.txt']!.metadata['assetname'], 'agent.tar.gz');
        expect(fake.objects['a.txt']!.metadata['releaseid'], 'rel-1');
      });

      test('records the digest so head can report it', () async {
        // S3's own etag is an MD5 for single-part uploads, so the SHA-256 has
        // to travel in user metadata or it is lost entirely.
        await open().put('a.txt', bytesOf('hello'));

        expect(
          fake.objects['a.txt']!.metadata['sha256'],
          Checksums.sha256OfString('hello'),
        );
      });

      test(
        'reads back a digest another tool wrote as x-amz-checksum-sha256',
        () async {
          final s3 = open();
          await s3.put('a.txt', bytesOf('hello'));
          // Simulate an object uploaded with S3's native checksum support, which
          // is base64 rather than hex and lives under a different header.
          final digest = Checksums.sha256OfString('hello');
          final raw = [
            for (var i = 0; i < digest.length; i += 2)
              int.parse(digest.substring(i, i + 2), radix: 16),
          ];
          fake.objects['a.txt'] = FakeObject(
            bytes: fake.objects['a.txt']!.bytes,
            contentType: 'text/plain',
            metadata: const {},
            modifiedAt: DateTime.utc(2026),
          );
          // Injected as a response header by re-opening against a client that
          // adds it.
          final withNative = S3ObjectStorage(
            bucket: 'test-bucket',
            region: 'eu-west-1',
            credentials: StaticAwsCredentialsProvider.of(
              accessKeyId: 'AKIAEXAMPLE',
              secretAccessKey: 'secret',
            ),
            httpClient: MockClient(
              (request) async => http.Response(
                '',
                200,
                headers: {
                  'content-length': '5',
                  'x-amz-checksum-sha256': base64Encode(raw),
                },
              ),
            ),
          );
          addTearDown(withNative.close);

          expect((await withNative.head('a.txt'))!.sha256, digest);
        },
      );
    });

    group('listing', () {
      test('follows continuation tokens across pages', () async {
        final s3 = open(pageSize: 2);
        for (final name in ['a', 'b', 'c', 'd', 'e']) {
          await s3.put('$name.txt', bytesOf(name));
        }
        fake.requests.clear();

        expect(await s3.list(), ['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']);
        // Five keys at two per page means the paging loop really ran.
        expect(fake.requests.length, greaterThan(1));
      });

      test('stops once the caller limit is met', () async {
        final s3 = open(pageSize: 2);
        for (final name in ['a', 'b', 'c', 'd', 'e']) {
          await s3.put('$name.txt', bytesOf(name));
        }

        expect(await s3.list(limit: 3), ['a.txt', 'b.txt', 'c.txt']);
      });

      test('unescapes XML entities in keys', () async {
        final s3 = open();
        await s3.put('a&b.txt', bytesOf('x'));

        expect(await s3.list(), ['a&b.txt']);
      });
    });

    group('failures', () {
      test(
        'maps a server error to a storage failure with its message',
        () async {
          final s3 = open();
          fake.failNextWith = 500;

          await expectLater(
            s3.put('a.txt', bytesOf('x')),
            throwsA(
              isA<StorageException>()
                  .having((e) => e.message, 'message', contains('500'))
                  .having((e) => e.message, 'message', contains('injected'))
                  .having((e) => e.key, 'key', 'a.txt'),
            ),
          );
        },
      );

      test('maps a transport failure to a storage failure', () async {
        final s3 = S3ObjectStorage(
          bucket: 'test-bucket',
          region: 'eu-west-1',
          credentials: StaticAwsCredentialsProvider.of(
            accessKeyId: 'AKIAEXAMPLE',
            secretAccessKey: 'secret',
          ),
          httpClient: MockClient(
            (request) async =>
                throw http.ClientException('refused', request.url),
          ),
        );
        addTearDown(s3.close);

        await expectLater(
          s3.head('a.txt'),
          throwsA(
            isA<StorageException>().having(
              (e) => e.message,
              'message',
              contains('refused'),
            ),
          ),
        );
      });

      test('reports a listing failure', () async {
        final s3 = open();
        fake.failNextWith = 403;

        await expectLater(s3.list(), throwsA(isA<StorageException>()));
      });

      test('refuses an object above the single-part limit', () async {
        await expectLater(
          open().put(
            'huge.bin',
            const Stream.empty(),
            length: S3ObjectStorage.maxSinglePartBytes + 1,
          ),
          throwsA(
            isA<StorageException>().having(
              (e) => e.message,
              'message',
              contains('multipart'),
            ),
          ),
        );
      });

      test('removes a truncated upload whose length was overstated', () async {
        final s3 = open();

        await expectLater(
          s3.put('short.bin', bytesOf('12345'), length: 99),
          throwsA(isA<ValidationException>()),
        );
        // Leaving a truncated artifact would fail every later download.
        expect(await s3.exists('short.bin'), isFalse);
      });
    });

    test('reports unknown usage rather than walking the bucket', () async {
      // Totalling every key on each provider heartbeat would be worse than not
      // knowing; placement reads null as "has room".
      expect(await open().usedBytes(), isNull);
    });
  });

  group('GcsObjectStorage', () {
    late FakeGcs fake;
    late GcsObjectStorage storage;

    GcsObjectStorage open({
      String prefix = '',
      String? storageClass,
      int pageSize = 1000,
      GcpCredentialsProvider? credentials,
    }) {
      fake = FakeGcs(pageSize: pageSize);
      return storage = GcsObjectStorage(
        bucket: 'test-bucket',
        prefix: prefix,
        storageClass: storageClass,
        credentials: credentials ?? GcpStaticCredentials.of('ya29.test'),
        apiBase: Uri.parse('https://storage.googleapis.test/'),
        httpClient: fake.client,
      );
    }

    tearDown(() => storage.close());

    test('authorises every request with a bearer token', () async {
      await open().put('a.txt', bytesOf('x'));

      expect(fake.bearerTokens, isNotEmpty);
      expect(fake.bearerTokens.every((t) => t == 'ya29.test'), isTrue);
    });

    test('uploads through the media endpoint', () async {
      await open().put('a/b.txt', bytesOf('x'));

      final upload = fake.requests.first;
      expect(upload.method, 'POST');
      expect(upload.url.path, '/upload/storage/v1/b/test-bucket/o');
      expect(upload.url.queryParameters['uploadType'], 'media');
      expect(upload.url.queryParameters['name'], 'a/b.txt');
    });

    test('applies the prefix to the stored key, not the caller key', () async {
      final gcs = open(prefix: 'registry');
      await gcs.put('a/b.txt', bytesOf('x'));

      expect(fake.objects.keys, ['registry/a/b.txt']);
      expect(await gcs.list(), ['a/b.txt']);
      expect((await gcs.head('a/b.txt'))!.key, 'a/b.txt');
    });

    test('sends the storage class when configured', () async {
      await open(storageClass: 'COLDLINE').put('a.txt', bytesOf('x'));

      expect(
        fake.requests.first.url.queryParameters['storageClass'],
        'COLDLINE',
      );
    });

    test('patches the digest on so head can report it', () async {
      await open().put('a.txt', bytesOf('hello'));

      // GCS's crc32c and md5Hash are neither a SHA-256, so the digest is
      // attached as custom metadata in a follow-up patch.
      expect(fake.requests.map((r) => r.method), contains('PATCH'));
      expect(
        fake.objects['a.txt']!.metadata['sha256'],
        Checksums.sha256OfString('hello'),
      );
    });

    test('an upload survives a failed metadata patch', () async {
      final gcs = open();

      // The patch is best-effort: a failure costs a null checksum from head,
      // and must not fail an upload that otherwise succeeded.
      var seenUpload = false;
      final flaky = GcsObjectStorage(
        bucket: 'test-bucket',
        credentials: GcpStaticCredentials.of('ya29.test'),
        apiBase: Uri.parse('https://storage.googleapis.test/'),
        httpClient: MockClient.streaming((request, body) async {
          if (request.method == 'PATCH') {
            return http.StreamedResponse(const Stream.empty(), 500);
          }
          seenUpload = true;
          await body.drain<void>();
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"name":"a.txt","size":"1"}')),
            200,
          );
        }),
      );
      addTearDown(flaky.close);

      final stored = await flaky.put('a.txt', bytesOf('x'));
      expect(seenUpload, isTrue);
      expect(stored.sha256, Checksums.sha256OfString('x'));
      await gcs.close();
    });

    test('reads size back from the string GCS reports it as', () async {
      final gcs = open();
      await gcs.put('a.txt', bytesOf('hello'));

      expect((await gcs.head('a.txt'))!.sizeBytes, 5);
    });

    test('follows page tokens across pages', () async {
      final gcs = open(pageSize: 2);
      for (final name in ['a', 'b', 'c', 'd', 'e']) {
        await gcs.put('$name.txt', bytesOf(name));
      }
      fake.requests.clear();

      expect(await gcs.list(), ['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']);
      expect(fake.requests.length, greaterThan(1));
    });

    test('treats a delete of a missing key as success', () async {
      final gcs = open();

      // The idempotent-delete contract: GCS answers 404, which is not an error.
      await gcs.delete('never-existed.txt');
    });

    test('maps a server error to a storage failure with its message', () async {
      final gcs = open();
      fake.failNextWith = 503;

      await expectLater(
        gcs.put('a.txt', bytesOf('x')),
        throwsA(
          isA<StorageException>()
              .having((e) => e.message, 'message', contains('503'))
              .having((e) => e.message, 'message', contains('injected')),
        ),
      );
    });

    test('maps a transport failure to a storage failure', () async {
      final gcs = GcsObjectStorage(
        bucket: 'test-bucket',
        credentials: GcpStaticCredentials.of('ya29.test'),
        apiBase: Uri.parse('https://storage.googleapis.test/'),
        httpClient: MockClient(
          (request) async => throw http.ClientException('refused', request.url),
        ),
      );
      addTearDown(gcs.close);

      await expectLater(gcs.head('a.txt'), throwsA(isA<StorageException>()));
    });

    test('removes a truncated upload whose length was overstated', () async {
      final gcs = open();

      await expectLater(
        gcs.put('short.bin', bytesOf('12345'), length: 99),
        throwsA(isA<ValidationException>()),
      );
      expect(await gcs.exists('short.bin'), isFalse);
    });

    test('reports unknown usage', () async {
      expect(await open().usedBytes(), isNull);
    });

    test('exchanges a service-account assertion for a token, once', () async {
      // Built explicitly rather than through `open`, so the credentials and
      // the storage share one endpoint — `open` assigns `fake` as a side
      // effect, and an argument referring to it would capture the previous
      // test's instance.
      final endpoint = FakeGcs();
      storage = GcsObjectStorage(
        bucket: 'test-bucket',
        credentials: GcpServiceAccountCredentials(
          clientEmail: serviceAccount.clientEmail,
          privateKey: serviceAccount.privateKey,
          tokenUri: Uri.parse('https://storage.googleapis.test/token'),
          httpClient: endpoint.client,
        ),
        apiBase: Uri.parse('https://storage.googleapis.test/'),
        httpClient: endpoint.client,
      );

      await storage.put('a.txt', bytesOf('x'));
      await storage.put('b.txt', bytesOf('y'));

      expect(endpoint.bearerTokens, isNotEmpty);
      expect(endpoint.bearerTokens.every((t) => t == 'ya29.fake'), isTrue);
      // Cached: one exchange, not one per request.
      expect(endpoint.requests.where((r) => r.url.path == '/token').length, 1);
    });
  });

  group('an OmnyStore over a cloud backend', () {
    test('runs a full release lifecycle against S3', () async {
      final fake = FakeS3();
      final store = OmnyStore(
        repositories: MemoryRepositories(),
        storage: S3ObjectStorage(
          bucket: 'test-bucket',
          region: 'eu-west-1',
          credentials: StaticAwsCredentialsProvider.of(
            accessKeyId: 'AKIAEXAMPLE',
            secretAccessKey: 'secret',
          ),
          httpClient: fake.client,
        ),
      );
      addTearDown(store.close);

      final organization = await store.createOrganization(name: 'acme');
      final project = await store.createProject(
        organizationId: organization.id,
        name: 'agent',
      );
      final package = await store.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await store.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );
      final asset = await store.attachAsset(
        releaseId: release.id,
        name: 'agent.tar.gz',
        data: bytesOf('the artifact'),
        platform: 'linux-x64',
      );

      expect(fake.objects.keys, [
        'orgs/acme/packages/omnyagent/1.0.0/agent.tar.gz',
      ]);
      expect(asset.sha256, Checksums.sha256OfString('the artifact'));
      expect(
        await readAsString((await store.openAsset(asset.id)).stream),
        'the artifact',
      );

      // A presigned redirect, so no artifact byte crosses the registry.
      final target = await store.downloadTarget(asset.id);
      expect(target, isA<RedirectDownload>());
      expect(
        (target as RedirectDownload).url.queryParameters['X-Amz-Signature'],
        isNotEmpty,
      );

      await store.deleteAsset(asset.id);
      expect(fake.objects, isEmpty);
    });

    test('streams a download through the hub when GCS cannot presign', () async {
      final fake = FakeGcs();
      final store = OmnyStore(
        repositories: MemoryRepositories(),
        storage: GcsObjectStorage(
          bucket: 'test-bucket',
          // Ambient credentials hold no private key, so URLs cannot be signed.
          credentials: GcpMetadataServerCredentials(httpClient: fake.client),
          apiBase: Uri.parse('https://storage.googleapis.test/'),
          httpClient: fake.client,
        ),
      );
      addTearDown(store.close);

      final organization = await store.createOrganization(name: 'acme');
      final project = await store.createProject(
        organizationId: organization.id,
        name: 'agent',
      );
      final package = await store.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await store.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );
      final asset = await store.attachAsset(
        releaseId: release.id,
        name: 'agent.tar.gz',
        data: bytesOf('payload'),
      );

      final target = await store.downloadTarget(asset.id);
      expect(target, isA<StreamedDownload>());
      expect(
        await readAsString((await store.openAsset(asset.id)).stream),
        'payload',
      );
    });
  });
}
