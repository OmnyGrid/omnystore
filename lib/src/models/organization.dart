import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../utils/equality.dart';

part 'organization.g.dart';

/// The top-level tenant: a company, a team, or an open-source org that owns
/// projects.
///
/// In a Hub/Node deployment the organization is also the **unit of federation**
/// — a node advertises the organizations it serves, and the hub routes every
/// request for `acme`'s projects to whichever provider owns `acme`. That makes
/// [name] a routing key, which is why it is validated and immutable.
@immutable
@JsonSerializable(explicitToJson: true)
class Organization {
  /// Stable, opaque identifier assigned at creation. Never reused.
  final String id;

  /// The URL-addressable name (`acme`), unique across the registry and used as
  /// the federation routing key. Validated by `Names.require`.
  final String name;

  /// Human-friendly name for display (`Acme Corporation`).
  final String displayName;

  /// Free-text description.
  final String? description;

  /// Homepage or documentation URL.
  final String? website;

  /// When the organization was created (UTC).
  final DateTime createdAt;

  /// When the organization was last modified (UTC).
  final DateTime updatedAt;

  /// Arbitrary application-defined key/value pairs.
  final Map<String, String> metadata;

  /// Creates an organization. [metadata] is copied into an unmodifiable map.
  ///
  /// Prefer `OmnyStore.createOrganization`, which assigns the [id] and
  /// timestamps and validates [name].
  Organization({
    required this.id,
    required this.name,
    String? displayName,
    this.description,
    this.website,
    required this.createdAt,
    required this.updatedAt,
    Map<String, String> metadata = const {},
  }) : displayName = displayName ?? name,
       metadata = Map.unmodifiable(metadata);

  /// Returns a copy with the given fields replaced.
  ///
  /// [id], [name] and [createdAt] are deliberately absent: renaming an
  /// organization would break every URL and every node routing entry that
  /// points at it, so it is a create-and-migrate operation, not an edit.
  Organization copyWith({
    String? displayName,
    String? description,
    String? website,
    DateTime? updatedAt,
    Map<String, String>? metadata,
  }) => Organization(
    id: id,
    name: name,
    displayName: displayName ?? this.displayName,
    description: description ?? this.description,
    website: website ?? this.website,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    metadata: metadata ?? this.metadata,
  );

  /// Parses an organization from a JSON map.
  factory Organization.fromJson(Map<String, dynamic> json) =>
      _$OrganizationFromJson(json);

  /// Serialises the organization to a JSON map.
  Map<String, dynamic> toJson() => _$OrganizationToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Organization &&
          other.id == id &&
          other.name == name &&
          other.displayName == displayName &&
          other.description == description &&
          other.website == website &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          Eq.maps(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    displayName,
    description,
    website,
    createdAt,
    updatedAt,
    Eq.mapHash(metadata),
  );

  @override
  String toString() => 'Organization($name, id: $id)';
}
