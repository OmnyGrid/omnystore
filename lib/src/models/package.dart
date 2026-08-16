import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../channels/release_channel.dart';
import '../utils/equality.dart';

part 'package.g.dart';

/// A distributable artifact line within a [Project] — the thing that has
/// versions.
///
/// A package is what a client asks about (`omnystore check-update --package
/// omnyagent`) and what releases hang off. One project may publish several:
/// `omnyagent` (the daemon), `omnyagent-cli`, `omnyagent-sdk`.
@immutable
@JsonSerializable(explicitToJson: true)
class Package {
  /// Stable, opaque identifier assigned at creation.
  final String id;

  /// The owning project's [Project.id].
  final String projectId;

  /// The owning organization's [Organization.id], denormalised onto the package
  /// so a release lookup can be routed to the right node without first
  /// resolving the project.
  final String organizationId;

  /// The URL-addressable name (`omnyagent`), unique within the project.
  final String name;

  /// Human-friendly name for display.
  final String displayName;

  /// Free-text description.
  final String? description;

  /// The channel clients are offered by default when they do not name one.
  ///
  /// Defaults to [ReleaseChannel.release]: a caller who does not opt in to
  /// pre-releases must never be handed one.
  final ReleaseChannel defaultChannel;

  /// Platforms this package publishes artifacts for (`linux-x64`,
  /// `macos-arm64`), advertised so a client can tell whether an update exists
  /// for it before downloading anything.
  final List<String> platforms;

  /// When the package was created (UTC).
  final DateTime createdAt;

  /// When the package was last modified (UTC).
  final DateTime updatedAt;

  /// Arbitrary application-defined key/value pairs.
  final Map<String, String> metadata;

  /// Creates a package. Collections are copied into unmodifiable views.
  ///
  /// Prefer `OmnyStore.createPackage`, which assigns the [id] and timestamps
  /// and validates [name] against its project.
  Package({
    required this.id,
    required this.projectId,
    required this.organizationId,
    required this.name,
    String? displayName,
    this.description,
    this.defaultChannel = ReleaseChannel.release,
    List<String> platforms = const [],
    required this.createdAt,
    required this.updatedAt,
    Map<String, String> metadata = const {},
  }) : displayName = displayName ?? name,
       platforms = List.unmodifiable(platforms),
       metadata = Map.unmodifiable(metadata);

  /// Returns a copy with the given fields replaced. Identity fields ([id],
  /// [projectId], [organizationId], [name], [createdAt]) cannot be changed.
  Package copyWith({
    String? displayName,
    String? description,
    ReleaseChannel? defaultChannel,
    List<String>? platforms,
    DateTime? updatedAt,
    Map<String, String>? metadata,
  }) => Package(
    id: id,
    projectId: projectId,
    organizationId: organizationId,
    name: name,
    displayName: displayName ?? this.displayName,
    description: description ?? this.description,
    defaultChannel: defaultChannel ?? this.defaultChannel,
    platforms: platforms ?? this.platforms,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    metadata: metadata ?? this.metadata,
  );

  /// Parses a package from a JSON map.
  factory Package.fromJson(Map<String, dynamic> json) =>
      _$PackageFromJson(json);

  /// Serialises the package to a JSON map.
  Map<String, dynamic> toJson() => _$PackageToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Package &&
          other.id == id &&
          other.projectId == projectId &&
          other.organizationId == organizationId &&
          other.name == name &&
          other.displayName == displayName &&
          other.description == description &&
          other.defaultChannel == defaultChannel &&
          Eq.lists(other.platforms, platforms) &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          Eq.maps(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    id,
    projectId,
    organizationId,
    name,
    displayName,
    description,
    defaultChannel,
    Eq.listHash(platforms),
    createdAt,
    updatedAt,
    Eq.mapHash(metadata),
  );

  @override
  String toString() => 'Package($name, id: $id, project: $projectId)';
}
