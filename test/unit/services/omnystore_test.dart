import 'dart:convert';

import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

void main() {
  late TestStore harness;
  late OmnyStore store;

  setUp(() {
    harness = TestStore();
    store = harness.store;
  });

  tearDown(() => harness.close());

  group('organizations', () {
    test('creates one with derived defaults', () async {
      final org = await store.createOrganization(
        name: 'acme',
        description: 'Acme Corp',
      );

      expect(org.name, 'acme');
      // displayName defaults to the name rather than being left null, so every
      // UI has something to render without a fallback of its own.
      expect(org.displayName, 'acme');
      expect(org.description, 'Acme Corp');
      expect(org.createdAt, harness.clock.now());
      expect(org.updatedAt, org.createdAt);
    });

    test('rejects an invalid name', () async {
      await expectLater(
        store.createOrganization(name: 'Acme Corp'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.field,
            'field',
            contains('name'),
          ),
        ),
      );
    });

    test('rejects a duplicate name', () async {
      await store.createOrganization(name: 'acme');
      await expectLater(
        store.createOrganization(name: 'acme'),
        throwsA(isA<ConflictException>()),
      );
    });

    test('looks one up by id and by name', () async {
      final org = await store.createOrganization(name: 'acme');
      expect(await store.organization(org.id), org);
      expect(await store.organizationByName('acme'), org);
      expect(await store.organizationByName('nope'), isNull);
    });

    test('updates mutable fields and bumps updatedAt', () async {
      final org = await store.createOrganization(name: 'acme');
      harness.clock.advance(const Duration(hours: 1));

      final updated = await store.updateOrganization(
        org.id,
        displayName: 'Acme Corporation',
      );

      expect(updated.displayName, 'Acme Corporation');
      expect(updated.name, 'acme', reason: 'the routing key never changes');
      expect(updated.createdAt, org.createdAt);
      expect(updated.updatedAt, isNot(org.updatedAt));
    });

    test('refuses to delete a populated organization without force', () async {
      final package = await harness.seedPackage();

      await expectLater(
        store.deleteOrganization(package.organizationId),
        throwsA(isA<ConflictException>()),
      );

      await store.deleteOrganization(package.organizationId, force: true);
      expect(await store.listOrganizations(), isEmpty);
      expect(await store.listPackages(), isEmpty);
    });
  });

  group('packages', () {
    test('denormalises the organization onto the package', () async {
      final package = await harness.seedPackage();
      final project = await store.project(package.projectId);

      expect(package.organizationId, project!.organizationId);
    });

    test('resolves by id and by bare name', () async {
      final package = await harness.seedPackage();

      expect(await store.resolvePackage(package.id), package);
      expect(await store.resolvePackage('omnyagent'), package);
    });

    test('reports an unknown package', () async {
      await expectLater(
        store.resolvePackage('ghost'),
        throwsA(
          isA<PackageNotFoundException>().having(
            (e) => e.reference,
            'reference',
            'ghost',
          ),
        ),
      );
    });

    test('refuses to resolve an ambiguous bare name', () async {
      final org = await store.createOrganization(name: 'acme');
      final a = await store.createProject(organizationId: org.id, name: 'one');
      final b = await store.createProject(organizationId: org.id, name: 'two');
      await store.createPackage(projectId: a.id, name: 'agent');
      await store.createPackage(projectId: b.id, name: 'agent');

      // Picking one arbitrarily would publish releases into the wrong project.
      await expectLater(
        store.resolvePackage('agent'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('ambiguous'),
          ),
        ),
      );
    });
  });

  group('releases', () {
    setUp(() => harness.seedPackage());

    test('derives the channel from the version', () async {
      final stable = await harness.publish('omnyagent', '1.0.0');
      final beta = await harness.publish('omnyagent', '1.1.0-beta.2');
      final dev = await harness.publish('omnyagent', '1.1.0-dev.3');

      expect(stable.channel, ReleaseChannel.release);
      expect(beta.channel, ReleaseChannel.beta);
      expect(dev.channel, ReleaseChannel.dev);
    });

    test('treats build metadata as stable', () async {
      final release = await harness.publish('omnyagent', '2.0.0+build5');

      expect(release.channel, ReleaseChannel.release);
      expect(release.version.build, ['build5']);
    });

    test('refuses to republish a version', () async {
      await harness.publish('omnyagent', '1.0.0');

      await expectLater(
        harness.publish('omnyagent', '1.0.0'),
        throwsA(
          isA<ConflictException>().having(
            (e) => e.message,
            'message',
            contains('immutable'),
          ),
        ),
      );
    });

    test('stamps publishedAt unless it is a draft', () async {
      final published = await harness.publish('omnyagent', '1.0.0');
      final draft = await harness.publish('omnyagent', '1.1.0', draft: true);

      expect(published.publishedAt, harness.clock.now());
      expect(published.isOfferable, isTrue);
      expect(draft.publishedAt, isNull);
      expect(draft.isOfferable, isFalse);
    });

    test('publishing a draft stamps its publication time', () async {
      final draft = await harness.publish('omnyagent', '1.1.0', draft: true);
      harness.clock.advance(const Duration(days: 1));

      final published = await store.updateRelease(draft.id, draft: false);

      expect(published.publishedAt, harness.clock.now());
      expect(published.isOfferable, isTrue);
    });

    test('lists newest first and excludes drafts by default', () async {
      await harness.publish('omnyagent', '1.0.0');
      await harness.publish('omnyagent', '1.2.0');
      await harness.publish('omnyagent', '1.1.0');
      await harness.publish('omnyagent', '2.0.0', draft: true);

      final offered = await store.listReleases('omnyagent');
      expect(offered.map((r) => '${r.version}'), ['1.2.0', '1.1.0', '1.0.0']);

      final all = await store.listReleases(
        'omnyagent',
        query: ReleaseQuery.all,
      );
      expect(all.first.version.toString(), '2.0.0');
    });

    test('orders two builds of one version deterministically', () async {
      await harness.publish('omnyagent', '1.0.0+build1');
      await harness.publish('omnyagent', '1.0.0+build2');

      // Semver calls these equal; a registry cannot, or "latest" would flap.
      expect(
        (await store.latestRelease('omnyagent'))!.version.toString(),
        '1.0.0+build2',
      );
    });
  });

  group('channel selection', () {
    setUp(() async {
      await harness.seedPackage();
      await harness.publish('omnyagent', '1.0.0');
      await harness.publish('omnyagent', '1.1.0-beta.1');
      await harness.publish('omnyagent', '1.2.0-dev.4');
    });

    test('latestRelease returns only stable', () async {
      expect(
        (await store.latestRelease('omnyagent'))!.version.toString(),
        '1.0.0',
      );
    });

    test('latestBeta and latestDev return their own channel', () async {
      expect(
        (await store.latestBeta('omnyagent'))!.version.toString(),
        '1.1.0-beta.1',
      );
      expect(
        (await store.latestDev('omnyagent'))!.version.toString(),
        '1.2.0-dev.4',
      );
    });

    test('latestAny returns the newest across every channel', () async {
      expect(
        (await store.latestAny('omnyagent'))!.version.toString(),
        '1.2.0-dev.4',
      );
    });

    test('latestChannel is inclusive downward in stability', () async {
      // A beta subscriber accepts beta and stable, but never a dev build.
      final beta = await store.latestChannel('omnyagent', ReleaseChannel.beta);
      expect(beta!.version.toString(), '1.1.0-beta.1');

      await harness.publish('omnyagent', '2.0.0');
      final promoted = await store.latestChannel(
        'omnyagent',
        ReleaseChannel.beta,
      );
      expect(
        promoted!.version.toString(),
        '2.0.0',
        reason: 'a newer stable release reaches beta subscribers too',
      );
    });

    test('exact mode restricts to the single channel', () async {
      await harness.publish('omnyagent', '2.0.0');

      final exact = await store.latestChannel(
        'omnyagent',
        ReleaseChannel.beta,
        exact: true,
      );
      expect(exact!.version.toString(), '1.1.0-beta.1');
    });

    test('yanked releases are never offered', () async {
      final latest = await store.latestRelease('omnyagent');
      await store.updateRelease(
        latest!.id,
        yanked: true,
        yankedReason: 'bad build',
      );

      expect(await store.latestRelease('omnyagent'), isNull);
      // But it stays retrievable, so clients that pinned it keep working.
      final stillThere = await store.release(latest.id);
      expect(stillThere!.yanked, isTrue);
      expect(stillThere.yankedReason, 'bad build');
    });

    test('un-yanking clears the reason', () async {
      final latest = (await store.latestRelease('omnyagent'))!;
      await store.updateRelease(latest.id, yanked: true, yankedReason: 'oops');

      final restored = await store.updateRelease(latest.id, yanked: false);

      expect(restored.yanked, isFalse);
      expect(restored.yankedReason, isNull);
    });
  });

  group('assets', () {
    setUp(() => harness.seedPackage());

    test('computes size and checksum while streaming', () async {
      final release = await harness.publish('omnyagent', '1.0.0');
      const content = 'binary-payload';

      final asset = await store.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-linux-x64.tar.gz',
        data: Stream.value(utf8.encode(content)),
        platform: 'linux-x64',
      );

      expect(asset.sizeBytes, content.length);
      expect(asset.sha256, Checksums.sha256OfString(content));
      expect(asset.platform, 'linux-x64');
      expect(
        asset.storageKey,
        'orgs/acme/packages/omnyagent/1.0.0/omnyagent-linux-x64.tar.gz',
      );
    });

    test(
      'verifies a declared checksum and stores nothing on mismatch',
      () async {
        final release = await harness.publish('omnyagent', '1.0.0');

        await expectLater(
          store.attachAsset(
            releaseId: release.id,
            name: 'agent.tar.gz',
            data: Stream.value(utf8.encode('actual content')),
            expectedSha256: Checksums.sha256OfString('what I expected'),
          ),
          throwsA(isA<ChecksumMismatchException>()),
        );

        expect(await store.listAssets(release.id), isEmpty);
        expect(harness.storage.length, 0, reason: 'no bytes were retained');
      },
    );

    test('rejects a filename that escapes its prefix', () async {
      final release = await harness.publish('omnyagent', '1.0.0');

      await expectLater(
        store.attachAsset(
          releaseId: release.id,
          name: '../../../etc/passwd',
          data: Stream.value(const [1, 2, 3]),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a duplicate asset name within a release', () async {
      final release = await harness.publish(
        'omnyagent',
        '1.0.0',
        assets: {'agent.tar.gz': 'one'},
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

    test('reads bytes back, whole and ranged', () async {
      final release = await harness.publish(
        'omnyagent',
        '1.0.0',
        assets: {'agent.txt': 'hello world'},
      );
      final asset = (await store.listAssets(release.id)).single;

      expect(
        await readAsString((await store.openAsset(asset.id)).stream),
        'hello world',
      );

      final ranged = await store.openAsset(asset.id, range: ByteRange(6, 10));
      expect(await readAsString(ranged.stream), 'world');
      expect(ranged.isPartial, isTrue);
      expect(ranged.length, 5);
    });

    test('deleting an asset removes its bytes and placement', () async {
      final release = await harness.publish(
        'omnyagent',
        '1.0.0',
        assets: {'agent.txt': 'data'},
      );
      final asset = (await store.listAssets(release.id)).single;

      await store.deleteAsset(asset.id);

      expect(await store.listAssets(release.id), isEmpty);
      expect(harness.storage.length, 0);
      expect(
        await harness.store.repositories.locations.byAsset(asset.id),
        isEmpty,
      );
    });

    test('deleting a release cascades to its assets', () async {
      final release = await harness.publish(
        'omnyagent',
        '1.0.0',
        assets: {'a.txt': 'a', 'b.txt': 'b'},
      );

      await store.deleteRelease(release.id);

      expect(await store.release(release.id), isNull);
      expect(harness.storage.length, 0);
    });
  });

  group('promotion', () {
    setUp(() => harness.seedPackage());

    test('creates a stable release carrying the artifacts across', () async {
      final beta = await harness.publish(
        'omnyagent',
        '1.2.0-beta.3',
        assets: {'agent.tar.gz': 'payload'},
      );

      final promoted = await store.promoteRelease(
        beta.id,
        ReleaseChannel.release,
      );

      expect(promoted.version.toString(), '1.2.0');
      expect(promoted.channel, ReleaseChannel.release);
      expect(promoted.metadata['promotedFrom'], '1.2.0-beta.3');

      final assets = await store.listAssets(promoted.id);
      expect(assets.single.name, 'agent.tar.gz');
      expect(
        await readAsString((await store.openAsset(assets.single.id)).stream),
        'payload',
      );
      // The source release is untouched — clients on beta keep working.
      expect(await store.release(beta.id), isNotNull);
    });

    test('refuses to promote towards instability', () async {
      final stable = await harness.publish('omnyagent', '1.2.0');

      await expectLater(
        store.promoteRelease(stable.id, ReleaseChannel.beta),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('towards stability'),
          ),
        ),
      );
    });

    test('refuses to promote onto an existing version', () async {
      final beta = await harness.publish('omnyagent', '1.2.0-beta.1');
      await harness.publish('omnyagent', '1.2.0');

      await expectLater(
        store.promoteRelease(beta.id, ReleaseChannel.release),
        throwsA(isA<ConflictException>()),
      );
    });
  });

  group('downloads', () {
    test('records a download and increments the counter', () async {
      await harness.seedPackage();
      final release = await harness.publish(
        'omnyagent',
        '1.0.0',
        assets: {'agent.txt': 'data'},
      );
      final asset = (await store.listAssets(release.id)).single;

      await store.recordDownload(
        assetId: asset.id,
        clientAddress: '203.0.113.4',
        userAgent: 'omnystore-cli/1.0.0',
      );

      expect((await store.asset(asset.id))!.downloadCount, 1);

      final records = await store.listDownloads('omnyagent');
      expect(records.single.version, '1.0.0');
      expect(records.single.clientAddress, '203.0.113.4');

      final stats = await store.downloadStats('omnyagent');
      expect(stats.total, 1);
      expect(stats.byVersion['1.0.0'], 1);
    });
  });

  group('update checks', () {
    setUp(() async {
      await harness.seedPackage();
      await harness.publish(
        'omnyagent',
        '1.0.0',
        assets: {'agent-linux.tar.gz': 'v1'},
        platform: 'linux-x64',
      );
    });

    test('offers a newer stable release', () async {
      await harness.publish(
        'omnyagent',
        '1.1.0',
        assets: {'agent-linux.tar.gz': 'v2'},
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
    });

    test('reports current when already on the newest', () async {
      final info = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
      );

      expect(info.updateAvailable, isFalse);
      expect(info.latestVersion.toString(), '1.0.0');
    });

    test('never offers a downgrade to a client that is ahead', () async {
      final info = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('2.0.0-dev.1'),
      );

      expect(info.updateAvailable, isFalse);
    });

    test('does not offer a pre-release to a stable client', () async {
      await harness.publish('omnyagent', '2.0.0-beta.1');

      final stable = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
      );
      expect(stable.updateAvailable, isFalse);

      final tester = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        channel: ReleaseChannel.beta,
      );
      expect(tester.updateAvailable, isTrue);
      expect(tester.latestVersion.toString(), '2.0.0-beta.1');
    });

    test('flags an update with no artifact for this platform', () async {
      await harness.publish(
        'omnyagent',
        '1.1.0',
        assets: {'agent-linux.tar.gz': 'v2'},
        platform: 'linux-x64',
      );

      final info = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'macos-arm64',
      );

      expect(info.updateAvailable, isTrue);
      expect(info.asset, isNull);
      // The distinction a client's download button must gate on.
      expect(info.isInstallable, isFalse);
    });

    test('handles a package with no offerable release', () async {
      await harness.seedPackage(
        organization: 'other',
        project: 'thing',
        package: 'empty',
      );

      final info = await store.checkForUpdates(
        packageReference: 'empty',
        currentVersion: Version.parse('1.0.0'),
      );

      expect(info.updateAvailable, isFalse);
      expect(info.latestVersion, isNull);
      expect(info.release, isNull);
    });
  });
}
