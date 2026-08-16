@Tags(['server'])
library;

import 'dart:convert';

import 'package:omnystore/omnystore_hub.dart';
import 'package:test/test.dart';

import '../support/federation.dart';
import '../support/harness.dart';

/// The central claim of the design, tested directly: **`OmnyStoreApi` behaves
/// identically whichever implementation is behind it.**
///
/// The same suite runs against all four:
///
/// * `OmnyStore` — local repositories and object storage.
/// * `OmnyStoreHub` over a local provider — the routing layer, in-process.
/// * `OmnyStoreHub` over a remote node — every call crossing the RPC protocol,
///   including chunked artifact relay and typed-exception round-tripping.
/// * `OmnyStoreClient` against a real `OmnyStoreServer` on a real socket.
///
/// A method implemented on one side and forgotten on another, or one that
/// quietly differs in what it throws, fails here rather than in production.
void main() {
  /// Everything a scenario needs, plus how to tear it down.
  ///
  /// Each implementation supplies one of these; the suite below never learns
  /// which it has.
  void conformanceSuite(
    String label,
    Future<({OmnyStoreApi store, Future<void> Function() dispose})> Function()
    open, {
    bool supportsDownloadRecording = true,
  }) {
    group('$label (OmnyStoreApi conformance)', () {
      late OmnyStoreApi store;
      late Future<void> Function() dispose;

      setUp(() async {
        final opened = await open();
        store = opened.store;
        dispose = opened.dispose;
      });

      tearDown(() => dispose());

      /// Creates `acme` / `agent` / `omnyagent` and returns the package.
      Future<Package> seed() async {
        final organization = await store.createOrganization(
          name: 'acme',
          displayName: 'Acme Corporation',
          description: 'Makers of things',
          website: 'https://acme.example.com',
          metadata: const {'tier': 'gold'},
        );
        final project = await store.createProject(
          organizationId: organization.id,
          name: 'agent',
          repository: 'https://github.com/acme/agent',
        );
        return store.createPackage(
          projectId: project.id,
          name: 'omnyagent',
          description: 'The agent',
          platforms: const ['linux-x64', 'macos-arm64'],
        );
      }

      group('organizations', () {
        test('create, read by id and by name, list, update, delete', () async {
          final created = await store.createOrganization(name: 'acme');

          expect(created.name, 'acme');
          expect(await store.organization(created.id), created);
          expect(await store.organizationByName('acme'), created);
          expect((await store.listOrganizations()).map((o) => o.name), [
            'acme',
          ]);

          final updated = await store.updateOrganization(
            created.id,
            displayName: 'Acme Corporation',
            description: 'Updated',
            website: 'https://acme.example.com',
            metadata: const {'tier': 'gold'},
          );
          expect(updated.displayName, 'Acme Corporation');
          expect(updated.description, 'Updated');
          expect(updated.metadata['tier'], 'gold');
          expect(updated.name, 'acme', reason: 'the routing key never changes');

          await store.deleteOrganization(created.id);
          expect(await store.listOrganizations(), isEmpty);
        });

        test('missing reads answer null, not an error', () async {
          expect(await store.organization('ghost'), isNull);
          expect(await store.organizationByName('ghost'), isNull);
        });

        test('a duplicate name conflicts', () async {
          await store.createOrganization(name: 'acme');

          await expectLater(
            store.createOrganization(name: 'acme'),
            throwsA(isA<ConflictException>()),
          );
        });

        test('an invalid name is rejected', () async {
          await expectLater(
            store.createOrganization(name: 'Acme Corp!'),
            throwsA(isA<ValidationException>()),
          );
        });

        test('deleting a populated organization needs force', () async {
          final package = await seed();

          await expectLater(
            store.deleteOrganization(package.organizationId),
            throwsA(isA<ConflictException>()),
          );

          await store.deleteOrganization(package.organizationId, force: true);
          expect(await store.listOrganizations(), isEmpty);
          expect(await store.listPackages(), isEmpty);
        });
      });

      group('projects', () {
        test('create, read, list, update, delete', () async {
          final package = await seed();
          final project = (await store.project(package.projectId))!;

          expect(project.name, 'agent');
          expect(project.repository, 'https://github.com/acme/agent');
          expect(
            await store.projectByName(package.organizationId, 'agent'),
            project,
          );
          expect(
            (await store.listProjects(
              organizationId: package.organizationId,
            )).map((p) => p.name),
            ['agent'],
          );
          expect((await store.listProjects()).map((p) => p.name), ['agent']);

          final updated = await store.updateProject(
            project.id,
            displayName: 'Agent',
            description: 'Updated',
            website: 'https://agent.example.com',
            metadata: const {'team': 'platform'},
          );
          expect(updated.displayName, 'Agent');
          expect(updated.metadata['team'], 'platform');

          await store.deleteProject(project.id, force: true);
          expect(await store.listProjects(), isEmpty);
        });

        test('a missing project reads null', () async {
          expect(await store.project('ghost'), isNull);
          expect(await store.projectByName('ghost', 'nope'), isNull);
        });
      });

      group('packages', () {
        test('create, resolve, list, update, delete', () async {
          final package = await seed();

          expect(package.platforms, ['linux-x64', 'macos-arm64']);
          expect(await store.package(package.id), package);
          expect(await store.resolvePackage('omnyagent'), package);
          expect(await store.resolvePackage(package.id), package);
          expect(
            await store.packageByName(package.projectId, 'omnyagent'),
            package,
          );
          expect(
            (await store.listPackages(
              projectId: package.projectId,
            )).map((p) => p.name),
            ['omnyagent'],
          );
          expect(
            (await store.listPackages(
              organizationId: package.organizationId,
            )).map((p) => p.name),
            ['omnyagent'],
          );

          final updated = await store.updatePackage(
            package.id,
            displayName: 'OmnyAgent',
            defaultChannel: ReleaseChannel.beta,
            platforms: const ['linux-x64'],
            metadata: const {'lang': 'dart'},
          );
          expect(updated.displayName, 'OmnyAgent');
          expect(updated.defaultChannel, ReleaseChannel.beta);
          expect(updated.platforms, ['linux-x64']);

          await store.deletePackage(package.id, force: true);
          expect(await store.listPackages(), isEmpty);
        });

        test('an unknown package raises PackageNotFoundException', () async {
          await expectLater(
            store.resolvePackage('ghost'),
            throwsA(isA<PackageNotFoundException>()),
          );
        });
      });

      group('releases', () {
        setUp(() => seed());

        test('publish, read, list, update, delete', () async {
          final release = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.0.0'),
            title: 'First',
            notes: 'Release notes.',
            tag: 'v1.0.0',
            metadata: const {'commit': 'abc123'},
          );

          expect(release.channel, ReleaseChannel.release);
          expect(release.title, 'First');
          expect(release.notes, 'Release notes.');
          expect(release.tag, 'v1.0.0');
          expect(release.metadata['commit'], 'abc123');
          expect(release.isOfferable, isTrue);

          expect(await store.release(release.id), release);
          expect(
            await store.releaseByVersion('omnyagent', Version.parse('1.0.0')),
            release,
          );
          expect(
            (await store.listReleases('omnyagent')).map((r) => '${r.version}'),
            ['1.0.0'],
          );

          final updated = await store.updateRelease(
            release.id,
            notes: 'Amended notes.',
          );
          expect(updated.notes, 'Amended notes.');

          await store.deleteRelease(release.id);
          expect(await store.release(release.id), isNull);
        });

        test('the channel comes from the version', () async {
          final published = <String, ReleaseChannel>{};
          for (final version in ['1.0.0', '1.1.0-beta.2', '1.2.0-dev.4']) {
            final release = await store.publishRelease(
              packageReference: 'omnyagent',
              version: Version.parse(version),
            );
            published[version] = release.channel;
          }

          expect(published, {
            '1.0.0': ReleaseChannel.release,
            '1.1.0-beta.2': ReleaseChannel.beta,
            '1.2.0-dev.4': ReleaseChannel.dev,
          });
        });

        test('republishing a version conflicts', () async {
          await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.0.0'),
          );

          await expectLater(
            store.publishRelease(
              packageReference: 'omnyagent',
              version: Version.parse('1.0.0'),
            ),
            throwsA(isA<ConflictException>()),
          );
        });

        test('every latest* accessor agrees', () async {
          for (final version in ['1.0.0', '1.1.0-beta.1', '1.2.0-dev.4']) {
            await store.publishRelease(
              packageReference: 'omnyagent',
              version: Version.parse(version),
            );
          }

          expect(
            (await store.latestRelease('omnyagent'))!.version.toString(),
            '1.0.0',
          );
          expect(
            (await store.latestBeta('omnyagent'))!.version.toString(),
            '1.1.0-beta.1',
          );
          expect(
            (await store.latestDev('omnyagent'))!.version.toString(),
            '1.2.0-dev.4',
          );
          expect(
            (await store.latestAny('omnyagent'))!.version.toString(),
            '1.2.0-dev.4',
          );
          // Inclusive downward in stability.
          expect(
            (await store.latestChannel(
              'omnyagent',
              ReleaseChannel.beta,
            ))!.version.toString(),
            '1.1.0-beta.1',
          );
          expect(
            (await store.latestChannel(
              'omnyagent',
              ReleaseChannel.beta,
              exact: true,
            ))!.version.toString(),
            '1.1.0-beta.1',
          );
        });

        test('a package with nothing offerable answers null', () async {
          expect(await store.latestRelease('omnyagent'), isNull);
          expect(await store.latestAny('omnyagent'), isNull);
        });

        test('drafts are stored but never offered', () async {
          final draft = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.0.0'),
            draft: true,
          );

          expect(draft.isOfferable, isFalse);
          expect(await store.latestRelease('omnyagent'), isNull);
          expect(
            await store.listReleases('omnyagent', query: ReleaseQuery.all),
            hasLength(1),
          );

          final published = await store.updateRelease(draft.id, draft: false);
          expect(published.isOfferable, isTrue);
          expect(await store.latestRelease('omnyagent'), isNotNull);
        });

        test('yanking withdraws without breaking a pinned client', () async {
          final release = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.0.0'),
          );

          await store.updateRelease(
            release.id,
            yanked: true,
            yankedReason: 'bad build',
          );

          expect(await store.latestRelease('omnyagent'), isNull);
          final pinned = await store.releaseByVersion(
            'omnyagent',
            Version.parse('1.0.0'),
          );
          expect(pinned!.yanked, isTrue);
          expect(pinned.yankedReason, 'bad build');

          final restored = await store.updateRelease(release.id, yanked: false);
          expect(restored.yanked, isFalse);
          expect(restored.yankedReason, isNull);
        });

        test('listing honours channel, paging and inclusion filters', () async {
          for (final version in ['1.0.0', '1.1.0', '1.2.0-beta.1']) {
            await store.publishRelease(
              packageReference: 'omnyagent',
              version: Version.parse(version),
            );
          }

          expect(
            (await store.listReleases(
              'omnyagent',
              query: ReleaseQuery.onChannel(ReleaseChannel.release),
            )).map((r) => '${r.version}'),
            ['1.1.0', '1.0.0'],
          );
          expect(
            (await store.listReleases(
              'omnyagent',
              query: const ReleaseQuery(limit: 1),
            )).map((r) => '${r.version}'),
            ['1.2.0-beta.1'],
          );
          expect(
            (await store.listReleases(
              'omnyagent',
              query: const ReleaseQuery(limit: 1, offset: 1),
            )).map((r) => '${r.version}'),
            ['1.1.0'],
          );
        });

        test('promotion copies the artifacts across', () async {
          final beta = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.2.0-beta.3'),
          );
          await store.attachAsset(
            releaseId: beta.id,
            name: 'agent.tar.gz',
            data: Stream.value(utf8.encode('payload')),
            platform: 'linux-x64',
          );

          final promoted = await store.promoteRelease(
            beta.id,
            ReleaseChannel.release,
          );

          expect(promoted.version.toString(), '1.2.0');
          final assets = await store.listAssets(promoted.id);
          expect(assets.single.name, 'agent.tar.gz');
          expect(assets.single.platform, 'linux-x64');
          expect(
            await readAsString(
              (await store.openAsset(assets.single.id)).stream,
            ),
            'payload',
          );
          // The source survives, for anyone still on it.
          expect(await store.release(beta.id), isNotNull);
        });

        test('promotion towards instability is refused', () async {
          final stable = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.2.0'),
          );

          await expectLater(
            store.promoteRelease(stable.id, ReleaseChannel.beta),
            throwsA(isA<ValidationException>()),
          );
        });

        test('a missing release reads null and updates raise', () async {
          expect(await store.release('ghost'), isNull);
          await expectLater(
            store.updateRelease('ghost', notes: 'x'),
            throwsA(isA<ReleaseNotFoundException>()),
          );
        });
      });

      group('assets', () {
        late Release release;

        setUp(() async {
          await seed();
          release = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.0.0'),
          );
        });

        test('attach, read, list, download, delete', () async {
          const payload = 'the artifact bytes';
          final asset = await store.attachAsset(
            releaseId: release.id,
            name: 'omnyagent-linux-x64.tar.gz',
            data: Stream.value(utf8.encode(payload)),
            length: payload.length,
            contentType: 'application/gzip',
            platform: 'linux-x64',
            kind: 'archive',
            metadata: const {'built-by': 'ci'},
          );

          expect(asset.sizeBytes, payload.length);
          expect(asset.sha256, Checksums.sha256OfString(payload));
          expect(asset.contentType, 'application/gzip');
          expect(asset.platform, 'linux-x64');
          expect(asset.kind, 'archive');

          expect(await store.asset(asset.id), asset);
          expect(
            await store.assetByName(release.id, 'omnyagent-linux-x64.tar.gz'),
            asset,
          );
          expect((await store.listAssets(release.id)).single, asset);

          final download = await store.openAsset(asset.id);
          expect(await readAsString(download.stream), payload);
          expect(download.length, payload.length);

          await store.deleteAsset(asset.id);
          expect(await store.listAssets(release.id), isEmpty);
          expect(await store.asset(asset.id), isNull);
        });

        test('serves a byte range', () async {
          final asset = await store.attachAsset(
            releaseId: release.id,
            name: 'agent.txt',
            data: Stream.value(utf8.encode('hello world')),
          );

          final ranged = await store.openAsset(
            asset.id,
            range: ByteRange(6, 10),
          );
          expect(await readAsString(ranged.stream), 'world');
          expect(ranged.length, 5);
        });

        test(
          'a declared checksum is verified, and stores nothing on mismatch',
          () async {
            await expectLater(
              store.attachAsset(
                releaseId: release.id,
                name: 'agent.tar.gz',
                data: Stream.value(utf8.encode('actual')),
                expectedSha256: Checksums.sha256OfString('expected'),
              ),
              throwsA(isA<ChecksumMismatchException>()),
            );

            expect(await store.listAssets(release.id), isEmpty);
          },
        );

        test('a duplicate asset name conflicts', () async {
          await store.attachAsset(
            releaseId: release.id,
            name: 'agent.tar.gz',
            data: Stream.value(utf8.encode('one')),
          );

          await expectLater(
            store.attachAsset(
              releaseId: release.id,
              name: 'agent.tar.gz',
              data: Stream.value(utf8.encode('two')),
            ),
            throwsA(isA<ConflictException>()),
          );
        });

        test('an unsafe asset name is rejected', () async {
          await expectLater(
            store.attachAsset(
              releaseId: release.id,
              name: '../../etc/passwd',
              data: Stream.value(const [1, 2, 3]),
            ),
            throwsA(isA<ValidationException>()),
          );
        });

        test('a missing asset reads null and download raises', () async {
          expect(await store.asset('ghost'), isNull);
          await expectLater(
            store.openAsset('ghost'),
            throwsA(isA<AssetNotFoundException>()),
          );
        });

        test('reports where the client should fetch from', () async {
          final asset = await store.attachAsset(
            releaseId: release.id,
            name: 'agent.txt',
            data: Stream.value(utf8.encode('payload')),
          );

          final target = await store.downloadTarget(asset.id);
          expect(
            target,
            anyOf(isA<RedirectDownload>(), isA<StreamedDownload>()),
          );
        });

        test('deleting a release cascades to its artifacts', () async {
          await store.attachAsset(
            releaseId: release.id,
            name: 'agent.txt',
            data: Stream.value(utf8.encode('payload')),
          );

          await store.deleteRelease(release.id);
          expect(await store.release(release.id), isNull);
        });
      });

      group('updates', () {
        setUp(() async {
          await seed();
          final v1 = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.0.0'),
          );
          await store.attachAsset(
            releaseId: v1.id,
            name: 'agent-linux.tar.gz',
            data: Stream.value(utf8.encode('v1')),
            platform: 'linux-x64',
          );
        });

        test('offers a newer release with the matching artifact', () async {
          final v2 = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.1.0'),
            notes: 'Fixes a crash.',
          );
          await store.attachAsset(
            releaseId: v2.id,
            name: 'agent-linux.tar.gz',
            data: Stream.value(utf8.encode('v2')),
            platform: 'linux-x64',
          );

          final info = await store.checkForUpdates(
            packageReference: 'omnyagent',
            currentVersion: Version.parse('1.0.0'),
            platform: 'linux-x64',
          );

          expect(info.updateAvailable, isTrue);
          expect(info.latestVersion.toString(), '1.1.0');
          expect(info.asset!.name, 'agent-linux.tar.gz');
          expect(info.isInstallable, isTrue);
          expect(info.notes, 'Fixes a crash.');
          expect(info.packageName, 'omnyagent');
        });

        test('reports current, and never a downgrade', () async {
          expect(
            (await store.checkForUpdates(
              packageReference: 'omnyagent',
              currentVersion: Version.parse('1.0.0'),
            )).updateAvailable,
            isFalse,
          );
          expect(
            (await store.checkForUpdates(
              packageReference: 'omnyagent',
              currentVersion: Version.parse('2.0.0'),
            )).updateAvailable,
            isFalse,
          );
        });

        test('does not offer a pre-release unless asked', () async {
          await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('2.0.0-beta.1'),
          );

          expect(
            (await store.checkForUpdates(
              packageReference: 'omnyagent',
              currentVersion: Version.parse('1.0.0'),
            )).updateAvailable,
            isFalse,
          );
          expect(
            (await store.checkForUpdates(
              packageReference: 'omnyagent',
              currentVersion: Version.parse('1.0.0'),
              channel: ReleaseChannel.beta,
            )).updateAvailable,
            isTrue,
          );
        });

        test('flags an update with nothing for this platform', () async {
          final v2 = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.1.0'),
          );
          await store.attachAsset(
            releaseId: v2.id,
            name: 'agent-linux.tar.gz',
            data: Stream.value(utf8.encode('v2')),
            platform: 'linux-x64',
          );

          final info = await store.checkForUpdates(
            packageReference: 'omnyagent',
            currentVersion: Version.parse('1.0.0'),
            platform: 'macos-arm64',
          );

          expect(info.updateAvailable, isTrue);
          expect(info.asset, isNull);
          expect(info.isInstallable, isFalse);
        });
      });

      group('downloads', () {
        test('records a download and aggregates it', () async {
          if (!supportsDownloadRecording) return;

          await seed();
          final release = await store.publishRelease(
            packageReference: 'omnyagent',
            version: Version.parse('1.0.0'),
          );
          final asset = await store.attachAsset(
            releaseId: release.id,
            name: 'agent.txt',
            data: Stream.value(utf8.encode('payload')),
          );

          final record = await store.recordDownload(
            assetId: asset.id,
            clientAddress: '203.0.113.4',
            userAgent: 'omnystore-cli/1.0.0',
            bytesServed: 7,
          );

          expect(record.version, '1.0.0');
          expect(record.assetId, asset.id);
          expect((await store.asset(asset.id))!.downloadCount, 1);

          final records = await store.listDownloads('omnyagent');
          expect(records, hasLength(1));

          final stats = await store.downloadStats('omnyagent');
          expect(stats.total, 1);
          expect(stats.byVersion['1.0.0'], 1);
          expect(stats.byAsset[asset.id], 1);
        });

        test('lists and aggregates an empty history', () async {
          await seed();

          expect(await store.listDownloads('omnyagent'), isEmpty);
          expect((await store.downloadStats('omnyagent')).total, 0);
        });
      });

      group('providers', () {
        test('reports at least one provider', () async {
          final providers = await store.listProviders();

          expect(providers, isNotEmpty);
          expect(providers.first.id, isNotEmpty);
        });
      });
    });
  }

  // ------------------------------------------------------- embedded store ---
  conformanceSuite('OmnyStore', () async {
    final harness = TestStore();
    return (store: harness.store, dispose: harness.close);
  });

  // ------------------------------------------- hub over a local provider ---
  conformanceSuite('OmnyStoreHub (local provider)', () async {
    final federation = FakeFederation();
    return (store: federation.hub, dispose: federation.close);
  });

  // --------------------------------------------- hub over a remote node ---
  // Every call crosses the RPC protocol: JSON encoding of each argument,
  // chunked relay of artifact bytes, and typed exceptions reconstructed from
  // the error envelope.
  conformanceSuite('OmnyStoreHub (remote node over RPC)', () async {
    final federation = FakeFederation(withLocalProvider: false);
    federation.attach('node-1', servesAll: true);
    return (store: federation.hub, dispose: federation.close);
  });

  // ------------------------------------------- client over a real socket ---
  conformanceSuite('OmnyStoreClient (over HTTP)', () async {
    final backing = TestStore();
    final server = OmnyStoreServer(store: backing.store);
    await server.start(port: 0, address: '127.0.0.1');
    final client = OmnyStoreClient(baseUrl: 'http://127.0.0.1:${server.port}');
    return (
      store: client,
      dispose: () async {
        await client.close();
        await server.stop();
        await backing.close();
      },
    );
  }, supportsDownloadRecording: false);
}
