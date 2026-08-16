import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../utils/equality.dart';

part 'provider_descriptor.g.dart';

/// What kind of participant a storage provider is.
enum ProviderKind {
  /// The hub serving its own locally-hosted organizations, so a small
  /// deployment does not need a separate node process beside it.
  hub,

  /// A node that dialled the hub and serves one or more organizations.
  node,
}

/// How a provider's bytes reach a client.
enum DataPlaneMode {
  /// The provider's object store issues presigned URLs (S3, GCS). The hub
  /// redirects the client straight at the bucket; no bytes traverse the hub or
  /// the node. Fastest, and the only mode that scales to large artifacts
  /// without provisioning bandwidth on the registry itself.
  presigned,

  /// The provider is directly reachable at [ProviderDescriptor.baseUrl]. The
  /// hub redirects the client to the provider's own HTTP endpoint, carrying a
  /// short-lived signed ticket.
  direct,

  /// The provider is not reachable from the client — typically a node behind
  /// NAT, which is why it dialled the hub in the first place. Bytes are relayed
  /// through the hub over the node control channel in chunks.
  ///
  /// Correct everywhere and slower than the alternatives: every byte crosses
  /// the node→hub WebSocket and then the hub→client connection, and the control
  /// channel frames them as base64. Prefer [direct] or [presigned] whenever the
  /// topology allows it.
  relay,
}

/// The liveness of a provider, as tracked by the hub.
enum ProviderStatus {
  /// Registered and heartbeating.
  online,

  /// Disconnected, timed out, or explicitly drained.
  offline,

  /// Online but not accepting new writes — used to retire a node without
  /// interrupting the downloads it is still serving.
  draining,
}

/// The public description of a storage provider: who it is, which
/// organizations it serves, how its bytes are reached, and how much room it
/// has left.
///
/// This is what a node announces on registration and what
/// `GET /api/v1/providers` returns. Organizations and providers are **many to
/// many**: one organization's releases may be spread over (or replicated
/// across) several nodes, and one node may serve several organizations. That
/// relation lives in [organizations].
@immutable
@JsonSerializable(explicitToJson: true)
class ProviderDescriptor {
  /// Stable identifier, unique across the hub. For a node this is its
  /// OmnyHub `NodeId`.
  final String id;

  /// Whether this is the hub itself or a connected node.
  final ProviderKind kind;

  /// The names of the organizations this provider serves.
  ///
  /// Empty means "none" — a provider that has not been bound to any
  /// organization stores nothing and is never selected. Use [servesAll] for a
  /// catch-all provider.
  final Set<String> organizations;

  /// Whether this provider serves *every* organization, present and future.
  ///
  /// The single-server default: the hub's own provider sets this so a
  /// deployment with no nodes works without binding each organization by hand.
  /// A catch-all is only selected when no organization-specific provider is
  /// eligible, so adding a node for `acme` later takes over `acme`'s traffic
  /// without reconfiguring the hub.
  final bool servesAll;

  /// How this provider's bytes reach a client.
  final DataPlaneMode dataPlane;

  /// The provider's publicly reachable base URL, for [DataPlaneMode.direct].
  final String? baseUrl;

  /// Key/value labels used for placement filtering (`region=eu`, `tier=cold`).
  final Map<String, String> labels;

  /// Selection weight: higher wins when several providers are eligible. Equal
  /// weights are broken deterministically by [id], so placement never depends
  /// on registration order.
  final int priority;

  /// Total capacity in bytes, or `null` if the provider does not report one.
  final int? capacityBytes;

  /// Bytes currently stored, or `null` if the provider does not report it.
  final int? usedBytes;

  /// The provider agent's version string.
  final String agentVersion;

  /// Liveness, maintained hub-side from the control connection.
  final ProviderStatus status;

  /// When the hub last heard from this provider (UTC).
  final DateTime? lastSeenAt;

  /// Arbitrary application-defined key/value pairs.
  final Map<String, String> metadata;

  /// Creates a descriptor. Collections are copied into unmodifiable views.
  ProviderDescriptor({
    required this.id,
    this.kind = ProviderKind.node,
    Set<String> organizations = const {},
    this.servesAll = false,
    this.dataPlane = DataPlaneMode.relay,
    this.baseUrl,
    Map<String, String> labels = const {},
    this.priority = 0,
    this.capacityBytes,
    this.usedBytes,
    this.agentVersion = 'unknown',
    this.status = ProviderStatus.online,
    this.lastSeenAt,
    Map<String, String> metadata = const {},
  }) : organizations = Set.unmodifiable(organizations),
       labels = Map.unmodifiable(labels),
       metadata = Map.unmodifiable(metadata);

  /// Whether this provider serves the organization named [organization].
  bool serves(String organization) =>
      servesAll || organizations.contains(organization);

  /// Whether this provider can be read from right now.
  bool get isReadable => status != ProviderStatus.offline;

  /// Whether this provider can accept new writes right now.
  ///
  /// A draining provider keeps serving downloads but takes no new uploads,
  /// which is how a node is retired without breaking in-flight clients.
  bool get isWritable => status == ProviderStatus.online;

  /// Free capacity in bytes, or `null` if the provider does not report
  /// capacity. Never negative.
  int? get freeBytes {
    final capacity = capacityBytes;
    if (capacity == null) return null;
    final used = usedBytes ?? 0;
    return used >= capacity ? 0 : capacity - used;
  }

  /// Whether this provider has room for [bytes] more.
  ///
  /// A provider that does not report capacity is assumed to have room: an
  /// unreported limit is not a limit of zero, and refusing to place there would
  /// make the common case (a directory on a big disk) unusable.
  bool hasRoomFor(int bytes) {
    final free = freeBytes;
    return free == null || free >= bytes;
  }

  /// Whether this provider's labels contain every entry in [filter].
  bool matchesLabels(Map<String, String> filter) {
    for (final entry in filter.entries) {
      if (labels[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Returns a copy with the given fields replaced.
  ProviderDescriptor copyWith({
    Set<String>? organizations,
    bool? servesAll,
    DataPlaneMode? dataPlane,
    String? baseUrl,
    Map<String, String>? labels,
    int? priority,
    int? capacityBytes,
    int? usedBytes,
    String? agentVersion,
    ProviderStatus? status,
    DateTime? lastSeenAt,
    Map<String, String>? metadata,
  }) => ProviderDescriptor(
    id: id,
    kind: kind,
    organizations: organizations ?? this.organizations,
    servesAll: servesAll ?? this.servesAll,
    dataPlane: dataPlane ?? this.dataPlane,
    baseUrl: baseUrl ?? this.baseUrl,
    labels: labels ?? this.labels,
    priority: priority ?? this.priority,
    capacityBytes: capacityBytes ?? this.capacityBytes,
    usedBytes: usedBytes ?? this.usedBytes,
    agentVersion: agentVersion ?? this.agentVersion,
    status: status ?? this.status,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    metadata: metadata ?? this.metadata,
  );

  /// Parses a descriptor from a JSON map.
  factory ProviderDescriptor.fromJson(Map<String, dynamic> json) =>
      _$ProviderDescriptorFromJson(json);

  /// Serialises the descriptor to a JSON map.
  Map<String, dynamic> toJson() => _$ProviderDescriptorToJson(this);

  /// Orders providers best-first for placement: highest [priority], then most
  /// free space, then [id] so the result is stable.
  static int comparePreferred(ProviderDescriptor a, ProviderDescriptor b) {
    final byPriority = b.priority.compareTo(a.priority);
    if (byPriority != 0) return byPriority;
    final byFree = (b.freeBytes ?? -1).compareTo(a.freeBytes ?? -1);
    if (byFree != 0) return byFree;
    return a.id.compareTo(b.id);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProviderDescriptor &&
          other.id == id &&
          other.kind == kind &&
          Eq.sets(other.organizations, organizations) &&
          other.servesAll == servesAll &&
          other.dataPlane == dataPlane &&
          other.baseUrl == baseUrl &&
          Eq.maps(other.labels, labels) &&
          other.priority == priority &&
          other.capacityBytes == capacityBytes &&
          other.usedBytes == usedBytes &&
          other.agentVersion == agentVersion &&
          other.status == status &&
          other.lastSeenAt == lastSeenAt &&
          Eq.maps(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    Eq.setHash(organizations),
    servesAll,
    dataPlane,
    baseUrl,
    Eq.mapHash(labels),
    priority,
    capacityBytes,
    usedBytes,
    agentVersion,
    status,
    lastSeenAt,
    Eq.mapHash(metadata),
  );

  @override
  String toString() =>
      'ProviderDescriptor($id, ${kind.name}, ${status.name}, '
      'orgs: ${servesAll ? '*' : organizations.join(',')})';
}
