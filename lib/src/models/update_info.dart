import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../utils/version_codec.dart';
import 'asset.dart';
import 'release.dart';

part 'update_info.g.dart';

/// The answer to "is there a newer version for me?".
///
/// Returned by `UpdateChecker.checkForUpdates` and by
/// `GET /api/v1/packages/{id}/updates`. It deliberately carries the whole
/// [release] and the matching [asset] rather than just a version string: a
/// client that has decided to update should not need a second and third
/// round-trip to find out what to download.
///
/// [updateAvailable] is `false` — not an error — when the client is already
/// current or is *ahead* of the registry (a developer running a local build).
/// Downgrades are never offered.
@immutable
@JsonSerializable(explicitToJson: true)
class UpdateInfo {
  /// The version the client reported running.
  @VersionConverter()
  final Version currentVersion;

  /// The newest offerable version on [channel], or `null` if the package has no
  /// offerable release there at all.
  @NullableVersionConverter()
  final Version? latestVersion;

  /// Whether [latestVersion] is strictly newer than [currentVersion].
  final bool updateAvailable;

  /// The channel the check ran against.
  final ReleaseChannel channel;

  /// The release [latestVersion] belongs to, or `null` if there is none.
  final Release? release;

  /// The asset matching the client's platform within [release], or `null` if
  /// the client did not name a platform or no asset matches it.
  ///
  /// A `null` [asset] alongside a non-null [release] is meaningful: an update
  /// exists, but not one this client can install.
  final Asset? asset;

  /// The package the check ran against, denormalised so a client can render the
  /// prompt without another lookup.
  final String packageName;

  /// Notes to show the user, defaulting to the release's own notes.
  final String? notes;

  /// Creates an update answer.
  ///
  /// Prefer `UpdateChecker.checkForUpdates`, which derives [updateAvailable]
  /// from the version comparison rather than trusting a caller-supplied flag.
  const UpdateInfo({
    required this.currentVersion,
    this.latestVersion,
    required this.updateAvailable,
    required this.channel,
    this.release,
    this.asset,
    required this.packageName,
    this.notes,
  });

  /// An answer meaning "you are current" (or ahead) on [channel].
  factory UpdateInfo.upToDate({
    required Version currentVersion,
    required ReleaseChannel channel,
    required String packageName,
    Version? latestVersion,
    Release? release,
  }) => UpdateInfo(
    currentVersion: currentVersion,
    latestVersion: latestVersion,
    updateAvailable: false,
    channel: channel,
    release: release,
    packageName: packageName,
  );

  /// Whether an update exists *and* ships an artifact this client can install.
  ///
  /// The distinction matters for the prompt shown to the user: "update
  /// available" with nothing to download is a broken experience, so a client
  /// should gate its download button on this rather than on [updateAvailable].
  bool get isInstallable => updateAvailable && asset != null;

  /// Parses an update answer from a JSON map.
  factory UpdateInfo.fromJson(Map<String, dynamic> json) =>
      _$UpdateInfoFromJson(json);

  /// Serialises the update answer to a JSON map.
  Map<String, dynamic> toJson() => _$UpdateInfoToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UpdateInfo &&
          other.currentVersion == currentVersion &&
          other.latestVersion == latestVersion &&
          other.updateAvailable == updateAvailable &&
          other.channel == channel &&
          other.release == release &&
          other.asset == asset &&
          other.packageName == packageName &&
          other.notes == notes;

  @override
  int get hashCode => Object.hash(
    currentVersion,
    latestVersion,
    updateAvailable,
    channel,
    release,
    asset,
    packageName,
    notes,
  );

  @override
  String toString() => updateAvailable
      ? 'UpdateInfo($packageName $currentVersion -> $latestVersion '
            '(${channel.name}))'
      : 'UpdateInfo($packageName $currentVersion is current (${channel.name}))';
}
