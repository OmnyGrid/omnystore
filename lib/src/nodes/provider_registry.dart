import 'dart:async';

import '../exceptions/omnystore_exception.dart';
import '../models/provider_descriptor.dart';
import 'store_provider.dart';

/// How a provider's membership changed.
enum ProviderEventKind {
  /// A provider registered.
  registered,

  /// A provider's descriptor changed (organizations bound, capacity, status).
  updated,

  /// A provider was removed or went offline.
  removed,
}

/// A change to the set of providers a hub knows about.
class ProviderEvent {
  /// What happened.
  final ProviderEventKind kind;

  /// The provider it happened to.
  final ProviderDescriptor descriptor;

  /// Creates an event.
  const ProviderEvent(this.kind, this.descriptor);

  @override
  String toString() => 'ProviderEvent(${kind.name}, ${descriptor.id})';
}

/// The hub's directory of storage providers, and the routing table that maps
/// organizations onto them.
///
/// **Organizations and providers are many to many.** One organization's
/// releases may be spread over — or replicated across — several nodes, and one
/// node may serve several organizations. Both directions are ordinary here:
/// [providersFor] returns every provider serving an organization, and a
/// provider's own [ProviderDescriptor.organizations] lists everything it
/// carries.
///
/// Two sources decide who serves what, and they compose:
///
/// * **Node-declared.** A node advertises its organizations at registration.
///   This is the common case: the node operator knows what they are hosting.
/// * **Hub-bound.** [bind] adds an organization to a provider from the hub
///   side, for a deployment where the hub is the system of record and nodes
///   are interchangeable capacity.
///
/// A provider with [ProviderDescriptor.servesAll] is a **catch-all**, and is
/// only selected when no organization-specific provider is eligible. That is
/// what lets a single-server deployment work with no configuration, and lets
/// adding a node for `acme` later take over `acme`'s traffic without touching
/// the hub's settings.
class ProviderRegistry {
  final Map<String, StoreProvider> _providers = {};
  final Map<String, Set<String>> _hubBound = {};
  final StreamController<ProviderEvent> _events =
      StreamController<ProviderEvent>.broadcast();

  /// Creates an empty registry.
  ProviderRegistry();

  /// Membership changes, for a hub that wants to react to a node arriving or
  /// leaving (re-replicate, alert, refresh a cache).
  Stream<ProviderEvent> get events => _events.stream;

  /// Every registered provider, ordered by id.
  List<StoreProvider> get all =>
      _providers.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  /// Descriptors of every registered provider.
  List<ProviderDescriptor> get descriptors =>
      all.map((p) => p.descriptor).toList();

  /// How many providers are registered.
  int get length => _providers.length;

  /// Every organization name any provider serves explicitly, sorted.
  ///
  /// Catch-all providers contribute nothing here: they serve organizations
  /// they have never been told about, so there is no finite set to report.
  List<String> get boundOrganizations {
    final names = <String>{};
    for (final provider in _providers.values) {
      names.addAll(provider.descriptor.organizations);
      names.addAll(_hubBound[provider.id] ?? const <String>{});
    }
    return names.toList()..sort();
  }

  /// Registers [provider], replacing any provider already using its id.
  ///
  /// Replacement rather than rejection is deliberate: a node that reconnects
  /// after a network blip re-registers under the same id, and refusing it would
  /// strand its organizations until the stale entry timed out.
  void register(StoreProvider provider) {
    final existing = _providers[provider.id];
    _providers[provider.id] = provider;
    _emit(
      existing == null
          ? ProviderEventKind.registered
          : ProviderEventKind.updated,
      provider.descriptor,
    );
  }

  /// The provider with [id], or `null`.
  StoreProvider? byId(String id) => _providers[id];

  /// The provider with [id], or throws [ValidationException].
  StoreProvider requireById(String id) {
    final provider = _providers[id];
    if (provider == null) {
      throw ValidationException(
        "No storage provider '$id' is registered",
        field: 'providerId',
      );
    }
    return provider;
  }

  /// Removes the provider with [id]. Returns whether one was removed.
  bool remove(String id) {
    final removed = _providers.remove(id);
    _hubBound.remove(id);
    if (removed == null) return false;
    _emit(ProviderEventKind.removed, removed.descriptor);
    return true;
  }

  /// Binds [organization] to the provider with [providerId] from the hub side.
  ///
  /// Additive to whatever the provider itself declared; use it when the hub,
  /// not the node, decides placement.
  void bind(String organization, String providerId) {
    requireById(providerId);
    (_hubBound[providerId] ??= <String>{}).add(organization);
    _emit(ProviderEventKind.updated, _providers[providerId]!.descriptor);
  }

  /// Removes a hub-side binding. Returns whether one was removed.
  ///
  /// Cannot unbind an organization the provider declares itself — that is the
  /// node's own statement about what it holds, and the hub overriding it would
  /// make the node's data unreachable while it is still storing it.
  bool unbind(String organization, String providerId) {
    final removed = _hubBound[providerId]?.remove(organization) ?? false;
    if (removed) {
      _emit(ProviderEventKind.updated, _providers[providerId]!.descriptor);
    }
    return removed;
  }

  /// Whether the provider with [providerId] serves [organization], counting
  /// both its own declaration and any hub-side binding.
  bool serves(String providerId, String organization) {
    final provider = _providers[providerId];
    if (provider == null) return false;
    return provider.serves(organization) ||
        (_hubBound[providerId]?.contains(organization) ?? false);
  }

  /// The providers serving [organization], best-first.
  ///
  /// Organization-specific providers come first, ordered by
  /// [ProviderDescriptor.comparePreferred] — highest priority, then most free
  /// space, then id. Catch-all providers follow, and are therefore only reached
  /// when no specific provider is eligible.
  ///
  /// [readable] and [writable] narrow the result to providers in the right
  /// state; a draining node still serves reads but takes no writes.
  List<StoreProvider> providersFor(
    String organization, {
    bool readable = true,
    bool writable = false,
    Map<String, String> labels = const {},
  }) {
    final specific = <StoreProvider>[];
    final catchAll = <StoreProvider>[];

    for (final provider in _providers.values) {
      if (readable && !provider.isReadable) continue;
      if (writable && !provider.isWritable) continue;
      if (labels.isNotEmpty && !provider.descriptor.matchesLabels(labels)) {
        continue;
      }
      final explicit =
          provider.descriptor.organizations.contains(organization) ||
          (_hubBound[provider.id]?.contains(organization) ?? false);
      if (explicit) {
        specific.add(provider);
      } else if (provider.descriptor.servesAll) {
        catchAll.add(provider);
      }
    }

    int byPreference(StoreProvider a, StoreProvider b) =>
        ProviderDescriptor.comparePreferred(a.descriptor, b.descriptor);
    specific.sort(byPreference);
    catchAll.sort(byPreference);
    return [...specific, ...catchAll];
  }

  /// The provider that should take a **write** for [organization].
  ///
  /// Writes go to exactly one provider so that ids stay unique and
  /// unambiguous: two providers each minting their own id for "the same" new
  /// release would leave the hub unable to say which one a client meant.
  /// Replication of the resulting *bytes* is a separate, explicit step.
  ///
  /// Throws [StorageException] when nothing is eligible, naming the
  /// organization — the actionable failure for an operator who has not attached
  /// a node yet.
  StoreProvider primaryFor(
    String organization, {
    Map<String, String> labels = const {},
  }) {
    final candidates = providersFor(
      organization,
      writable: true,
      labels: labels,
    );
    if (candidates.isEmpty) {
      final anyReadable = providersFor(organization).isNotEmpty;
      throw StorageException(
        anyReadable
            ? "Every provider for organization '$organization' is draining or "
                  'read-only, so it cannot accept writes'
            : "No storage provider serves organization '$organization'. "
                  'Attach a node that serves it, bind an existing provider to '
                  'it, or give the hub a catch-all local provider.',
      );
    }
    return candidates.first;
  }

  /// Every provider that could hold bytes for [organization], best-first —
  /// the candidate set a replication policy chooses from.
  List<StoreProvider> replicationCandidatesFor(
    String organization, {
    Map<String, String> labels = const {},
  }) => providersFor(organization, writable: true, labels: labels);

  /// Every provider, whether or not it serves a particular organization,
  /// best-first. Used for id-based lookups, where the owning organization is
  /// not known until the record is found.
  List<StoreProvider> get readable {
    final providers = _providers.values.where((p) => p.isReadable).toList()
      ..sort(
        (a, b) =>
            ProviderDescriptor.comparePreferred(a.descriptor, b.descriptor),
      );
    return providers;
  }

  /// Closes the registry's event stream. Does not close the providers, which
  /// belong to whoever created them.
  Future<void> close() => _events.close();

  void _emit(ProviderEventKind kind, ProviderDescriptor descriptor) {
    if (!_events.isClosed) _events.add(ProviderEvent(kind, descriptor));
  }
}
