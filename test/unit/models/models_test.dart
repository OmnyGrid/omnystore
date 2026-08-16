import 'dart:convert';

import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

/// Every model, in a fully populated form, paired with its `fromJson`.
///
/// Round-tripping through `jsonEncode`/`jsonDecode` rather than straight
/// through the maps is deliberate: it is the only way to catch a field that
/// serialises to something JSON cannot carry, which is exactly the bug that
/// surfaces first in production and never in a unit test.
final samples =
    <String, ({Object model, Object Function(Map<String, dynamic>) parse})>{
      'Organization': (
        model: Organization(
          id: 'org-1',
          name: 'acme',
          displayName: 'Acme Corporation',
          description: 'Makers of things',
          website: 'https://acme.example.com',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 2, 1),
          metadata: {'tier': 'gold'},
        ),
        parse: Organization.fromJson,
      ),
      'Project': (
        model: Project(
          id: 'proj-1',
          organizationId: 'org-1',
          name: 'agent',
          displayName: 'Omny Agent',
          description: 'The agent',
          repository: 'https://github.com/acme/agent',
          website: 'https://agent.example.com',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 2, 1),
          metadata: {'team': 'platform'},
        ),
        parse: Project.fromJson,
      ),
      'Package': (
        model: Package(
          id: 'pkg-1',
          projectId: 'proj-1',
          organizationId: 'org-1',
          name: 'omnyagent',
          displayName: 'OmnyAgent',
          description: 'The daemon',
          defaultChannel: ReleaseChannel.beta,
          platforms: ['linux-x64', 'macos-arm64'],
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 2, 1),
          metadata: {'lang': 'dart'},
        ),
        parse: Package.fromJson,
      ),
      'Release': (
        model: Release(
          id: 'rel-1',
          packageId: 'pkg-1',
          organizationId: 'org-1',
          version: Version.parse('1.2.0-beta.3+ci.7'),
          title: 'Beta 3',
          notes: 'Notes with "quotes", a newline\nand ünicode.',
          tag: 'v1.2.0-beta.3',
          draft: false,
          yanked: true,
          yankedReason: 'bad build',
          createdAt: DateTime.utc(2026, 1, 1),
          publishedAt: DateTime.utc(2026, 1, 2),
          metadata: {'ci': 'github'},
        ),
        parse: Release.fromJson,
      ),
      'Asset': (
        model: Asset(
          id: 'asset-1',
          releaseId: 'rel-1',
          packageId: 'pkg-1',
          organizationId: 'org-1',
          name: 'omnyagent-linux-x64.tar.gz',
          storageKey:
              'orgs/acme/packages/omnyagent/1.2.0/omnyagent-linux-x64.tar.gz',
          contentType: 'application/gzip',
          sizeBytes: 4096,
          sha256:
              'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          platform: 'linux-x64',
          kind: 'archive',
          downloadCount: 42,
          createdAt: DateTime.utc(2026, 1, 2),
          metadata: {'built-by': 'ci'},
        ),
        parse: Asset.fromJson,
      ),
      'DownloadRecord': (
        model: DownloadRecord(
          id: 'dl-1',
          assetId: 'asset-1',
          releaseId: 'rel-1',
          packageId: 'pkg-1',
          organizationId: 'org-1',
          version: '1.2.0',
          downloadedAt: DateTime.utc(2026, 3, 1, 12, 30),
          providerId: 'node-eu',
          clientAddress: '203.0.113.4',
          userAgent: 'omnystore-cli/1.0.0',
          principalId: 'user-1',
          bytesServed: 4096,
          metadata: {'region': 'eu'},
        ),
        parse: DownloadRecord.fromJson,
      ),
      'DownloadStats': (
        model: DownloadStats(
          total: 7,
          byVersion: {'1.0.0': 3, '1.1.0': 4},
          byAsset: {'asset-1': 7},
          from: DateTime.utc(2026, 1, 1),
          to: DateTime.utc(2026, 2, 1),
        ),
        parse: DownloadStats.fromJson,
      ),
      'AssetLocation': (
        model: AssetLocation(
          id: 'loc-1',
          assetId: 'asset-1',
          providerId: 'node-eu',
          organizationId: 'org-1',
          storageKey: 'orgs/acme/packages/omnyagent/1.2.0/agent.tar.gz',
          state: ReplicaState.available,
          sizeBytes: 4096,
          createdAt: DateTime.utc(2026, 1, 2),
          verifiedAt: DateTime.utc(2026, 1, 3),
        ),
        parse: AssetLocation.fromJson,
      ),
      'ProviderDescriptor': (
        model: ProviderDescriptor(
          id: 'node-eu',
          kind: ProviderKind.node,
          organizations: {'acme', 'globex'},
          dataPlane: DataPlaneMode.presigned,
          baseUrl: 'https://eu.example.com',
          labels: {'region': 'eu'},
          priority: 10,
          capacityBytes: 1 << 40,
          usedBytes: 1 << 20,
          agentVersion: '1.0.0',
          status: ProviderStatus.draining,
          lastSeenAt: DateTime.utc(2026, 3, 1),
          metadata: {'rack': 'a1'},
        ),
        parse: ProviderDescriptor.fromJson,
      ),
      'UpdateInfo': (
        model: UpdateInfo(
          currentVersion: Version.parse('1.0.0'),
          latestVersion: Version.parse('1.2.0-beta.3'),
          updateAvailable: true,
          channel: ReleaseChannel.beta,
          release: Release(
            id: 'rel-1',
            packageId: 'pkg-1',
            organizationId: 'org-1',
            version: Version.parse('1.2.0-beta.3'),
            createdAt: DateTime.utc(2026, 1, 1),
            publishedAt: DateTime.utc(2026, 1, 2),
          ),
          asset: Asset(
            id: 'asset-1',
            releaseId: 'rel-1',
            packageId: 'pkg-1',
            organizationId: 'org-1',
            name: 'agent.tar.gz',
            storageKey: 'k',
            sizeBytes: 1,
            sha256: 'x',
            createdAt: DateTime.utc(2026, 1, 2),
          ),
          packageName: 'omnyagent',
          notes: 'Fixes a crash.',
        ),
        parse: UpdateInfo.fromJson,
      ),
    };

void main() {
  group('JSON round-trip', () {
    samples.forEach((name, sample) {
      test('$name survives encode → decode intact', () {
        final encoded = jsonEncode((sample.model as dynamic).toJson());
        final decoded = sample.parse(
          jsonDecode(encoded) as Map<String, dynamic>,
        );

        expect(decoded, sample.model);
        expect(decoded.hashCode, sample.model.hashCode);
      });
    });
  });

  group('equality', () {
    test('is structural, not identity', () {
      final a = Organization(
        id: 'org-1',
        name: 'acme',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        metadata: {'a': '1', 'b': '2'},
      );
      final b = Organization(
        id: 'org-1',
        name: 'acme',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        // Different insertion order: identity-based map equality would fail.
        metadata: {'b': '2', 'a': '1'},
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
    });

    test('distinguishes models that differ in one field', () {
      final base = Package(
        id: 'pkg-1',
        projectId: 'proj-1',
        organizationId: 'org-1',
        name: 'omnyagent',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      expect(base, isNot(base.copyWith(displayName: 'Other')));
      expect(base, isNot(base.copyWith(defaultChannel: ReleaseChannel.dev)));
      expect(base, isNot(base.copyWith(platforms: ['linux-x64'])));
    });
  });

  group('immutability', () {
    test('collections are unmodifiable views', () {
      final package = Package(
        id: 'pkg-1',
        projectId: 'proj-1',
        organizationId: 'org-1',
        name: 'omnyagent',
        platforms: ['linux-x64'],
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        metadata: {'a': 'b'},
      );

      expect(() => package.platforms.add('x'), throwsUnsupportedError);
      expect(() => package.metadata['c'] = 'd', throwsUnsupportedError);
    });

    test('a source collection cannot mutate a built model', () {
      final metadata = {'a': 'b'};
      final organization = Organization(
        id: 'org-1',
        name: 'acme',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        metadata: metadata,
      );

      metadata['c'] = 'd';
      expect(organization.metadata, {'a': 'b'});
    });
  });

  group('Release', () {
    test('derives its channel and title from the version', () {
      final release = Release(
        id: 'rel-1',
        packageId: 'pkg-1',
        organizationId: 'org-1',
        version: Version.parse('1.2.0-beta.3'),
        createdAt: DateTime.utc(2026),
      );

      expect(release.channel, ReleaseChannel.beta);
      expect(release.title, '1.2.0-beta.3');
      expect(release.isPreRelease, isTrue);
    });

    test('is offerable only when published, not draft and not yanked', () {
      final published = Release(
        id: 'r',
        packageId: 'p',
        organizationId: 'o',
        version: Version.parse('1.0.0'),
        createdAt: DateTime.utc(2026),
        publishedAt: DateTime.utc(2026),
      );

      expect(published.isOfferable, isTrue);
      expect(published.copyWith(draft: true).isOfferable, isFalse);
      expect(published.copyWith(yanked: true).isOfferable, isFalse);
      expect(
        Release(
          id: 'r',
          packageId: 'p',
          organizationId: 'o',
          version: Version.parse('1.0.0'),
          createdAt: DateTime.utc(2026),
        ).isOfferable,
        isFalse,
      );
    });

    test('clears the yank reason when re-instated', () {
      final yanked = Release(
        id: 'r',
        packageId: 'p',
        organizationId: 'o',
        version: Version.parse('1.0.0'),
        createdAt: DateTime.utc(2026),
        yanked: true,
        yankedReason: 'bad build',
      );

      // A re-instated release must not keep a reason that no longer applies.
      expect(yanked.copyWith(yanked: false).yankedReason, isNull);
      expect(yanked.copyWith(yanked: true).yankedReason, 'bad build');
    });

    test('orders newest first', () {
      final releases = [
        Release(
          id: 'a',
          packageId: 'p',
          organizationId: 'o',
          version: Version.parse('1.0.0'),
          createdAt: DateTime.utc(2026),
        ),
        Release(
          id: 'c',
          packageId: 'p',
          organizationId: 'o',
          version: Version.parse('2.0.0'),
          createdAt: DateTime.utc(2026),
        ),
        Release(
          id: 'b',
          packageId: 'p',
          organizationId: 'o',
          version: Version.parse('1.5.0'),
          createdAt: DateTime.utc(2026),
        ),
      ]..sort(Release.compareNewestFirst);

      expect(releases.map((r) => r.id), ['c', 'b', 'a']);
    });
  });

  group('AssetLocation', () {
    test('clears the error when it stops failing', () {
      final failed = AssetLocation(
        id: 'loc-1',
        assetId: 'a',
        providerId: 'p',
        organizationId: 'o',
        storageKey: 'k',
        sizeBytes: 1,
        createdAt: DateTime.utc(2026),
        state: ReplicaState.failed,
        error: 'disk full',
      );

      expect(failed.copyWith(state: ReplicaState.available).error, isNull);
      expect(failed.copyWith(state: ReplicaState.failed).error, 'disk full');
      expect(failed.isAvailable, isFalse);
      expect(
        failed.copyWith(state: ReplicaState.available).isAvailable,
        isTrue,
      );
    });
  });

  group('UpdateInfo', () {
    test('upToDate is never available', () {
      final info = UpdateInfo.upToDate(
        currentVersion: Version.parse('1.0.0'),
        channel: ReleaseChannel.release,
        packageName: 'omnyagent',
      );

      expect(info.updateAvailable, isFalse);
      expect(info.isInstallable, isFalse);
    });

    test('is installable only with both an update and an artifact', () {
      final withoutAsset = UpdateInfo(
        currentVersion: Version.parse('1.0.0'),
        latestVersion: Version.parse('1.1.0'),
        updateAvailable: true,
        channel: ReleaseChannel.release,
        packageName: 'omnyagent',
      );

      expect(withoutAsset.updateAvailable, isTrue);
      expect(withoutAsset.isInstallable, isFalse);
    });
  });
}
