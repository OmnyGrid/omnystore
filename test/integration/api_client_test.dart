@Tags(['server'])
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnystore/omnystore_client.dart';
import 'package:omnystore/omnystore_hub.dart' hide Version;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Exercises the REST server over a real loopback socket, driven by the real
/// client SDK.
///
/// Nothing is mocked: OmnyHub binds a port, the client opens TCP connections to
/// it, and artifact bytes cross the wire. That is the only way to catch the
/// failures that live in the seams — a route that shadows another, a header
/// that never gets set, a stream that is buffered when it should not be.
void main() {
  late TestStore backing;
  late OmnyStoreServer server;
  late OmnyStoreClient client;

  setUp(() async {
    backing = TestStore();
    server = OmnyStoreServer(store: backing.store, allowAnyOrigin: true);
    await server.start(port: 0, address: '127.0.0.1');
    client = OmnyStoreClient(baseUrl: 'http://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await client.close();
    await server.stop();
    await backing.close();
  });

  /// Creates `acme` / `agent` / `omnyagent` through the API.
  Future<Package> seed() async {
    final org = await client.createOrganization(
      name: 'acme',
      displayName: 'Acme Corporation',
    );
    final project = await client.createProject(
      organizationId: org.id,
      name: 'agent',
    );
    return client.createPackage(
      projectId: project.id,
      name: 'omnyagent',
      platforms: ['linux-x64', 'macos-arm64'],
    );
  }

  group('health', () {
    test('reports the version and provider count', () async {
      final health = await client.health();

      expect(health['status'], 'ok');
      expect(health['version'], omnyStoreVersion);
      expect(health['api'], omnyStoreApiVersion);
      expect(health['providers'], 1);
    });
  });

  group('resource lifecycle', () {
    test('creates, reads, updates and deletes an organization', () async {
      final created = await client.createOrganization(
        name: 'acme',
        description: 'Acme Corp',
      );
      expect(created.name, 'acme');

      expect(await client.organization(created.id), created);
      expect(
        await client.organizationByName('acme'),
        created,
        reason: 'the id route resolves a name too',
      );
      expect((await client.listOrganizations()).single, created);

      final updated = await client.updateOrganization(
        created.id,
        displayName: 'Acme Corporation',
      );
      expect(updated.displayName, 'Acme Corporation');

      await client.deleteOrganization(created.id);
      expect(await client.listOrganizations(), isEmpty);
    });

    test('returns null rather than throwing for a missing resource', () async {
      expect(await client.organization('nope'), isNull);
      expect(await client.release('nope'), isNull);
      expect(await client.asset('nope'), isNull);
    });

    test('walks the organization → project → package hierarchy', () async {
      final package = await seed();

      final projects = await client.listProjects(
        organizationId: package.organizationId,
      );
      expect(projects.single.name, 'agent');

      final packages = await client.listPackages(projectId: package.projectId);
      expect(packages.single.name, 'omnyagent');
      expect(packages.single.platforms, ['linux-x64', 'macos-arm64']);
    });
  });

  group('releases over the API', () {
    setUp(() => seed());

    test('publishes and lists newest-first', () async {
      await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.0.0'),
      );
      await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.1.0-beta.1'),
      );
      await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.2.0'),
      );

      final releases = await client.listReleases('omnyagent');
      expect(releases.map((r) => '${r.version}'), [
        '1.2.0',
        '1.1.0-beta.1',
        '1.0.0',
      ]);
    });

    test('serves latest per channel', () async {
      await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.0.0'),
      );
      await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.1.0-beta.1'),
      );

      expect(
        (await client.latestRelease('omnyagent'))!.version.toString(),
        '1.0.0',
      );
      expect(
        (await client.latestBeta('omnyagent'))!.version.toString(),
        '1.1.0-beta.1',
      );
      expect(
        (await client.latestAny('omnyagent'))!.version.toString(),
        '1.1.0-beta.1',
      );
    });

    test('the latest route is not shadowed by the version route', () async {
      await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.0.0'),
      );

      // `/releases/latest` and `/releases/<version>` both match the same shape;
      // the literal must win, or "latest" would be parsed as a version.
      final byVersion = await client.releaseByVersion(
        'omnyagent',
        Version.parse('1.0.0'),
      );
      final latest = await client.latestRelease('omnyagent');

      expect(byVersion!.id, latest!.id);
    });

    test(
      'fetches a release by exact version, build metadata included',
      () async {
        await client.publishRelease(
          packageReference: 'omnyagent',
          version: Version.parse('2.0.0+build5'),
        );

        final release = await client.releaseByVersion(
          'omnyagent',
          Version.parse('2.0.0+build5'),
        );
        expect(release!.version.build, ['build5']);
        expect(release.channel, ReleaseChannel.release);
      },
    );

    test('yanks and promotes', () async {
      final beta = await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.2.0-beta.1'),
      );

      final promoted = await client.promoteRelease(
        beta.id,
        ReleaseChannel.release,
      );
      expect(promoted.version.toString(), '1.2.0');

      await client.updateRelease(
        promoted.id,
        yanked: true,
        yankedReason: 'bad build',
      );
      expect(await client.latestRelease('omnyagent'), isNull);
    });
  });

  group('assets over the API', () {
    late Release release;

    setUp(() async {
      await seed();
      release = await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.0.0'),
      );
    });

    test('uploads, verifies and downloads', () async {
      const payload = 'the artifact bytes';

      final asset = await client.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-linux-x64.tar.gz',
        data: Stream.value(utf8.encode(payload)),
        length: payload.length,
        contentType: 'application/gzip',
        platform: 'linux-x64',
      );

      expect(asset.sizeBytes, payload.length);
      expect(asset.sha256, Checksums.sha256OfString(payload));

      final bytes = await client.downloadAsset(asset.id);
      expect(utf8.decode(bytes), payload);
    });

    test('rejects an upload whose declared checksum does not match', () async {
      await expectLater(
        client.attachAsset(
          releaseId: release.id,
          name: 'agent.tar.gz',
          data: Stream.value(utf8.encode('actual')),
          expectedSha256: Checksums.sha256OfString('expected'),
        ),
        throwsA(
          isA<ChecksumMismatchException>()
              .having((e) => e.expected, 'expected', isNotEmpty)
              .having((e) => e.actual, 'actual', isNotEmpty),
        ),
      );

      expect(await client.listAssets(release.id), isEmpty);
    });

    test('serves a byte range as 206 with content-range', () async {
      const payload = 'hello world';
      final asset = await client.attachAsset(
        releaseId: release.id,
        name: 'agent.txt',
        data: Stream.value(utf8.encode(payload)),
      );

      final response = await http.get(
        Uri.parse(
          'http://127.0.0.1:${server.port}'
          '/api/$omnyStoreApiVersion/assets/${asset.id}/download',
        ),
        headers: {'range': 'bytes=6-10'},
      );

      expect(response.statusCode, 206);
      expect(response.body, 'world');
      expect(response.headers['content-range'], 'bytes 6-10/11');
      expect(response.headers['accept-ranges'], 'bytes');
    });

    test('advertises the checksum and a filename on download', () async {
      const payload = 'artifact';
      final asset = await client.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-linux-x64.tar.gz',
        data: Stream.value(utf8.encode(payload)),
      );

      final response = await http.get(
        Uri.parse(
          'http://127.0.0.1:${server.port}'
          '/api/$omnyStoreApiVersion/assets/${asset.id}/download',
        ),
      );

      expect(response.statusCode, 200);
      expect(
        response.headers['x-omnystore-sha256'],
        Checksums.sha256OfString(payload),
      );
      expect(
        response.headers['content-disposition'],
        'attachment; filename="omnyagent-linux-x64.tar.gz"',
      );
    });

    test('records the download and increments the counter', () async {
      final asset = await client.attachAsset(
        releaseId: release.id,
        name: 'agent.txt',
        data: Stream.value(utf8.encode('data')),
      );

      await client.downloadAsset(asset.id);

      expect((await client.asset(asset.id))!.downloadCount, 1);
      final stats = await client.downloadStats('omnyagent');
      expect(stats.total, 1);
      expect(stats.byVersion['1.0.0'], 1);
    });

    test('deletes an asset', () async {
      final asset = await client.attachAsset(
        releaseId: release.id,
        name: 'agent.txt',
        data: Stream.value(utf8.encode('data')),
      );

      await client.deleteAsset(asset.id);

      expect(await client.listAssets(release.id), isEmpty);
      expect(await client.asset(asset.id), isNull);
    });
  });

  group('update checks over the API', () {
    setUp(() async {
      await seed();
      final v1 = await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.0.0'),
      );
      await client.attachAsset(
        releaseId: v1.id,
        name: 'omnyagent-linux-x64.tar.gz',
        data: Stream.value(utf8.encode('v1')),
        platform: 'linux-x64',
      );
    });

    test('offers a newer release with the matching platform asset', () async {
      final v2 = await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.1.0'),
        notes: 'Fixes a crash on startup.',
      );
      await client.attachAsset(
        releaseId: v2.id,
        name: 'omnyagent-linux-x64.tar.gz',
        data: Stream.value(utf8.encode('v2')),
        platform: 'linux-x64',
      );
      await client.attachAsset(
        releaseId: v2.id,
        name: 'omnyagent-macos-arm64.tar.gz',
        data: Stream.value(utf8.encode('v2-mac')),
        platform: 'macos-arm64',
      );

      final info = await client.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'macos-arm64',
      );

      expect(info.updateAvailable, isTrue);
      expect(info.latestVersion.toString(), '1.1.0');
      expect(info.asset!.name, 'omnyagent-macos-arm64.tar.gz');
      expect(info.notes, 'Fixes a crash on startup.');
    });

    test('reports current when there is nothing newer', () async {
      final info = await client.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
      );

      expect(info.updateAvailable, isFalse);
    });

    test('rejects a check with no current version', () async {
      final response = await http.get(
        Uri.parse(
          'http://127.0.0.1:${server.port}'
          '/api/$omnyStoreApiVersion/packages/omnyagent/updates',
        ),
      );

      expect(response.statusCode, 400);
      final error = jsonDecode(response.body)['error'];
      expect(error['code'], ErrorCodes.validationError);
    });

    test('drives an UpdateChecker end to end', () async {
      await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('2.0.0-beta.1'),
      );

      final checker = UpdateChecker.forVersion(
        store: client,
        packageReference: 'omnyagent',
        currentVersion: '1.0.0',
        channel: ReleaseChannel.beta,
      );

      expect(await checker.hasUpdate(), isTrue);
      expect((await checker.latestVersion()).toString(), '2.0.0-beta.1');
    });
  });

  group('errors keep their type across the wire', () {
    test('a missing package raises PackageNotFoundException', () async {
      await expectLater(
        client.resolvePackage('ghost'),
        throwsA(
          isA<PackageNotFoundException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.packageNotFound,
          ),
        ),
      );
    });

    test('a duplicate name raises ConflictException', () async {
      await client.createOrganization(name: 'acme');

      await expectLater(
        client.createOrganization(name: 'acme'),
        throwsA(
          isA<ConflictException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
    });

    test('an invalid name raises ValidationException', () async {
      await expectLater(
        client.createOrganization(name: 'Acme Corp!'),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'an unreachable server raises ApiException, not a raw socket error',
      () async {
        final offline = OmnyStoreClient(
          baseUrl: 'http://127.0.0.1:1',
          timeout: const Duration(seconds: 2),
        );
        addTearDown(offline.close);

        await expectLater(
          offline.listOrganizations(),
          throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 503),
          ),
        );
      },
    );
  });

  group('CORS', () {
    test('answers a preflight and stamps the allow-origin header', () async {
      final request =
          http.Request(
              'OPTIONS',
              Uri.parse(
                'http://127.0.0.1:${server.port}'
                '/api/$omnyStoreApiVersion/organizations',
              ),
            )
            ..headers.addAll({
              'origin': 'https://releases.example.com',
              'access-control-request-method': 'POST',
            });

      final response = await http.Response.fromStream(
        await http.Client().send(request),
      );

      expect(response.statusCode, 204);
      expect(response.headers['access-control-allow-origin'], isNotNull);
    });

    test('exposes the checksum header to browser JavaScript', () async {
      await seed();
      final release = await client.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.0.0'),
      );
      final asset = await client.attachAsset(
        releaseId: release.id,
        name: 'agent.txt',
        data: Stream.value(utf8.encode('data')),
      );

      final response = await http.get(
        Uri.parse(
          'http://127.0.0.1:${server.port}'
          '/api/$omnyStoreApiVersion/assets/${asset.id}/download',
        ),
        headers: {'origin': 'https://releases.example.com'},
      );

      // Without this the header is present on the wire but invisible to JS,
      // so a browser downloader could not verify what it fetched.
      expect(
        response.headers['access-control-expose-headers'],
        contains('x-omnystore-sha256'),
      );
    });
  });

  group('write authentication', () {
    test('blocks writes and allows reads when configured', () async {
      final guarded = TestStore();
      final secured = OmnyStoreServer(
        store: guarded.store,
        requireAuthForWrites: true,
        writeAuthenticator: BearerTokenAuthenticator({
          'publish-token': Principal(id: 'ci', roles: const {'publisher'}),
        }),
      );
      await secured.start(port: 0, address: '127.0.0.1');
      addTearDown(() async {
        await secured.stop();
        await guarded.close();
      });

      final anonymous = OmnyStoreClient(
        baseUrl: 'http://127.0.0.1:${secured.port}',
      );
      final publisher = OmnyStoreClient(
        baseUrl: 'http://127.0.0.1:${secured.port}',
        auth: const TokenAuthProvider('publish-token'),
      );
      addTearDown(() async {
        await anonymous.close();
        await publisher.close();
      });

      // Reads stay open: a registry nobody can read cannot serve downloads.
      expect(await anonymous.listOrganizations(), isEmpty);

      await expectLater(
        anonymous.createOrganization(name: 'acme'),
        throwsA(isA<UnauthorizedException>()),
      );

      final created = await publisher.createOrganization(name: 'acme');
      expect(created.name, 'acme');
    });
  });
}
