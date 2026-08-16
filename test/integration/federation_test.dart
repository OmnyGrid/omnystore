import 'dart:convert';

import 'package:omnystore/omnystore_hub.dart';
import 'package:test/test.dart';

import '../support/federation.dart';
import '../support/harness.dart';

void main() {
  late FakeFederation federation;
  late OmnyStoreHub hub;

  tearDown(() => federation.close());

  group('hub as its own provider', () {
    setUp(() {
      federation = FakeFederation();
      hub = federation.hub;
    });

    test('serves a full lifecycle with no nodes attached', () async {
      final org = await hub.createOrganization(name: 'acme');
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      final package = await hub.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );
      await hub.attachAsset(
        releaseId: release.id,
        name: 'agent.tar.gz',
        data: Stream.value(utf8.encode('payload')),
        platform: 'linux-x64',
      );

      expect(
        (await hub.latestRelease('omnyagent'))!.version.toString(),
        '1.0.0',
      );
      final assets = await hub.listAssets(release.id);
      expect(
        await readAsString((await hub.openAsset(assets.single.id)).stream),
        'payload',
      );
    });

    test('reports itself as the only provider', () async {
      final providers = await hub.listProviders();
      expect(providers.single.id, 'hub-local');
      expect(providers.single.kind, ProviderKind.hub);
      expect(providers.single.servesAll, isTrue);
    });
  });

  group('routing by organization', () {
    late FakeNode eu;
    late FakeNode us;

    setUp(() {
      federation = FakeFederation();
      hub = federation.hub;
      eu = federation.attach('node-eu', organizations: {'acme'});
      us = federation.attach('node-us', organizations: {'globex'});
    });

    test('sends an organization write to the node that serves it', () async {
      // `acme` is declared by node-eu, so it wins over the catch-all hub.
      final acme = await hub.createOrganization(name: 'acme');
      expect(await eu.backing.store.organization(acme.id), isNotNull);
      expect(await us.backing.store.organization(acme.id), isNull);
      expect(
        await federation.localBacking!.store.organization(acme.id),
        isNull,
      );

      final globex = await hub.createOrganization(name: 'globex');
      expect(await us.backing.store.organization(globex.id), isNotNull);
    });

    test('falls back to the catch-all for an unclaimed organization', () async {
      final other = await hub.createOrganization(name: 'initech');

      expect(
        await federation.localBacking!.store.organization(other.id),
        isNotNull,
        reason: 'no node declares initech, so the hub keeps it',
      );
    });

    test('writes follow ownership down the hierarchy', () async {
      final org = await hub.createOrganization(name: 'acme');
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      final package = await hub.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );

      // Every child landed on the node holding the parent, not on the hub.
      expect(await eu.backing.store.project(project.id), isNotNull);
      expect(await eu.backing.store.package(package.id), isNotNull);
      expect(await eu.backing.store.release(release.id), isNotNull);
      expect(await federation.localBacking!.store.release(release.id), isNull);
    });

    test('aggregates listings across every provider', () async {
      await hub.createOrganization(name: 'acme');
      await hub.createOrganization(name: 'globex');
      await hub.createOrganization(name: 'initech');

      final names = (await hub.listOrganizations()).map((o) => o.name);
      expect(names, ['acme', 'globex', 'initech']);
    });

    test(
      'an unreachable node degrades a listing rather than failing it',
      () async {
        await hub.createOrganization(name: 'acme');
        await hub.createOrganization(name: 'globex');

        us.goOffline();

        // globex lived on node-us and is gone; acme is still served.
        final names = (await hub.listOrganizations()).map((o) => o.name);
        expect(names, contains('acme'));
        expect(names, isNot(contains('globex')));
      },
    );
  });

  group('many-to-many organizations and nodes', () {
    late FakeNode primary;
    late FakeNode secondary;

    setUp(() {
      federation = FakeFederation(withLocalProvider: false);
      hub = federation.hub;
      // Both nodes serve `acme`; `primary` also serves `globex`. One
      // organization on several nodes, and one node with several organizations.
      primary = federation.attach(
        'node-a',
        organizations: {'acme', 'globex'},
        priority: 10,
      );
      secondary = federation.attach(
        'node-b',
        organizations: {'acme'},
        priority: 1,
      );
    });

    test('writes go to the highest-priority provider for the org', () async {
      final acme = await hub.createOrganization(name: 'acme');

      expect(await primary.backing.store.organization(acme.id), isNotNull);
      expect(
        await secondary.backing.store.organization(acme.id),
        isNull,
        reason: 'a write goes to exactly one provider, so ids stay unique',
      );
    });

    test('a node can carry several organizations', () async {
      await hub.createOrganization(name: 'acme');
      await hub.createOrganization(name: 'globex');

      final held = await primary.backing.store.listOrganizations();
      expect(held.map((o) => o.name), ['acme', 'globex']);
    });

    /// Publishes `acme/agent/omnyagent@1.0.0` with one artifact.
    Future<Asset> seedAsset(String content) async {
      final org = await hub.createOrganization(name: 'acme');
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      final package = await hub.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
        notes: 'Notes carried to the replica.',
      );
      return hub.attachAsset(
        releaseId: release.id,
        name: 'agent.tar.gz',
        data: Stream.value(utf8.encode(content)),
        platform: 'linux-x64',
      );
    }

    test('replicates asset bytes onto a second node for the org', () async {
      final asset = await seedAsset('replicate me');

      final replica = await hub.replicateAsset(asset.id, 'node-b');

      expect(replica.sha256, asset.sha256);
      expect(replica.platform, 'linux-x64');
      expect(
        await readAsString(
          (await secondary.backing.store.openAsset(replica.id)).stream,
        ),
        'replicate me',
      );
    });

    test('builds the ownership chain on the target by natural key', () async {
      // Each provider mints its own ids, so the target's copies are located by
      // name and version and created when absent — not by copying ids across,
      // which would dangle.
      final asset = await seedAsset('replicate me');

      await hub.replicateAsset(asset.id, 'node-b');

      final mirrored = secondary.backing.store;
      expect((await mirrored.organizationByName('acme'))!.name, 'acme');
      final release = await mirrored.latestRelease('omnyagent');
      expect(release!.version.toString(), '1.0.0');
      expect(release.notes, 'Notes carried to the replica.');
      // The ids genuinely differ between providers.
      expect(release.id, isNot(asset.releaseId));
    });

    test('converges when re-run, rather than failing', () async {
      // Replication is a reconciliation pass; running it twice must not be an
      // error, or a scheduled reconciler would alarm on every cycle.
      final asset = await seedAsset('replicate me');

      final first = await hub.replicateAsset(asset.id, 'node-b');
      final second = await hub.replicateAsset(asset.id, 'node-b');

      expect(second.id, first.id);
      expect(secondary.backing.storage.length, 1);
    });

    test(
      'refuses to replicate onto the provider that already owns it',
      () async {
        final asset = await seedAsset('replicate me');

        await expectLater(
          hub.replicateAsset(asset.id, 'node-a'),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test('refuses to replicate onto a draining provider', () async {
      final asset = await seedAsset('replicate me');
      secondary.drain();

      await expectLater(
        hub.replicateAsset(asset.id, 'node-b'),
        throwsA(isA<StorageException>()),
      );
    });

    test('a replicated organization still lists once', () async {
      final asset = await seedAsset('replicate me');
      await hub.replicateAsset(asset.id, 'node-b');

      // Deduplicated by natural key, so replication stays invisible to
      // clients.
      expect((await hub.listOrganizations()).map((o) => o.name), ['acme']);
      expect((await hub.listPackages()).map((p) => p.name), ['omnyagent']);
    });

    test('a draining node keeps serving reads but takes no writes', () async {
      final acme = await hub.createOrganization(name: 'acme');
      primary.drain();

      // Reads still reach it.
      expect(await hub.organization(acme.id), isNotNull);

      // New writes for `acme` fall to the remaining writable provider.
      final globexAttempt = hub.createOrganization(name: 'globex');
      await expectLater(globexAttempt, throwsA(isA<StorageException>()));
    });
  });

  group('relay data plane', () {
    late FakeNode node;

    setUp(() {
      federation = FakeFederation(withLocalProvider: false);
      hub = federation.hub;
      node = federation.attach('node-1', organizations: {'acme'});
    });

    Future<Asset> seedAsset(String content) async {
      final org = await hub.createOrganization(name: 'acme');
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      final package = await hub.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );
      return hub.attachAsset(
        releaseId: release.id,
        name: 'agent.bin',
        data: Stream.value(utf8.encode(content)),
      );
    }

    test('streams an upload across chunk boundaries', () async {
      // Well over the node's 64-byte chunk size, so the relay genuinely splits.
      final content = List.generate(50, (i) => 'chunk-$i-').join();
      final asset = await seedAsset(content);

      expect(asset.sizeBytes, content.length);
      expect(asset.sha256, Checksums.sha256OfString(content));
      expect(
        node.calls.where((c) => c == StoreProtocol.uploadChunk).length,
        greaterThan(1),
        reason: 'the payload must have been sent as several chunks',
      );
    });

    test('streams a download back across chunk boundaries', () async {
      final content = List.generate(50, (i) => 'chunk-$i-').join();
      final asset = await seedAsset(content);

      final download = await hub.openAsset(asset.id);

      expect(await readAsString(download.stream), content);
      expect(download.length, content.length);
      expect(
        node.calls.where((c) => c == StoreProtocol.chunkRead).length,
        greaterThan(1),
      );
    });

    test('serves a byte range through the relay', () async {
      final asset = await seedAsset('hello world');

      final download = await hub.openAsset(asset.id, range: ByteRange(6, 10));

      expect(await readAsString(download.stream), 'world');
      expect(download.length, 5);
    });

    test('closes the node session when a download is abandoned', () async {
      final content = List.generate(50, (i) => 'chunk-$i-').join();
      final asset = await seedAsset(content);

      final download = await hub.openAsset(asset.id);
      // Take one chunk, then walk away — the pattern of a client that
      // disconnects mid-download.
      await download.stream.take(1).drain<void>();

      expect(
        node.rpc.openReads,
        0,
        reason: 'an abandoned read must not pin an object handle on the node',
      );
    });

    test('unwinds a failed upload, leaving nothing behind', () async {
      final org = await hub.createOrganization(name: 'acme');
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      final package = await hub.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );

      await expectLater(
        hub.attachAsset(
          releaseId: release.id,
          name: 'agent.bin',
          data: Stream.fromIterable([utf8.encode('some bytes')])
              .asyncExpand<List<int>>(
                (chunk) => Stream.error(StateError('source failed')),
              ),
        ),
        throwsA(isA<Object>()),
      );

      expect(await hub.listAssets(release.id), isEmpty);
      expect(node.rpc.openUploads, 0);
      expect(node.backing.storage.length, 0);
    });

    test('reports a stream target when the node cannot presign', () async {
      final asset = await seedAsset('payload');

      final target = await hub.downloadTarget(asset.id);

      expect(target, isA<StreamedDownload>());
      expect((target as StreamedDownload).providerId, isNotEmpty);
    });
  });

  group('typed errors across the wire', () {
    setUp(() {
      federation = FakeFederation(withLocalProvider: false);
      hub = federation.hub;
      federation.attach('node-1', organizations: {'acme'});
    });

    test('a not-found on the node arrives as its own exception type', () async {
      await hub.createOrganization(name: 'acme');

      await expectLater(
        hub.resolvePackage('ghost'),
        throwsA(isA<PackageNotFoundException>()),
      );
    });

    test('a conflict on the node arrives as a conflict', () async {
      final org = await hub.createOrganization(name: 'acme');
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      final package = await hub.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );

      await expectLater(
        hub.publishRelease(
          packageReference: package.id,
          version: Version.parse('1.0.0'),
        ),
        throwsA(isA<ConflictException>()),
      );
    });

    test('a checksum mismatch on the node arrives as a mismatch', () async {
      final org = await hub.createOrganization(name: 'acme');
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      final package = await hub.createPackage(
        projectId: project.id,
        name: 'omnyagent',
      );
      final release = await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.0.0'),
      );

      await expectLater(
        hub.attachAsset(
          releaseId: release.id,
          name: 'agent.bin',
          data: Stream.value(utf8.encode('actual')),
          expectedSha256: Checksums.sha256OfString('expected'),
        ),
        throwsA(isA<ChecksumMismatchException>()),
      );
    });
  });

  group('ambiguity across the federation', () {
    test('refuses a bare package name held by two providers', () async {
      federation = FakeFederation(withLocalProvider: false);
      hub = federation.hub;
      final a = federation.attach('node-a', organizations: {'acme'});
      final b = federation.attach('node-b', organizations: {'globex'});

      for (final (node, org) in [(a, 'acme'), (b, 'globex')]) {
        final organization = await node.backing.store.createOrganization(
          name: org,
        );
        final project = await node.backing.store.createProject(
          organizationId: organization.id,
          name: 'agent',
        );
        await node.backing.store.createPackage(
          projectId: project.id,
          name: 'omnyagent',
        );
      }

      // Publishing into "whichever one we found first" would put a release in
      // the wrong organization, so this has to be an error.
      await expectLater(
        hub.resolvePackage('omnyagent'),
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
}
