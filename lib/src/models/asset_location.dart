import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

part 'asset_location.g.dart';

/// Where a replica of an asset's bytes stands.
enum ReplicaState {
  /// The replica has been planned but the bytes are not there yet.
  pending,

  /// The bytes are stored and verified; the replica can serve downloads.
  available,

  /// The replica could not be written, or failed verification. Kept rather than
  /// deleted so an operator can see *that* placement failed and why — a silent
  /// disappearance looks identical to "never attempted".
  failed,
}

/// Records that one provider holds the bytes of one asset.
///
/// This is the placement index that makes many-to-many organization↔node
/// federation work: an asset's record lives with its organization's catalogue,
/// while its *bytes* may sit on any subset of that organization's nodes. The
/// hub consults these rows to decide who can serve a download, and to know
/// whether a replication target still needs filling.
///
/// The pair ([assetId], [providerId]) is unique.
@immutable
@JsonSerializable(explicitToJson: true)
class AssetLocation {
  /// Stable, opaque identifier.
  final String id;

  /// The asset whose bytes these are.
  final String assetId;

  /// The provider holding them (a node id, or the hub's own provider id).
  final String providerId;

  /// The organization the asset belongs to, denormalised so the hub can find
  /// every placement for an organization without loading its assets.
  final String organizationId;

  /// The key the bytes are stored under on this provider.
  ///
  /// Usually identical across replicas, but not required to be: a provider
  /// backed by someone else's bucket may prefix keys differently.
  final String storageKey;

  /// The replica's state.
  final ReplicaState state;

  /// Bytes stored, for reconciling a replica against the asset record.
  final int sizeBytes;

  /// When the replica was created (UTC).
  final DateTime createdAt;

  /// When the replica last became [ReplicaState.available] (UTC).
  final DateTime? verifiedAt;

  /// Why the replica is [ReplicaState.failed], if it is.
  final String? error;

  /// Creates a placement record.
  const AssetLocation({
    required this.id,
    required this.assetId,
    required this.providerId,
    required this.organizationId,
    required this.storageKey,
    this.state = ReplicaState.pending,
    required this.sizeBytes,
    required this.createdAt,
    this.verifiedAt,
    this.error,
  });

  /// Whether this replica can serve a download right now.
  bool get isAvailable => state == ReplicaState.available;

  /// Returns a copy with the given fields replaced.
  AssetLocation copyWith({
    ReplicaState? state,
    int? sizeBytes,
    DateTime? verifiedAt,
    String? error,
  }) => AssetLocation(
    id: id,
    assetId: assetId,
    providerId: providerId,
    organizationId: organizationId,
    storageKey: storageKey,
    state: state ?? this.state,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    createdAt: createdAt,
    verifiedAt: verifiedAt ?? this.verifiedAt,
    // Cleared on a transition away from `failed`, so a recovered replica does
    // not keep reporting the error that no longer applies.
    error: (state ?? this.state) == ReplicaState.failed
        ? (error ?? this.error)
        : null,
  );

  /// Parses a placement record from a JSON map.
  factory AssetLocation.fromJson(Map<String, dynamic> json) =>
      _$AssetLocationFromJson(json);

  /// Serialises the placement record to a JSON map.
  Map<String, dynamic> toJson() => _$AssetLocationToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssetLocation &&
          other.id == id &&
          other.assetId == assetId &&
          other.providerId == providerId &&
          other.organizationId == organizationId &&
          other.storageKey == storageKey &&
          other.state == state &&
          other.sizeBytes == sizeBytes &&
          other.createdAt == createdAt &&
          other.verifiedAt == verifiedAt &&
          other.error == error;

  @override
  int get hashCode => Object.hash(
    id,
    assetId,
    providerId,
    organizationId,
    storageKey,
    state,
    sizeBytes,
    createdAt,
    verifiedAt,
    error,
  );

  @override
  String toString() => 'AssetLocation($assetId @ $providerId, ${state.name})';
}
