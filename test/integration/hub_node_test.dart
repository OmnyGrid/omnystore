@Tags(['server'])
library;

import 'dart:convert';

import 'package:omnystore/omnystore_hub.dart' hide Version;
import 'package:omnystore/omnystore_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Runs a real hub and a real node over a real WebSocket.
///
/// The federation tests drive the RPC protocol in-process; this one closes the
/// last gap — that `OmnyStoreNode` and `StoreNodeGateway` agree on
/// registration, heartbeating, admission and teardown when an actual socket
/// and OmnyHub's node runtime are in between.
void main() {
  late TestStore hubBacking;
  late TestStore nodeBacking;
  late OmnyStoreHub hub;
  late OmnyStoreServer server;
  late OmnyStoreNode node;

  /// Waits until [condition] holds, or fails the test.
  ///
  /// Registration completes asynchronously after `start` returns, so the tests
  /// wait for the observable effect rather than sleeping a guessed duration.
  Future<void> until(
    bool Function() condition, {
    String reason = 'condition was never met',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail(reason);
  }

  setUp(() async {
    hubBacking = TestStore(idScope: 'hub-local');
    nodeBacking = TestStore(idScope: 'node-eu');

    hub = OmnyStoreHub()
      ..addProvider(
        LocalStoreProvider(
          hubBacking.store,
          descriptor: ProviderDescriptor(
            id: 'hub-local',
            kind: ProviderKind.hub,
            servesAll: true,
            priority: -100,
          ),
        ),
      );

    server = OmnyStoreServer(store: hub, nodeAuthenticator: null);
    await server.start(port: 0, address: '127.0.0.1');

    node = OmnyStoreNode(
      hubUri: Uri.parse('ws://127.0.0.1:${server.port}/_node'),
      nodeId: 'node-eu',
      store: nodeBacking.store,
      organizations: {'acme'},
      labels: const {'region': 'eu'},
      priority: 10,
      heartbeatInterval: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    await node.stop();
    await server.stop();
    await nodeBacking.close();
    await hubBacking.close();
  });

  group('registration', () {
    test('a node joins the federation and is routed to', () async {
      await node.start();
      await until(
        () => hub.providers.byId('node-eu') != null,
        reason: 'the node never registered',
      );

      final providers = await hub.listProviders();
      expect(providers.map((p) => p.id), containsAll(['hub-local', 'node-eu']));

      final registered = hub.providers.byId('node-eu')!.descriptor;
      expect(registered.organizations, {'acme'});
      expect(registered.kind, ProviderKind.node);
      expect(registered.labels['region'], 'eu');
      expect(
        registered.servesAll,
        isFalse,
        reason: 'only the hub itself may be a catch-all',
      );
    });

    test('the node takes over its organization from the catch-all', () async {
      await node.start();
      await until(() => hub.providers.byId('node-eu') != null);

      final acme = await hub.createOrganization(name: 'acme');
      final other = await hub.createOrganization(name: 'initech');

      // `acme` is declared by the node, so it wins over the hub's catch-all.
      expect(await nodeBacking.store.organization(acme.id), isNotNull);
      expect(await hubBacking.store.organization(acme.id), isNull);
      // Nothing claims `initech`, so it stays on the hub.
      expect(await hubBacking.store.organization(other.id), isNotNull);
    });

    test('an admission policy can narrow what a node may serve', () async {
      final guardedHub = OmnyStoreHub();
      final guardedServer = OmnyStoreServer(
        store: guardedHub,
        nodeAdmissionPolicy: (nodeId, declared, principal) =>
            declared.intersection({'acme'}),
      );
      await guardedServer.start(port: 0, address: '127.0.0.1');

      final overreaching = TestStore(idScope: 'greedy');
      final greedy = OmnyStoreNode(
        hubUri: Uri.parse('ws://127.0.0.1:${guardedServer.port}/_node'),
        nodeId: 'greedy',
        store: overreaching.store,
        organizations: {'acme', 'globex', 'initech'},
      );
      addTearDown(() async {
        await greedy.stop();
        await guardedServer.stop();
        await overreaching.close();
      });

      await greedy.start();
      await until(() => guardedHub.providers.byId('greedy') != null);

      // Without a policy, any peer reaching the endpoint could claim to serve
      // an organization and start receiving its releases.
      expect(guardedHub.providers.byId('greedy')!.descriptor.organizations, {
        'acme',
      });
    });
  });

  group('operations across the socket', () {
    setUp(() async {
      await node.start();
      await until(() => hub.providers.byId('node-eu') != null);
    });

    test('runs a full release lifecycle on the node', () async {
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

      const payload = 'artifact bytes crossing a websocket';
      final asset = await hub.attachAsset(
        releaseId: release.id,
        name: 'agent.tar.gz',
        data: Stream.value(utf8.encode(payload)),
        platform: 'linux-x64',
      );

      // The bytes really landed on the node, not on the hub.
      expect(nodeBacking.storage.length, 1);
      expect(hubBacking.storage.length, 0);

      expect(asset.sha256, Checksums.sha256OfString(payload));
      expect(
        await readAsString((await hub.openAsset(asset.id)).stream),
        payload,
      );
      expect(
        (await hub.latestRelease('omnyagent'))!.version.toString(),
        '1.0.0',
      );
    });

    test('answers an update check from the node', () async {
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
      final v2 = await hub.publishRelease(
        packageReference: package.id,
        version: Version.parse('1.1.0'),
      );
      await hub.attachAsset(
        releaseId: v2.id,
        name: 'agent-linux.tar.gz',
        data: Stream.value(utf8.encode('v2')),
        platform: 'linux-x64',
      );

      final info = await hub.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'linux-x64',
      );

      expect(info.updateAvailable, isTrue);
      expect(info.latestVersion.toString(), '1.1.0');
      expect(info.asset!.name, 'agent-linux.tar.gz');
    });

    test('a typed failure on the node keeps its type at the hub', () async {
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
  });

  group('lifecycle', () {
    test('draining stops writes while reads keep working', () async {
      await node.start();
      await until(() => hub.providers.byId('node-eu') != null);

      final org = await hub.createOrganization(name: 'acme');
      await node.drain();
      await until(
        () =>
            hub.providers.byId('node-eu')!.descriptor.status ==
            ProviderStatus.draining,
        reason: 'the hub never saw the drain',
      );

      // Still readable.
      expect(await hub.organization(org.id), isNotNull);

      // But no longer writable, and nothing else serves `acme`, so the hub
      // falls back to its catch-all rather than failing.
      final project = await hub.createProject(
        organizationId: org.id,
        name: 'agent',
      );
      expect(project.name, 'agent');
    });

    test('a node leaving removes it from the routing table', () async {
      await node.start();
      await until(() => hub.providers.byId('node-eu') != null);

      await node.stop();

      await until(
        () => hub.providers.byId('node-eu') == null,
        reason: 'the hub kept a dead provider in its routing table',
      );
      final providers = await hub.listProviders();
      expect(providers.map((p) => p.id), ['hub-local']);
    });

    test('a node rejoining is routed to again', () async {
      await node.start();
      await until(() => hub.providers.byId('node-eu') != null);
      await node.stop();
      await until(() => hub.providers.byId('node-eu') == null);

      final rejoined = OmnyStoreNode(
        hubUri: Uri.parse('ws://127.0.0.1:${server.port}/_node'),
        nodeId: 'node-eu',
        store: nodeBacking.store,
        organizations: {'acme'},
      );
      addTearDown(rejoined.stop);

      await rejoined.start();
      await until(
        () => hub.providers.byId('node-eu') != null,
        reason: 'a reconnecting node must be re-admitted under the same id',
      );
    });
  });
}
