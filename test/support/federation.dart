import 'package:omnystore/omnystore_hub.dart';

import 'harness.dart';

/// A storage node wired to a hub through the real [StoreProtocol] — the same
/// actions and payloads a socket would carry — but invoked in-process.
///
/// Everything the wire protocol does is exercised: JSON encoding of every
/// argument, chunked relay of artifact bytes, and typed-exception round-tripping
/// through the error envelope. Only the socket is elided, which is what makes
/// the federation tests fast and deterministic while still testing the protocol
/// rather than a mock of it.
class FakeNode {
  /// The node's own store.
  final TestStore backing;

  /// The node's RPC server, answering hub calls.
  final StoreRpcServer rpc;

  /// The hub-side proxy for this node.
  final RemoteNodeStoreProvider provider;

  /// Every action the hub has invoked, in order — for asserting that a call
  /// took the route the test expects rather than being served locally.
  final List<String> calls = [];

  /// Whether the node is currently reachable. Set `false` to simulate a
  /// partition without tearing anything down.
  bool reachable = true;

  FakeNode._(this.backing, this.rpc, this.provider);

  /// Creates a node serving [organizations].
  ///
  /// [servesAll] makes it a catch-all, which is how the hub's own local
  /// provider behaves in a single-server deployment.
  factory FakeNode({
    required String id,
    Set<String> organizations = const {},
    bool servesAll = false,
    int priority = 0,
    ProviderStatus status = ProviderStatus.online,
    int chunkBytes = 64,
  }) {
    final backing = TestStore(idScope: id);
    late final FakeNode node;

    var descriptor = ProviderDescriptor(
      id: id,
      kind: ProviderKind.node,
      organizations: organizations,
      servesAll: servesAll,
      dataPlane: DataPlaneMode.relay,
      priority: priority,
      status: status,
    );

    final rpc = StoreRpcServer(
      store: backing.store,
      describeProvider: () async => descriptor,
      idGenerator: SequentialIdGenerator(),
    );

    final provider = RemoteNodeStoreProvider(
      descriptor: descriptor,
      // A deliberately small chunk size, so relay tests cross chunk boundaries
      // with payloads small enough to read in a failure message.
      chunkBytes: chunkBytes,
      invoke: (action, payload) async {
        node.calls.add(action);
        if (!node.reachable) {
          throw StorageException('Node $id is unreachable');
        }
        return rpc.handle(action, payload);
      },
    );

    node = FakeNode._(backing, rpc, provider);

    /// Keeps the hub-side descriptor and the node-side one in step, the way a
    /// heartbeat would.
    node._setDescriptor = (updated) {
      descriptor = updated;
      provider.updateDescriptor(updated);
    };
    return node;
  }

  late void Function(ProviderDescriptor) _setDescriptor;

  /// The organizations this node serves.
  Set<String> get organizations => provider.descriptor.organizations;

  /// Replaces the advertised descriptor on both sides.
  void updateDescriptor(ProviderDescriptor descriptor) =>
      _setDescriptor(descriptor);

  /// Marks the node draining: still serving downloads, taking no new writes.
  void drain() => updateDescriptor(
    provider.descriptor.copyWith(status: ProviderStatus.draining),
  );

  /// Marks the node offline.
  void goOffline() {
    reachable = false;
    updateDescriptor(
      provider.descriptor.copyWith(status: ProviderStatus.offline),
    );
  }

  /// Brings the node back online.
  void goOnline() {
    reachable = true;
    updateDescriptor(
      provider.descriptor.copyWith(status: ProviderStatus.online),
    );
  }

  /// Releases the node's resources.
  Future<void> close() async {
    await rpc.closeSessions();
    await backing.close();
  }
}

/// A hub with an optional catch-all local provider, plus any number of nodes.
class FakeFederation {
  /// The hub under test.
  final OmnyStoreHub hub;

  /// The hub's own local provider, or `null` if it hosts nothing itself.
  final LocalStoreProvider? local;

  /// The hub's local backing store, when it has one.
  final TestStore? localBacking;

  /// The attached nodes, by id.
  final Map<String, FakeNode> nodes = {};

  FakeFederation._(this.hub, this.local, this.localBacking);

  /// Creates a federation.
  ///
  /// [withLocalProvider] gives the hub a catch-all provider of its own — the
  /// "a hub can also be a provider" deployment, where no separate node process
  /// is needed beside it.
  factory FakeFederation({bool withLocalProvider = true}) {
    final hub = OmnyStoreHub();
    TestStore? backing;
    LocalStoreProvider? local;

    if (withLocalProvider) {
      backing = TestStore(idScope: 'hub-local');
      local = LocalStoreProvider(
        backing.store,
        descriptor: ProviderDescriptor(
          id: 'hub-local',
          kind: ProviderKind.hub,
          servesAll: true,
          dataPlane: DataPlaneMode.relay,
          // Lowest priority: a catch-all is the fallback, and an
          // organization-specific node must win whenever one exists.
          priority: -100,
        ),
      );
      hub.addProvider(local);
    }

    return FakeFederation._(hub, local, backing);
  }

  /// Attaches a node serving [organizations] and returns it.
  FakeNode attach(
    String id, {
    Set<String> organizations = const {},
    bool servesAll = false,
    int priority = 0,
    int chunkBytes = 64,
  }) {
    final node = FakeNode(
      id: id,
      organizations: organizations,
      servesAll: servesAll,
      priority: priority,
      chunkBytes: chunkBytes,
    );
    hub.addProvider(node.provider);
    nodes[id] = node;
    return node;
  }

  /// Releases every participant's resources.
  Future<void> close() async {
    for (final node in nodes.values) {
      await node.close();
    }
    await localBacking?.close();
    await hub.providers.close();
  }
}
