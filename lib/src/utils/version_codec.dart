import 'package:json_annotation/json_annotation.dart';
import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../exceptions/omnystore_exception.dart';

/// Serialises a [Version] as its canonical string form.
///
/// Registered on the model fields that hold versions so `json_serializable`
/// emits `"1.1.0-beta.2"` rather than an object, and round-trips build
/// metadata (`2.0.0+build5`) unchanged.
class VersionConverter implements JsonConverter<Version, String> {
  /// Creates the converter.
  const VersionConverter();

  @override
  Version fromJson(String json) => Versions.parse(json);

  @override
  String toJson(Version object) => object.toString();
}

/// Serialises a nullable [Version].
class NullableVersionConverter implements JsonConverter<Version?, String?> {
  /// Creates the converter.
  const NullableVersionConverter();

  @override
  Version? fromJson(String? json) =>
      json == null || json.isEmpty ? null : Versions.parse(json);

  @override
  String? toJson(Version? object) => object?.toString();
}

/// Serialises a [VersionConstraint] as its string form (`'^1.2.0'`, `'any'`).
class VersionConstraintConverter
    implements JsonConverter<VersionConstraint, String> {
  /// Creates the converter.
  const VersionConstraintConverter();

  @override
  VersionConstraint fromJson(String json) => Versions.parseConstraint(json);

  @override
  String toJson(VersionConstraint object) => object.toString();
}

/// Version helpers that fail with OmnyStore's own typed exceptions instead of
/// `pub_semver`'s [FormatException].
///
/// The difference matters at the API and CLI boundaries: a malformed version in
/// a request body should render as a `400` with
/// [ErrorCodes.validationError], not escape as an unmapped `FormatException`.
class Versions {
  const Versions._();

  /// Parses [input] as a semantic version.
  ///
  /// Throws [ValidationException] if it is not a valid version. Accepts a
  /// leading `v` (`v1.2.3`), which is what git tags and CI variables carry.
  ///
  /// ```dart
  /// Versions.parse('1.0.0');        // 1.0.0
  /// Versions.parse('v2.0.0+build5') // 2.0.0+build5
  /// ```
  static Version parse(String input, {String field = 'version'}) {
    final version = tryParse(input);
    if (version != null) return version;
    throw ValidationException(
      "Invalid semantic version '$input': expected MAJOR.MINOR.PATCH with an "
      'optional -prerelease and +build (e.g. 1.1.0-beta.2)',
      field: field,
    );
  }

  /// Parses [input], returning `null` if it is not a valid version.
  static Version? tryParse(String input) {
    final trimmed = input.trim();
    final normalized = trimmed.startsWith('v') || trimmed.startsWith('V')
        ? trimmed.substring(1)
        : trimmed;
    if (normalized.isEmpty) return null;
    try {
      return Version.parse(normalized);
    } on FormatException {
      return null;
    }
  }

  /// Parses [input] as a version constraint (`'^1.2.0'`, `'>=1.0.0 <2.0.0'`,
  /// `'any'`).
  ///
  /// Throws [ValidationException] if it is not a valid constraint.
  static VersionConstraint parseConstraint(
    String input, {
    String field = 'constraint',
  }) {
    try {
      return VersionConstraint.parse(input.trim());
    } on FormatException catch (e) {
      throw ValidationException(
        "Invalid version constraint '$input': ${e.message}",
        field: field,
      );
    }
  }

  /// Compares [a] and [b] for "which release is newer", with build metadata as
  /// the final tie-breaker.
  ///
  /// The semver *specification* excludes build metadata from precedence, so a
  /// strict implementation orders `1.0.0+build1` and `1.0.0+build2` as equal.
  /// That is right for dependency resolution and wrong for a release registry,
  /// where two builds of one version are distinct artifacts and "the latest"
  /// has to be a single deterministic answer rather than whichever the store
  /// happened to yield first.
  ///
  /// `pub_semver` already breaks that tie, so this mostly delegates — but the
  /// tie-break is applied explicitly here so the ordering is guaranteed by
  /// OmnyStore's own contract rather than by a dependency's choice, and stays
  /// correct if that choice ever changes.
  static int compare(Version a, Version b) {
    final byPrecedence = a.compareTo(b);
    if (byPrecedence != 0) return byPrecedence;
    return a.build.join('.').compareTo(b.build.join('.'));
  }

  /// Whether [version] carries the pre-release tag [channel] stamps.
  ///
  /// Equivalent to `ReleaseChannel.forVersion(version) == channel`, spelled out
  /// so callers reading channel-filtering code do not have to follow the
  /// derivation.
  static bool matchesChannel(Version version, ReleaseChannel channel) =>
      ReleaseChannel.forVersion(version) == channel;

  /// Stamps [version] with [channel]'s pre-release tag and [build] number,
  /// replacing any pre-release tag already present.
  ///
  /// Used by CI to derive the channel-specific version for a build from a base
  /// version, so the same pipeline produces `1.2.0-dev.41`, `1.2.0-beta.3` and
  /// `1.2.0` without string surgery at each call site.
  ///
  /// ```dart
  /// Versions.stamp(Version.parse('1.2.0'), ReleaseChannel.beta, 3);
  /// // => 1.2.0-beta.3
  /// ```
  static Version stamp(Version version, ReleaseChannel channel, [int? build]) {
    final tag = channel.preReleaseTag;
    final preRelease = tag == null
        ? ''
        : build == null
        ? '-$tag'
        : '-$tag.$build';
    final metadata = version.build.isEmpty ? '' : '+${version.build.join('.')}';
    return Version.parse(
      '${version.major}.${version.minor}.${version.patch}$preRelease$metadata',
    );
  }

  /// The version with the pre-release tag and build metadata stripped — the
  /// stable version a pre-release is working towards.
  ///
  /// ```dart
  /// Versions.baseOf(Version.parse('1.2.0-beta.3+ci.7')); // 1.2.0
  /// ```
  static Version baseOf(Version version) =>
      Version(version.major, version.minor, version.patch);
}
