import 'dart:convert';
import 'dart:io';

import 'package:omnystore/omnystore_hub.dart' hide Version;
import 'package:omnystore/omnystore_node.dart';

/// **7 — A hub federating storage nodes.**
///
/// The hub is the discovery point; the nodes hold the metadata *and* the bytes
/// for the organizations they serve. Organizations and nodes are **many to
/// many**: one organization's releases may live on several nodes, and one node
/// may serve several organizations.
///
/// Both nodes here run in this process for the sake of the example; in a real
/// deployment each is a separate `omnystore node` process, possibly behind NAT
/// in another datacentre.
///
/// ```sh
/// dart run example/hub_and_nodes/hub_with_nodes.dart
/// ```
Future<void> main() async {
  // ---------------------------------------------------------------- hub ---
  final hubLocal = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
    providerId: 'hub-local',
  );

  final hub = OmnyStoreHub()
    ..addProvider(
      LocalStoreProvider(
        hubLocal,
        descriptor: ProviderDescriptor(
          id: 'hub-local',
          kind: ProviderKind.hub,
          // The fallback for organizations no node claims. Lowest priority, so
          // attaching a node for `acme` takes over `acme` with no hub change.
          servesAll: true,
          priority: -100,
        ),
      ),
    );

  final server = OmnyStoreServer(store: hub);
  await server.start(port: 0, address: '127.0.0.1');
  final hubUri = Uri.parse('ws://127.0.0.1:${server.port}/_node');

  // -------------------------------------------------------------- nodes ---
  // `node-eu` serves two organizations; `acme` is served by two nodes.
  final nodes = [
    OmnyStoreNode(
      hubUri: hubUri,
      nodeId: 'node-eu',
      store: OmnyStore(
        repositories: MemoryRepositories(),
        storage: MemoryObjectStorage(),
        providerId: 'node-eu',
      ),
      organizations: {'acme', 'globex'},
      labels: const {'region': 'eu'},
      priority: 10,
    ),
    OmnyStoreNode(
      hubUri: hubUri,
      nodeId: 'node-us',
      store: OmnyStore(
        repositories: MemoryRepositories(),
        storage: MemoryObjectStorage(),
        providerId: 'node-us',
      ),
      organizations: {'acme'},
      labels: const {'region': 'us'},
      priority: 1,
    ),
  ];

  for (final node in nodes) {
    await node.start();
  }
  await _waitForProviders(hub, 3);

  print('Providers the hub knows about:');
  for (final provider in await hub.listProviders()) {
    print(
      '  ${provider.id.padRight(10)} ${provider.kind.name.padRight(5)} '
      '${provider.servesAll ? '*' : provider.organizations.join(',')}',
    );
  }

  // ------------------------------------------------------------ traffic ---
  // Routed to node-eu: it declares `acme`, so it beats the hub's catch-all,
  // and it outranks node-us on priority.
  final organization = await hub.createOrganization(name: 'acme');
  final project = await hub.createProject(
    organizationId: organization.id,
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
  final asset = await hub.attachAsset(
    releaseId: release.id,
    name: 'omnyagent-linux-x64.tar.gz',
    data: Stream.value(utf8.encode('artifact bytes crossing a websocket')),
    platform: 'linux-x64',
  );

  print('\nPublished ${release.version}; the artifact landed on a node:');
  print(
    '  hub holds  ${(hubLocal.storage as MemoryObjectStorage).length} objects',
  );
  for (final node in nodes) {
    final storage = node.store.storage as MemoryObjectStorage;
    print('  ${node.nodeId} holds ${storage.length} objects');
  }

  // Reads work through the hub regardless of which node holds the bytes.
  final bytes = <int>[];
  await for (final chunk in (await hub.openAsset(asset.id)).stream) {
    bytes.addAll(chunk);
  }
  print('\nRead back through the hub: "${utf8.decode(bytes)}"');

  // An organization no node claims falls to the hub's own provider.
  final unclaimed = await hub.createOrganization(name: 'initech');
  print(
    'initech landed on the hub itself: '
    '${await hubLocal.organization(unclaimed.id) != null}',
  );

  // ------------------------------------------------------------ retire ---
  // Draining stops new placements while downloads in flight finish.
  await nodes.first.drain();
  print('\nnode-eu is draining; writes for acme now fall to node-us.');

  for (final node in nodes) {
    await node.close();
  }
  await server.stop();
  await hubLocal.close();
  exit(0);
}

/// Waits until the hub has [count] providers, since registration completes
/// asynchronously after `start` returns.
Future<void> _waitForProviders(OmnyStoreHub hub, int count) async {
  for (var i = 0; i < 200; i++) {
    if (hub.providers.length >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('nodes did not register');
}
