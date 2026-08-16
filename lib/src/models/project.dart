import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../utils/equality.dart';

part 'project.g.dart';

/// A product or repository within an [Organization], grouping the packages
/// released together.
///
/// The middle tier exists so one organization can ship several independent
/// products, and so a product can publish several artifacts (a CLI, a daemon,
/// a library) that version and release as one unit.
@immutable
@JsonSerializable(explicitToJson: true)
class Project {
  /// Stable, opaque identifier assigned at creation.
  final String id;

  /// The owning organization's [Organization.id].
  final String organizationId;

  /// The URL-addressable name (`omnyagent`), unique within the organization.
  final String name;

  /// Human-friendly name for display.
  final String displayName;

  /// Free-text description.
  final String? description;

  /// Source repository URL.
  final String? repository;

  /// Homepage or documentation URL.
  final String? website;

  /// When the project was created (UTC).
  final DateTime createdAt;

  /// When the project was last modified (UTC).
  final DateTime updatedAt;

  /// Arbitrary application-defined key/value pairs.
  final Map<String, String> metadata;

  /// Creates a project. [metadata] is copied into an unmodifiable map.
  ///
  /// Prefer `OmnyStore.createProject`, which assigns the [id] and timestamps
  /// and validates [name] against its organization.
  Project({
    required this.id,
    required this.organizationId,
    required this.name,
    String? displayName,
    this.description,
    this.repository,
    this.website,
    required this.createdAt,
    required this.updatedAt,
    Map<String, String> metadata = const {},
  }) : displayName = displayName ?? name,
       metadata = Map.unmodifiable(metadata);

  /// Returns a copy with the given fields replaced. Identity fields ([id],
  /// [organizationId], [name], [createdAt]) cannot be changed.
  Project copyWith({
    String? displayName,
    String? description,
    String? repository,
    String? website,
    DateTime? updatedAt,
    Map<String, String>? metadata,
  }) => Project(
    id: id,
    organizationId: organizationId,
    name: name,
    displayName: displayName ?? this.displayName,
    description: description ?? this.description,
    repository: repository ?? this.repository,
    website: website ?? this.website,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    metadata: metadata ?? this.metadata,
  );

  /// Parses a project from a JSON map.
  factory Project.fromJson(Map<String, dynamic> json) =>
      _$ProjectFromJson(json);

  /// Serialises the project to a JSON map.
  Map<String, dynamic> toJson() => _$ProjectToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Project &&
          other.id == id &&
          other.organizationId == organizationId &&
          other.name == name &&
          other.displayName == displayName &&
          other.description == description &&
          other.repository == repository &&
          other.website == website &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          Eq.maps(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    id,
    organizationId,
    name,
    displayName,
    description,
    repository,
    website,
    createdAt,
    updatedAt,
    Eq.mapHash(metadata),
  );

  @override
  String toString() => 'Project($name, id: $id, org: $organizationId)';
}
