import 'dart:async';

import 'package:omnyhub/omnyhub.dart'
    show
        Connection,
        Heartbeat,
        Logger,
        NoopLogger,
        NodeDescriptor,
        NodeGateway,
        NodeId,
        Principal,
        RegisteredNode,
        UnauthorizedException,
        ValidationException;

import '../models/provider_descriptor.dart';
import '../nodes/remote_store_provider.dart';
import '../nodes/store_protocol.dart';
import '../utils/json.dart';
import 'omnystore_hub.dart';

/// Decides whether a storage node may join the federation, and which
/// organizations it is allowed to serve.
///
/// A node declares what it holds; without a check, anyone who can reach the
/// control endpoint could declare themselves the provider for `acme` and start
/// receiving its releases. Return the organizations the node may actually serve
/// — usually [declared], possibly a subset — or throw to reject it.
///
/// [principal] is whoever authenticated on the WebSocket upgrade, so a hub with
/// a token authenticator can key the decision off a real identity.
typedef NodeAdmissionPolicy =
    FutureOr<Set<String>> Function(
      String nodeId,
      Set<String> declared,
      Principal? principal,
    );

/// The hub-side endpoint storage nodes connect to.
///
/// Wraps OmnyHub's [NodeGateway] and translates its lifecycle into
/// [OmnyStoreHub] provider membership: a node that registers becomes a
/// [RemoteNodeStoreProvider] in the hub's registry, its heartbeats refresh that
/// provider's capacity and status, and a disconnect removes it.
///
/// ```dart
/// final hub = OmnyStoreHub();
/// final gateway = StoreNodeGateway(store: hub);
///
/// final server = OmnyHub(transports: [HttpTransport.http(port: 8080)]);
/// await server.registerService(gateway.service);
/// await server.start();
/// ```
///
/// Mount it on the same OmnyHub instance that serves the REST API and both
/// share one port — which is what makes a hub deployable as a single container
/// with one exposed port.
class StoreNodeGateway {
  /// The federating hub whose registry this gateway maintains.
  final OmnyStoreHub store;

  /// The OmnyHub service nodes connect to. Register it with an `OmnyHub`.
  ///
  /// `late` because its lifecycle hooks close over `this`, which does not
  /// exist until the field initialisers have run.
  late final NodeGateway service;

  /// Vets registrations. When `null`, a node serves exactly what it declares.
  ///
  /// Leaving it `null` is only safe when the control endpoint is itself
  /// protected — by an authenticator on the OmnyHub route, by a private
  /// network, or by mutual TLS. An open endpoint with no policy lets any peer
  /// claim any organization.
  final NodeAdmissionPolicy? admissionPolicy;

  /// Bytes requested per relay chunk from nodes.
  final int chunkBytes;

  /// Structured logging.
  final Logger logger;

  final Map<String, RemoteNodeStoreProvider> _providers = {};

  /// Creates a gateway feeding [store].
  StoreNodeGateway({
    required this.store,
    this.admissionPolicy,
    this.chunkBytes = StoreProtocol.defaultChunkBytes,
    this.logger = const NoopLogger(),
    String mount = '/_node',
    String name = 'omnystore-nodes',
    Duration heartbeatInterval = const Duration(seconds: 10),
    Duration heartbeatTimeout = const Duration(seconds: 30),
  }) {
    service = NodeGateway(
      name: name,
      mount: mount,
      heartbeatInterval: heartbeatInterval,
      heartbeatTimeout: heartbeatTimeout,
      logger: logger,
      onRegister: _onRegister,
      onHeartbeat: _onHeartbeat,
      onNotify: _onNotify,
      onDisconnect: _onDisconnect,
      onTimeout: _onTimeout,
      // A node that drops is removed from the registry outright rather than
      // retained as offline: the hub is not the system of record for a node's
      // catalogue, and keeping a dead provider in the routing table would make
      // every lookup pay a failing round-trip.
      retainNodes: false,
    );
  }

  /// The nodes currently registered as storage providers.
  List<ProviderDescriptor> get nodes =>
      _providers.values.map((p) => p.descriptor).toList();

  /// Admits a node: checks the protocol version, applies the admission policy,
  /// and registers a provider proxy for it.
  Future<Map<String, dynamic>> _onRegister(
    NodeDescriptor descriptor,
    Map<String, dynamic> payload,
    Principal? principal,
  ) async {
    final nodeId = descriptor.id.value;

    final protocolVersion = Json.optInt(payload, StoreProtocol.versionKey, 0)!;
    if (protocolVersion != StoreProtocol.version) {
      // Refusing outright beats admitting a peer that will misinterpret every
      // payload: a version mismatch is an operator error with a clear fix.
      throw ValidationException(
        'Storage node $nodeId speaks protocol version $protocolVersion; this '
        'hub speaks ${StoreProtocol.version}. Upgrade the node or the hub.',
      );
    }

    final raw = payload[StoreProtocol.descriptorKey];
    if (raw == null) {
      throw ValidationException(
        'Storage node $nodeId did not send a provider descriptor',
      );
    }
    var provider = ProviderDescriptor.fromJson(
      Json.asObject(raw, 'provider descriptor'),
    );

    final policy = admissionPolicy;
    if (policy != null) {
      final allowed = await policy(nodeId, provider.organizations, principal);
      final refused = provider.organizations.difference(allowed);
      if (allowed.isEmpty) {
        throw UnauthorizedException(
          'Storage node $nodeId is not permitted to serve any organization',
        );
      }
      if (refused.isNotEmpty) {
        logger.warn(
          'Storage node organizations refused',
          context: {'node': nodeId, 'refused': refused.join(',')},
        );
      }
      provider = provider.copyWith(organizations: allowed);
    }

    // A node never gets to be a catch-all: that is reserved for the hub's own
    // provider, so attaching a node cannot silently capture organizations it
    // was never given.
    provider = provider.copyWith(
      servesAll: false,
      status: ProviderStatus.online,
      lastSeenAt: store.clock.now(),
    );

    final proxy = RemoteNodeStoreProvider(
      descriptor: provider,
      chunkBytes: chunkBytes,
      invoke: (action, payloadIn) async {
        final response = await service.request(
          descriptor.id,
          action,
          payload: payloadIn,
        );
        if (!response.ok) {
          // A transport-level failure, distinct from the store-level errors the
          // RPC server encodes into its payload.
          throw ValidationException(
            'Storage node $nodeId failed to handle $action: '
            '${response.error ?? 'unknown error'}',
          );
        }
        return response.payload;
      },
    );

    _providers[nodeId] = proxy;
    store.addProvider(proxy);

    return {
      StoreProtocol.versionKey: StoreProtocol.version,
      'organizations': provider.organizations.toList()..sort(),
    };
  }

  /// Refreshes a provider's descriptor from the heartbeat it rides on.
  void _onHeartbeat(RegisteredNode node, Heartbeat beat) =>
      _refresh(node.id, beat.payload);

  /// Applies an out-of-band descriptor push — how a node makes a drain take
  /// effect immediately rather than at the next heartbeat.
  void _onNotify(
    String action,
    Map<String, dynamic> payload,
    RegisteredNode from,
  ) {
    if (action != StoreProtocol.describe) return;
    _refresh(from.id, payload);
  }

  void _refresh(NodeId id, Map<String, dynamic> payload) {
    final raw = payload[StoreProtocol.descriptorKey];
    if (raw == null) return;
    final proxy = _providers[id.value];
    if (proxy == null) return;
    try {
      final updated = ProviderDescriptor.fromJson(
        Json.asObject(raw, 'provider descriptor'),
      );
      proxy.updateDescriptor(
        updated.copyWith(
          // The hub owns the organization set — it applied the admission
          // policy — so a node cannot widen its own scope by heartbeating a
          // longer list.
          organizations: proxy.descriptor.organizations,
          servesAll: false,
          lastSeenAt: store.clock.now(),
        ),
      );
      // Re-register so the hub's registry emits an update event for anything
      // watching provider membership.
      store.providers.register(proxy);
    } on Object catch (e) {
      logger.warn(
        'Ignoring malformed descriptor from node',
        context: {'node': id.value, 'error': '$e'},
      );
    }
  }

  void _onDisconnect(RegisteredNode? node, Connection connection) {
    if (node == null) return;
    _drop(node.id.value, 'disconnected');
  }

  void _onTimeout(RegisteredNode node) => _drop(node.id.value, 'timed out');

  void _drop(String nodeId, String reason) {
    if (_providers.remove(nodeId) == null) return;
    store.removeProvider(nodeId);
    logger.warn(
      'Storage node left the federation',
      context: {'node': nodeId, 'reason': reason},
    );
  }
}
