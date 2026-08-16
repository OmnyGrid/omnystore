import '../models/provider_descriptor.dart';
import '../services/omnystore.dart';
import '../services/omnystore_api.dart';

/// A participant that holds and serves releases for one or more organizations.
///
/// This is the federation primitive. A provider is a [descriptor] — who it is,
/// which organizations it serves, how its bytes are reached — paired with a
/// [store] that can actually answer registry operations for them. Two
/// implementations ship:
///
/// * [LocalStoreProvider] wraps an in-process [OmnyStore]. A **node** runs one
///   of these over its own repositories and object storage; a **hub** also runs
///   one when it hosts organizations itself, so a small deployment does not
///   need a separate node process beside it.
/// * `RemoteNodeStoreProvider` is the hub-side proxy for a connected node: the
///   same [OmnyStoreApi], with every call forwarded over the node's control
///   channel.
///
/// Because both expose [OmnyStoreApi], the hub federates them without knowing
/// which is which — the local case is not a special path through the routing
/// code, which is what keeps "hub with no nodes" and "hub with twelve nodes"
/// exercising the same logic.
abstract interface class StoreProvider {
  /// Stable identifier, unique within a hub.
  String get id;

  /// Who this provider is and what it serves. Refreshed as the node
  /// heartbeats, so capacity and liveness stay current.
  ProviderDescriptor get descriptor;

  /// The registry operations this provider can answer.
  OmnyStoreApi get store;

  /// Whether this provider can be read from right now.
  bool get isReadable => descriptor.isReadable;

  /// Whether this provider accepts new writes right now.
  bool get isWritable => descriptor.isWritable;

  /// Whether this provider serves [organization].
  bool serves(String organization) => descriptor.serves(organization);

  /// Releases the provider's resources.
  Future<void> close();
}

/// A [StoreProvider] backed by an in-process [OmnyStore].
///
/// Used both by a node — where it *is* the node's storage — and by a hub that
/// hosts organizations itself.
///
/// ```dart
/// final provider = LocalStoreProvider(
///   OmnyStore(
///     repositories: MemoryRepositories(),
///     storage: LocalObjectStorage('/var/lib/omnystore'),
///   ),
///   descriptor: ProviderDescriptor(
///     id: 'hub-local', kind: ProviderKind.hub, servesAll: true,
///   ),
/// );
/// ```
class LocalStoreProvider implements StoreProvider {
  @override
  final OmnyStore store;

  ProviderDescriptor _descriptor;

  /// Wraps [store], advertising it as [descriptor].
  LocalStoreProvider(this.store, {required ProviderDescriptor descriptor})
    : _descriptor = descriptor;

  /// Wraps [store], deriving the descriptor from the store's own configuration
  /// and its object-storage capabilities.
  static Future<LocalStoreProvider> describing(
    OmnyStore store, {
    ProviderKind kind = ProviderKind.hub,
    String? baseUrl,
    Map<String, String> labels = const {},
    int priority = 0,
    int? capacityBytes,
  }) async => LocalStoreProvider(
    store,
    descriptor: await store.describeProvider(
      kind: kind,
      baseUrl: baseUrl,
      labels: labels,
      priority: priority,
      capacityBytes: capacityBytes,
    ),
  );

  @override
  String get id => _descriptor.id;

  @override
  ProviderDescriptor get descriptor => _descriptor;

  @override
  bool get isReadable => _descriptor.isReadable;

  @override
  bool get isWritable => _descriptor.isWritable;

  @override
  bool serves(String organization) => _descriptor.serves(organization);

  /// Replaces the advertised descriptor — used to bind new organizations, mark
  /// the provider draining, or refresh reported usage.
  void updateDescriptor(ProviderDescriptor descriptor) =>
      _descriptor = descriptor;

  /// Refreshes the reported storage usage from the underlying object store.
  Future<void> refreshUsage() async {
    _descriptor = _descriptor.copyWith(
      usedBytes: await store.storage.usedBytes(),
      lastSeenAt: store.clock.now(),
    );
  }

  @override
  Future<void> close() => store.close();
}
