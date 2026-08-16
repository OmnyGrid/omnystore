import 'package:pub_semver/pub_semver.dart';

import '../exceptions/omnystore_exception.dart';

/// The distribution channel a release belongs to.
///
/// A channel is *derived from the version itself* rather than stored
/// independently, so a version string and its channel can never disagree:
///
/// | Version            | Channel  |
/// |--------------------|----------|
/// | `1.0.0`            | release  |
/// | `2.0.0+build5`     | release  |
/// | `1.1.0-beta.2`     | beta     |
/// | `1.1.0-dev.3`      | dev      |
///
/// Build metadata (`+build5`) never affects the channel — semver says it is not
/// part of a version's identity for ordering, and a stable build is stable
/// however it was produced.
enum ReleaseChannel {
  /// Internal development builds (`1.1.0-dev.3`). The least stable channel;
  /// typically produced by CI on every merge.
  dev,

  /// Public testing releases (`1.1.0-beta.2`). Shipped to opt-in testers.
  beta,

  /// Stable production releases (`1.0.0`). No pre-release tag.
  release;

  /// The channel implied by [version]'s pre-release tag.
  ///
  /// A version with no pre-release tag is [release]. Otherwise the *first*
  /// pre-release identifier selects the channel: `dev` → [dev], `beta` →
  /// [beta]. Any other tag (`1.0.0-rc.1`, `1.0.0-alpha`) is treated as [dev],
  /// on the principle that an unrecognised pre-release is the least stable
  /// thing it could be — never something that would ship to production.
  ///
  /// ```dart
  /// ReleaseChannel.forVersion(Version.parse('1.0.0'));        // release
  /// ReleaseChannel.forVersion(Version.parse('1.0.0-beta.1')); // beta
  /// ReleaseChannel.forVersion(Version.parse('1.0.0-rc.1'));   // dev
  /// ```
  static ReleaseChannel forVersion(Version version) {
    if (version.preRelease.isEmpty) return release;
    final tag = '${version.preRelease.first}'.toLowerCase();
    return switch (tag) {
      'beta' => beta,
      'dev' => dev,
      _ => dev,
    };
  }

  /// Parses a channel [name] (case-insensitive), throwing [ValidationException]
  /// for an unknown value.
  ///
  /// Accepts the aliases `stable` and `prod`/`production` for [release], which
  /// is what users type in practice.
  static ReleaseChannel parse(String name) {
    final channel = tryParse(name);
    if (channel != null) return channel;
    throw ValidationException(
      "Unknown channel '$name': expected one of "
      '${values.map((c) => c.name).join(', ')}',
      field: 'channel',
    );
  }

  /// Parses a channel [name] (case-insensitive), returning `null` for an
  /// unknown value.
  static ReleaseChannel? tryParse(String name) =>
      switch (name.trim().toLowerCase()) {
        'dev' || 'development' => dev,
        'beta' || 'test' || 'testing' => beta,
        'release' || 'stable' || 'prod' || 'production' => release,
        _ => null,
      };

  /// Channels ordered from least to most stable — the order in which a client
  /// on this channel is willing to accept releases (see [accepts]).
  static const List<ReleaseChannel> byStability = [dev, beta, release];

  /// How stable this channel is: `0` for [dev], `2` for [release].
  int get stability => byStability.indexOf(this);

  /// Whether a client subscribed to this channel should be offered a release on
  /// [other].
  ///
  /// Channels are *inclusive downward in stability*: a `dev` subscriber gets
  /// dev, beta and stable builds; a `beta` subscriber gets beta and stable; a
  /// `release` subscriber gets only stable. This is what makes promotion work —
  /// publishing `1.2.0` stable immediately reaches every subscriber, without
  /// re-publishing it on each channel.
  ///
  /// ```dart
  /// ReleaseChannel.beta.accepts(ReleaseChannel.release); // true
  /// ReleaseChannel.beta.accepts(ReleaseChannel.dev);     // false
  /// ```
  bool accepts(ReleaseChannel other) => other.stability >= stability;

  /// The pre-release identifier this channel stamps onto a version
  /// (`'beta'`, `'dev'`), or `null` for [release].
  String? get preReleaseTag => switch (this) {
    dev => 'dev',
    beta => 'beta',
    release => null,
  };

  /// A human-readable label for CLI and API output.
  String get label => switch (this) {
    dev => 'dev',
    beta => 'beta',
    release => 'release',
  };
}
