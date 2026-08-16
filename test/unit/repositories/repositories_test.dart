import 'dart:io';

import 'package:omnystore/omnystore.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/harness.dart';

/// Builds a release for [packageId] at [version].
Release releaseAt(
  String packageId,
  String version, {
  String id = 'rel',
  bool draft = false,
  bool yanked = false,
  bool published = true,
}) {
  final parsed = Version.parse(version);
  return Release(
    id: id,
    packageId: packageId,
    organizationId: 'org-1',
    version: parsed,
    createdAt: DateTime.utc(2026),
    publishedAt: published ? DateTime.utc(2026) : null,
    draft: draft,
    yanked: yanked,
  );
}

void main() {
  group('ReleaseQuery', () {
    final stable = releaseAt('pkg', '1.0.0', id: 'a');
    final beta = releaseAt('pkg', '1.1.0-beta.1', id: 'b');
    final dev = releaseAt('pkg', '1.2.0-dev.4', id: 'c');
    final draft = releaseAt('pkg', '2.0.0', id: 'd', draft: true);
    final yanked = releaseAt('pkg', '1.0.1', id: 'e', yanked: true);
    final unpublished = releaseAt('pkg', '3.0.0', id: 'f', published: false);
    final all = [stable, beta, dev, draft, yanked, unpublished];

    test('defaults to what a client should be offered', () {
      const query = ReleaseQuery();

      expect(query.apply(all).map((r) => r.id), ['c', 'b', 'a']);
    });

    test('sorts newest first regardless of input order', () {
      expect(const ReleaseQuery().apply(all.reversed).map((r) => r.id), [
        'c',
        'b',
        'a',
      ]);
    });

    test('filters to an exact channel', () {
      expect(
        ReleaseQuery.onChannel(ReleaseChannel.beta).apply(all).map((r) => r.id),
        ['b'],
      );
      expect(
        ReleaseQuery.onChannel(
          ReleaseChannel.release,
        ).apply(all).map((r) => r.id),
        ['a'],
      );
    });

    test('acceptedBy is inclusive downward in stability', () {
      // What the update service asks: a beta subscriber takes beta and stable.
      expect(
        ReleaseQuery.acceptedBy(
          ReleaseChannel.beta,
        ).apply(all).map((r) => r.id),
        ['b', 'a'],
      );
      expect(
        ReleaseQuery.acceptedBy(ReleaseChannel.dev).apply(all).map((r) => r.id),
        ['c', 'b', 'a'],
      );
      expect(
        ReleaseQuery.acceptedBy(
          ReleaseChannel.release,
        ).apply(all).map((r) => r.id),
        ['a'],
      );
    });

    test('the publisher view includes everything', () {
      expect(ReleaseQuery.all.apply(all), hasLength(6));
    });

    test('pages after sorting, not before', () {
      // Offsetting an unsorted sequence would walk an arbitrary order.
      const page = ReleaseQuery(limit: 2);
      expect(page.apply(all).map((r) => r.id), ['c', 'b']);
      expect(page.copyWith(offset: 1).apply(all).map((r) => r.id), ['b', 'a']);
      expect(page.copyWith(offset: 99).apply(all), isEmpty);
    });

    test('renders to URL query parameters', () {
      expect(
        const ReleaseQuery(
          channel: ReleaseChannel.beta,
          includeDrafts: true,
          limit: 10,
          offset: 5,
        ).toQueryParameters(),
        {
          'channel': 'beta',
          'includeDrafts': 'true',
          'limit': '10',
          'offset': '5',
        },
      );
      expect(const ReleaseQuery().toQueryParameters(), isEmpty);
    });

    test('has value equality', () {
      expect(
        const ReleaseQuery(channel: ReleaseChannel.beta),
        const ReleaseQuery(channel: ReleaseChannel.beta),
      );
      expect(
        const ReleaseQuery(channel: ReleaseChannel.beta).hashCode,
        const ReleaseQuery(channel: ReleaseChannel.beta).hashCode,
      );
      expect(
        const ReleaseQuery(channel: ReleaseChannel.beta),
        isNot(const ReleaseQuery(channel: ReleaseChannel.dev)),
      );
    });
  });

  group('MemoryReleaseRepository', () {
    late MemoryReleaseRepository repository;

    setUp(() async {
      repository = MemoryReleaseRepository();
      for (final (id, version) in [
        ('a', '1.0.0'),
        ('b', '1.1.0-beta.1'),
        ('c', '1.2.0'),
      ]) {
        await repository.save(releaseAt('pkg', version, id: id));
      }
    });

    test('finds an exact version, build metadata included', () async {
      await repository.save(releaseAt('pkg', '2.0.0+build1', id: 'd'));
      await repository.save(releaseAt('pkg', '2.0.0+build2', id: 'e'));

      expect(
        (await repository.byVersion('pkg', Version.parse('2.0.0+build1')))!.id,
        'd',
      );
      expect(
        await repository.byVersion('pkg', Version.parse('2.0.0')),
        isNull,
        reason: 'a bare 2.0.0 is a different release from 2.0.0+build1',
      );
    });

    test('latest ignores the query paging', () async {
      // "The latest matching release" is the head of the sequence; applying an
      // offset would silently answer a different question.
      final latest = await repository.latest(
        'pkg',
        query: const ReleaseQuery(offset: 2, limit: 1),
      );
      expect(latest!.id, 'c');
    });

    test('latest respects the channel filter', () async {
      expect(
        (await repository.latest(
          'pkg',
          query: ReleaseQuery.onChannel(ReleaseChannel.beta),
        ))!.id,
        'b',
      );
    });

    test('latest returns null for a package with nothing offerable', () async {
      expect(await repository.latest('other'), isNull);
    });

    test('scopes listings by package and organization', () async {
      await repository.save(
        Release(
          id: 'other',
          packageId: 'pkg2',
          organizationId: 'org-2',
          version: Version.parse('9.0.0'),
          createdAt: DateTime.utc(2026),
          publishedAt: DateTime.utc(2026),
        ),
      );

      expect(await repository.listByPackage('pkg'), hasLength(3));
      expect(await repository.listByOrganization('org-1'), hasLength(3));
      expect(await repository.listByOrganization('org-2'), hasLength(1));
    });
  });

  group('MemoryAssetRepository', () {
    test('increments the download counter atomically per call', () async {
      final repository = MemoryAssetRepository();
      final asset = Asset(
        id: 'asset-1',
        releaseId: 'rel-1',
        packageId: 'pkg-1',
        organizationId: 'org-1',
        name: 'a.tar.gz',
        storageKey: 'k',
        sizeBytes: 1,
        sha256: 'x',
        createdAt: DateTime.utc(2026),
      );
      await repository.save(asset);

      // Concurrent downloads of one asset must not lose a count.
      await Future.wait([
        repository.incrementDownloadCount('asset-1'),
        repository.incrementDownloadCount('asset-1'),
        repository.incrementDownloadCount('asset-1'),
      ]);

      expect((await repository.byId('asset-1'))!.downloadCount, 3);
    });

    test('returns null when incrementing a missing asset', () async {
      expect(
        await MemoryAssetRepository().incrementDownloadCount('ghost'),
        isNull,
      );
    });
  });

  group('MemoryDownloadRepository', () {
    DownloadRecord recordAt(
      String id,
      DateTime at, {
      String version = '1.0.0',
    }) => DownloadRecord(
      id: id,
      assetId: 'asset-1',
      releaseId: 'rel-1',
      packageId: 'pkg-1',
      organizationId: 'org-1',
      version: version,
      downloadedAt: at,
    );

    test('lists newest first', () async {
      final repository = MemoryDownloadRepository();
      await repository.save(recordAt('a', DateTime.utc(2026, 1, 1)));
      await repository.save(recordAt('c', DateTime.utc(2026, 1, 3)));
      await repository.save(recordAt('b', DateTime.utc(2026, 1, 2)));

      expect((await repository.listByAsset('asset-1')).map((r) => r.id), [
        'c',
        'b',
        'a',
      ]);
      expect(
        (await repository.listByAsset('asset-1', limit: 2)).map((r) => r.id),
        ['c', 'b'],
      );
    });

    test('aggregates statistics over a half-open window', () async {
      final repository = MemoryDownloadRepository();
      await repository.save(
        recordAt('a', DateTime.utc(2026, 1, 1), version: '1.0.0'),
      );
      await repository.save(
        recordAt('b', DateTime.utc(2026, 1, 2), version: '1.1.0'),
      );
      await repository.save(
        recordAt('c', DateTime.utc(2026, 1, 3), version: '1.1.0'),
      );

      final all = await repository.statsByPackage('pkg-1');
      expect(all.total, 3);
      expect(all.byVersion, {'1.0.0': 1, '1.1.0': 2});

      final window = await repository.statsByPackage(
        'pkg-1',
        from: DateTime.utc(2026, 1, 2),
        to: DateTime.utc(2026, 1, 3),
      );
      expect(window.total, 1, reason: 'from is inclusive, to is exclusive');
      expect(window.byVersion, {'1.1.0': 1});
    });

    test('discards the oldest records past its cap', () async {
      // Unbounded download history in a long-lived process is a silent leak
      // that only shows up in production.
      final repository = MemoryDownloadRepository(maxRecords: 2);
      for (var i = 0; i < 5; i++) {
        await repository.save(recordAt('$i', DateTime.utc(2026, 1, i + 1)));
      }

      final kept = await repository.listByAsset('asset-1');
      expect(kept.map((r) => r.id), ['4', '3']);
    });

    test('deletes an asset history', () async {
      final repository = MemoryDownloadRepository();
      await repository.save(recordAt('a', DateTime.utc(2026)));

      expect(await repository.deleteByAsset('asset-1'), 1);
      expect(await repository.listByAsset('asset-1'), isEmpty);
    });
  });

  group('MemoryAssetLocationRepository', () {
    AssetLocation locationAt(String id, String assetId, String providerId) =>
        AssetLocation(
          id: id,
          assetId: assetId,
          providerId: providerId,
          organizationId: 'org-1',
          storageKey: 'k',
          sizeBytes: 10,
          createdAt: DateTime.utc(2026),
          state: ReplicaState.available,
        );

    test('indexes placements by asset, provider and organization', () async {
      final repository = MemoryAssetLocationRepository();
      await repository.save(locationAt('l1', 'asset-1', 'node-a'));
      await repository.save(locationAt('l2', 'asset-1', 'node-b'));
      await repository.save(locationAt('l3', 'asset-2', 'node-a'));

      expect((await repository.byAsset('asset-1')).map((l) => l.providerId), [
        'node-a',
        'node-b',
      ]);
      expect(await repository.byProvider('node-a'), hasLength(2));
      expect(await repository.byOrganization('org-1'), hasLength(3));
      expect(
        (await repository.byAssetAndProvider('asset-1', 'node-b'))!.id,
        'l2',
      );
      expect(await repository.byAssetAndProvider('asset-1', 'node-z'), isNull);
    });

    test('deletes every placement of an asset', () async {
      final repository = MemoryAssetLocationRepository();
      await repository.save(locationAt('l1', 'asset-1', 'node-a'));
      await repository.save(locationAt('l2', 'asset-1', 'node-b'));

      expect(await repository.deleteByAsset('asset-1'), 2);
      expect(await repository.byAsset('asset-1'), isEmpty);
    });
  });

  group('JsonFileRepositories', () {
    test('round-trips a registry through the filesystem', () async {
      await withTempDir((dir) async {
        final path = p.join(dir.path, 'metadata');

        final first = await JsonFileRepositories.open(path);
        final store = OmnyStore(
          repositories: first,
          storage: MemoryObjectStorage(),
          clock: FixedClock(),
          idGenerator: SequentialIdGenerator(),
        );
        final org = await store.createOrganization(name: 'acme');
        final project = await store.createProject(
          organizationId: org.id,
          name: 'agent',
        );
        final package = await store.createPackage(
          projectId: project.id,
          name: 'omnyagent',
        );
        await store.publishRelease(
          packageReference: package.id,
          version: Version.parse('1.2.0'),
          notes: 'Notes with "quotes" and a ünicode character.',
        );
        await first.flush();

        // Re-opened as a separate instance, exactly as a restarted server would.
        final second = await JsonFileRepositories.open(path);
        final reopened = OmnyStore(
          repositories: second,
          storage: MemoryObjectStorage(),
        );

        expect((await reopened.listOrganizations()).single.name, 'acme');
        final release = await reopened.latestRelease('omnyagent');
        expect(release!.version.toString(), '1.2.0');
        expect(release.notes, 'Notes with "quotes" and a ünicode character.');
        expect(release.channel, ReleaseChannel.release);
      });
    });

    test('writes each collection to its own readable file', () async {
      await withTempDir((dir) async {
        final path = p.join(dir.path, 'metadata');
        final repositories = await JsonFileRepositories.open(path);
        final store = OmnyStore(
          repositories: repositories,
          storage: MemoryObjectStorage(),
        );
        await store.createOrganization(name: 'acme');
        await repositories.flush();

        final file = File(p.join(path, 'organizations.json'));
        expect(file.existsSync(), isTrue);
        // Indented, because most of the point of JSON-on-disk is that an
        // operator can read and diff it.
        expect(file.readAsStringSync(), contains('\n  {'));
        expect(file.readAsStringSync(), contains('"name": "acme"'));
      });
    });

    test('starts empty on a fresh directory', () async {
      await withTempDir((dir) async {
        final repositories = await JsonFileRepositories.open(
          p.join(dir.path, 'brand-new'),
        );
        expect(await repositories.organizations.list(), isEmpty);
      });
    });

    test(
      'refuses to open a corrupt file rather than losing the catalogue',
      () async {
        await withTempDir((dir) async {
          final path = p.join(dir.path, 'metadata');
          await JsonFileRepositories.open(path);
          File(p.join(path, 'releases.json')).writeAsStringSync('[{"broken":');

          // Starting empty would look, to every client, exactly like every
          // release having been deleted — and they would act on it.
          await expectLater(
            JsonFileRepositories.open(path),
            throwsA(
              isA<StorageException>().having(
                (e) => e.message,
                'message',
                allOf(contains('Cannot parse'), contains('backup')),
              ),
            ),
          );
        });
      },
    );

    test('rejects a file holding the wrong JSON shape', () async {
      await withTempDir((dir) async {
        final path = p.join(dir.path, 'metadata');
        await JsonFileRepositories.open(path);
        File(
          p.join(path, 'packages.json'),
        ).writeAsStringSync('{"not": "list"}');

        await expectLater(
          JsonFileRepositories.open(path),
          throwsA(isA<StorageException>()),
        );
      });
    });

    test('treats an empty file as an empty collection', () async {
      await withTempDir((dir) async {
        final path = p.join(dir.path, 'metadata');
        await JsonFileRepositories.open(path);
        File(p.join(path, 'projects.json')).writeAsStringSync('');

        final reopened = await JsonFileRepositories.open(path);
        expect(await reopened.projects.list(), isEmpty);
      });
    });

    test('persists a delete, not just a write', () async {
      await withTempDir((dir) async {
        final path = p.join(dir.path, 'metadata');
        final repositories = await JsonFileRepositories.open(path);
        final store = OmnyStore(
          repositories: repositories,
          storage: MemoryObjectStorage(),
        );
        final org = await store.createOrganization(name: 'acme');
        await store.deleteOrganization(org.id);
        await repositories.flush();

        final reopened = await JsonFileRepositories.open(path);
        expect(await reopened.organizations.list(), isEmpty);
      });
    });

    test('leaves no temporary files behind', () async {
      await withTempDir((dir) async {
        final path = p.join(dir.path, 'metadata');
        final repositories = await JsonFileRepositories.open(path);
        final store = OmnyStore(
          repositories: repositories,
          storage: MemoryObjectStorage(),
        );
        for (var i = 0; i < 5; i++) {
          await store.createOrganization(name: 'org$i');
        }
        await repositories.flush();

        final stray = Directory(path)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.tmp.'))
            .toList();
        expect(stray, isEmpty);
      });
    });
  });
}
