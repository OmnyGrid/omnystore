import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../utils/equality.dart';
import '../utils/version_codec.dart';

part 'release.g.dart';

/// A published version of a [Package], with its notes and its [Asset]s.
///
/// Releases are **immutable once published**: re-publishing `1.2.0` is a
/// `ConflictException`, not an update, because a client that already downloaded
/// it has no way to learn the bytes changed underneath it. What *can* change is
/// the metadata around it — notes, [yanked] — and that is what [copyWith]
/// exposes.
///
/// [channel] is derived from [version] rather than set independently, so the
/// two can never disagree. It is stored on the record anyway because channel is
/// the single most common query filter and re-deriving it per row on every
/// `latestBeta()` would be wasteful.
@immutable
@JsonSerializable(explicitToJson: true)
class Release {
  /// Stable, opaque identifier assigned at publication.
  final String id;

  /// The owning package's [Package.id].
  final String packageId;

  /// The owning organization's [Organization.id], denormalised for routing.
  final String organizationId;

  /// The semantic version (`1.1.0-beta.2`, `2.0.0+build5`).
  @VersionConverter()
  final Version version;

  /// The channel this release belongs to, derived from [version].
  final ReleaseChannel channel;

  /// Human-friendly release title, defaulting to the version string.
  final String title;

  /// Release notes / changelog, typically Markdown.
  final String? notes;

  /// The VCS tag or commit this release was built from.
  final String? tag;

  /// Whether the release is a draft: visible to publishers, never offered by
  /// `latest*` queries or the update service.
  final bool draft;

  /// Whether the release has been withdrawn.
  ///
  /// A yanked release stays downloadable — clients that already pinned it must
  /// keep working — but is excluded from every `latest*` query and never
  /// offered as an update. This is the safe way to retract a bad build; see
  /// [yankedReason].
  final bool yanked;

  /// Why the release was yanked, shown to clients that ask about it.
  final String? yankedReason;

  /// When the release record was created (UTC).
  final DateTime createdAt;

  /// When the release was published (UTC), or `null` while it is a [draft].
  final DateTime? publishedAt;

  /// Arbitrary application-defined key/value pairs.
  final Map<String, String> metadata;

  /// Creates a release. [channel] defaults to the one implied by [version];
  /// passing a different value is how a caller *reads* a stored record, not a
  /// way to override the derivation — `OmnyStore.publishRelease` always derives
  /// it.
  Release({
    required this.id,
    required this.packageId,
    required this.organizationId,
    required this.version,
    ReleaseChannel? channel,
    String? title,
    this.notes,
    this.tag,
    this.draft = false,
    this.yanked = false,
    this.yankedReason,
    required this.createdAt,
    this.publishedAt,
    Map<String, String> metadata = const {},
  }) : channel = channel ?? ReleaseChannel.forVersion(version),
       title = title ?? version.toString(),
       metadata = Map.unmodifiable(metadata);

  /// Whether this release may be offered to clients by `latest*` queries and
  /// the update service: published, not a draft, not yanked.
  bool get isOfferable => !draft && !yanked && publishedAt != null;

  /// Whether this release is a pre-release (`dev` or `beta`).
  bool get isPreRelease => channel != ReleaseChannel.release;

  /// Returns a copy with the mutable metadata fields replaced.
  ///
  /// [version], [packageId] and [id] are absent by design — see the class
  /// documentation on immutability.
  Release copyWith({
    String? title,
    String? notes,
    String? tag,
    bool? draft,
    bool? yanked,
    String? yankedReason,
    DateTime? publishedAt,
    Map<String, String>? metadata,
  }) => Release(
    id: id,
    packageId: packageId,
    organizationId: organizationId,
    version: version,
    channel: channel,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    tag: tag ?? this.tag,
    draft: draft ?? this.draft,
    yanked: yanked ?? this.yanked,
    // Cleared when un-yanking, so a re-instated release does not keep a stale
    // reason attached to it.
    yankedReason: (yanked ?? this.yanked)
        ? (yankedReason ?? this.yankedReason)
        : null,
    createdAt: createdAt,
    publishedAt: publishedAt ?? this.publishedAt,
    metadata: metadata ?? this.metadata,
  );

  /// Parses a release from a JSON map.
  factory Release.fromJson(Map<String, dynamic> json) =>
      _$ReleaseFromJson(json);

  /// Serialises the release to a JSON map.
  Map<String, dynamic> toJson() => _$ReleaseToJson(this);

  /// Orders releases by version, newest first — the order `listReleases`
  /// returns and `latest*` selects the head of.
  ///
  /// Uses [Versions.compare], so two builds of one version (`1.0.0+build1`,
  /// `1.0.0+build2`) order deterministically instead of comparing equal.
  static int compareNewestFirst(Release a, Release b) =>
      Versions.compare(b.version, a.version);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Release &&
          other.id == id &&
          other.packageId == packageId &&
          other.organizationId == organizationId &&
          other.version == version &&
          other.channel == channel &&
          other.title == title &&
          other.notes == notes &&
          other.tag == tag &&
          other.draft == draft &&
          other.yanked == yanked &&
          other.yankedReason == yankedReason &&
          other.createdAt == createdAt &&
          other.publishedAt == publishedAt &&
          Eq.maps(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    id,
    packageId,
    organizationId,
    version,
    channel,
    title,
    notes,
    tag,
    draft,
    yanked,
    yankedReason,
    createdAt,
    publishedAt,
    Eq.mapHash(metadata),
  );

  @override
  String toString() =>
      'Release($version, ${channel.name}, package: $packageId'
      '${yanked ? ', yanked' : ''}${draft ? ', draft' : ''})';
}
