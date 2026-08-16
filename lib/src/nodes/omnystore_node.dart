import 'dart:async';

import 'package:omnyhub/omnyhub.dart' show Logger, NoopLogger;
import 'package:omnyhub/omnyhub_node.dart'
    show
        NodeConfig,
        NodeId,
        NodeRegistered,
        NodeRuntime,
        NodeState,
        ReconnectPolicy;

import '../exceptions/omnystore_exception.dart';
import '../models/provider_descriptor.dart';
import '../services/omnystore.dart';
import '../version.dart';
import 'store_protocol.dart';
import 'store_rpc_server.dart';

/// A storage node: an [OmnyStore] that dials a hub and serves its
/// organizations' releases through it.
///
/// The node is the unit of capacity and ownership in a federated deployment. It
/// holds the metadata *and* the bytes for the organizations it serves, and
/// answers the hub's calls over an outbound WebSocket — so it can sit behind
/// NAT, on a private network, or in a different cloud from the hub, and still
/// be a first-class part of a public registry.
///
/// ```dart
/// final node = OmnyStoreNode(
///   hubUri: Uri.parse('wss://store.example.com/_node'),
///   nodeId: 'node-eu',
///   organizations: {'acme', 'globex'},
///   store: OmnyStore(
///     repositories: MemoryRepositories(),
///     storage: S3ObjectStorage(
///       bucket: 'acme-releases',
///       region: 'eu-west-1',
///       credentials: EnvironmentAwsCredentialsProvider(Platform.environment),
///     ),
///     providerId: 'node-eu',
///   ),
///   authToken: Platform.environment['OMNYSTORE_NODE_TOKEN'],
/// );
///
/// await node.start();
/// ```
///
/// **Reconnection is automatic.** The underlying `NodeRuntime` reconnects with
/// exponential backoff and re-registers, so a hub restart or a network blip
/// heals without operator action. Downloads in flight over the relay fail and
/// must be retried; a client behind a `DownloadManager` resumes them.
///
/// **The data plane is chosen from what the node can do.** If its object
/// storage can presign URLs the node advertises [DataPlaneMode.presigned] and
/// clients fetch straight from the bucket. If it is reachable at [publicBaseUrl]
/// it advertises [DataPlaneMode.direct]. Otherwise it falls back to
/// [DataPlaneMode.relay], where artifact bytes are chunked over the control
/// channel — always correct, and the slowest of the three.
class OmnyStoreNode {
  /// The store holding this node's organizations.
  final OmnyStore store;

  /// The organizations this node serves.
  final Set<String> organizations;

  /// This node's identifier, unique within the hub.
  final String nodeId;

  /// The node's publicly reachable base URL, enabling
  /// [DataPlaneMode.direct]. `null` means the node is not reachable and bytes
  /// are relayed.
  final String? publicBaseUrl;

  /// Placement labels advertised to the hub (`region=eu`, `tier=cold`).
  final Map<String, String> labels;

  /// Selection weight: higher wins when several nodes serve one organization.
  final int priority;

  /// Total capacity in bytes, or `null` if unbounded/unknown.
  final int? capacityBytes;

  /// Structured logging.
  final Logger logger;

  /// The RPC server answering the hub's calls.
  ///
  /// `late` because it closes over `this` to describe the node, which is not
  /// available until the field initialisers have run.
  late final StoreRpcServer rpc;

  /// The underlying OmnyHub node runtime: connection, registration,
  /// heartbeating and reconnection.
  late final NodeRuntime runtime;

  bool _draining = false;

  /// Creates a node.
  ///
  /// [authToken] is sent as a bearer token on the WebSocket upgrade, so a hub
  /// with an authenticator admits only nodes it knows.
  OmnyStoreNode({
    required Uri hubUri,
    required this.nodeId,
    required this.store,
    Set<String> organizations = const {},
    this.publicBaseUrl,
    Map<String, String> labels = const {},
    this.priority = 0,
    this.capacityBytes,
    this.logger = const NoopLogger(),
    String? authToken,
    Duration heartbeatInterval = const Duration(seconds: 10),
    Duration sessionTimeout = const Duration(minutes: 10),
    ReconnectPolicy? reconnect,
    NodeRuntime? runtime,
    StoreRpcServer? rpc,
  }) : organizations = Set.unmodifiable(organizations),
       labels = Map.unmodifiable(labels) {
    this.rpc =
        rpc ??
        StoreRpcServer(
          store: store,
          sessionTimeout: sessionTimeout,
          describeProvider: describe,
        );
    this.runtime =
        runtime ??
        NodeRuntime(
          NodeConfig(
            hubUri: hubUri,
            nodeId: NodeId(nodeId),
            // Advertised so a hub whose OmnyHub instance also hosts other kinds
            // of node can tell storage providers apart from the rest.
            capabilities: {StoreProtocol.capability},
            labels: this.labels,
            agentVersion: omnyStoreVersion,
            heartbeatInterval: heartbeatInterval,
            reconnect: reconnect,
            headers: {
              if (authToken != null) 'authorization': 'Bearer $authToken',
            },
            // The hub calls these actions; the RPC server answers them against
            // this node's own store.
            onRequest: (action, payload) => this.rpc.handle(action, payload),
            registerPayload: () async => {
              StoreProtocol.versionKey: StoreProtocol.version,
              StoreProtocol.descriptorKey: (await describe()).toJson(),
            },
            onRegistered: _onRegistered,
            // Capacity and usage ride along on the heartbeat, so placement
            // decisions use fresh numbers without the hub polling every node.
            heartbeatPayload: () async => {
              StoreProtocol.descriptorKey: (await describe()).toJson(),
            },
          ),
          logger: logger,
        );
  }

  /// Lifecycle transitions of the hub connection.
  Stream<NodeState> get states => runtime.states;

  /// Whether the node is registered with the hub and serving.
  bool get isReady => runtime.isReady;

  /// Whether the node is draining: still serving downloads, taking no writes.
  bool get isDraining => _draining;

  /// This node's current provider descriptor.
  Future<ProviderDescriptor> describe() => _describe(
    nodeId: nodeId,
    store: store,
    organizations: organizations,
    publicBaseUrl: publicBaseUrl,
    labels: labels,
    priority: priority,
    capacityBytes: capacityBytes,
    draining: _draining,
  );

  /// Connects to the hub and registers. Returns once the node is serving.
  Future<void> start() async {
    await runtime.start();
    logger.info(
      'Storage node started',
      context: {
        'node': nodeId,
        'organizations': organizations.join(','),
        'hub': runtime.config.hubUri.toString(),
      },
    );
  }

  /// Stops accepting new writes while continuing to serve downloads, and tells
  /// the hub.
  ///
  /// The safe way to retire a node: the hub stops placing new artifacts here
  /// immediately, while every client already downloading from it finishes
  /// normally. Replicate its artifacts elsewhere, then [stop] it.
  Future<void> drain() async {
    _draining = true;
    await _announce();
    logger.info('Storage node draining', context: {'node': nodeId});
  }

  /// Resumes accepting writes after a [drain].
  Future<void> resume() async {
    _draining = false;
    await _announce();
  }

  /// Disconnects from the hub, closing every in-flight relay session.
  Future<void> stop() async {
    await rpc.closeSessions();
    await runtime.stop();
    logger.info('Storage node stopped', context: {'node': nodeId});
  }

  /// Stops the node and closes its store.
  Future<void> close() async {
    await stop();
    await store.close();
  }

  Future<void> _onRegistered(NodeRegistered ack) async {
    logger.info(
      'Registered with hub',
      context: {'node': nodeId, 'hub': ack.hubId},
    );
  }

  /// Pushes a fresh descriptor to the hub outside the heartbeat cycle, so a
  /// drain takes effect immediately rather than up to one interval later.
  Future<void> _announce() async {
    if (!runtime.isReady) return;
    try {
      runtime.notify(
        StoreProtocol.describe,
        payload: {StoreProtocol.descriptorKey: (await describe()).toJson()},
      );
    } on Object catch (e) {
      // Best-effort: the next heartbeat carries the same descriptor, so a lost
      // notify delays the change rather than losing it.
      logger.warn(
        'Could not announce descriptor change',
        context: {'node': nodeId, 'error': '$e'},
      );
    }
  }

  static Future<ProviderDescriptor> _describe({
    required String nodeId,
    required OmnyStore store,
    required Set<String> organizations,
    required String? publicBaseUrl,
    required Map<String, String> labels,
    required int priority,
    required int? capacityBytes,
    required bool draining,
  }) async {
    // Preference order matters: presigned costs the registry nothing, direct
    // costs it a redirect, relay costs it the whole artifact's bandwidth twice.
    final dataPlane = store.storage.supportsPresignedUrls
        ? DataPlaneMode.presigned
        : publicBaseUrl != null
        ? DataPlaneMode.direct
        : DataPlaneMode.relay;

    int? used;
    try {
      used = await store.storage.usedBytes();
    } on OmnyStoreException {
      // A backend that cannot report usage must not stop the node registering;
      // placement reads `null` as "has room".
      used = null;
    }

    return ProviderDescriptor(
      id: nodeId,
      kind: ProviderKind.node,
      organizations: organizations,
      // A node always serves an explicit set. Only a hub's own provider is a
      // catch-all, so that attaching a node for `acme` takes over `acme`
      // without any hub reconfiguration.
      servesAll: false,
      dataPlane: dataPlane,
      baseUrl: publicBaseUrl,
      labels: labels,
      priority: priority,
      capacityBytes: capacityBytes,
      usedBytes: used,
      agentVersion: omnyStoreVersion,
      status: draining ? ProviderStatus.draining : ProviderStatus.online,
      lastSeenAt: store.clock.now(),
    );
  }
}
