import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../models/asset.dart';
import '../models/release.dart';
import '../models/update_info.dart';
import '../utils/version_codec.dart';

/// The decision logic behind every update check, kept in one pure function so
/// the embedded store, the hub, the REST endpoint and the standalone
/// `UpdateChecker` cannot drift apart on the question that matters most:
/// *should this client be told to update?*
///
/// Getting this wrong is expensive in both directions. Offering a downgrade
/// bricks a fleet; failing to offer a real update leaves known-bad versions
/// running. So the rules are written down once, here, and tested directly.
class UpdateResolver {
  const UpdateResolver._();

  /// Builds the answer for a client on [currentVersion] and [channel], given
  /// the newest release the registry would offer it.
  ///
  /// The rules:
  ///
  /// * No offerable release at all → not an error, `updateAvailable: false`.
  ///   A package with only drafts is a real state, not a failure.
  /// * [latest] not strictly newer than [currentVersion] → `false`. Equal
  ///   versions are current; an *older* registry version means the client is
  ///   ahead (a developer on a local build), and offering a downgrade would be
  ///   worse than saying nothing.
  /// * Otherwise → `true`, carrying the release and the asset matching
  ///   [platform].
  ///
  /// Comparison uses [Versions.compare], so `1.0.0+build2` is correctly newer
  /// than `1.0.0+build1` — semver calls those equal, which would strand a fleet
  /// on a broken build of the same version.
  static UpdateInfo resolve({
    required String packageName,
    required Version currentVersion,
    required ReleaseChannel channel,
    Release? latest,
    List<Asset> assets = const [],
    String? platform,
  }) {
    if (latest == null) {
      return UpdateInfo.upToDate(
        currentVersion: currentVersion,
        channel: channel,
        packageName: packageName,
      );
    }

    final isNewer = Versions.compare(latest.version, currentVersion) > 0;
    if (!isNewer) {
      return UpdateInfo.upToDate(
        currentVersion: currentVersion,
        channel: channel,
        packageName: packageName,
        latestVersion: latest.version,
        release: latest,
      );
    }

    return UpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latest.version,
      updateAvailable: true,
      channel: channel,
      release: latest,
      asset: selectAsset(assets, platform: platform),
      packageName: packageName,
      notes: latest.notes,
    );
  }

  /// Picks the asset a client on [platform] should download, or `null`.
  ///
  /// * With a [platform], only assets for that platform are eligible, plus
  ///   platform-independent ones as a fallback. A `macos-arm64` client is never
  ///   handed a Linux binary just because it was the only artifact present.
  /// * Auxiliary artifacts — checksum files, signatures — are never selected as
  ///   *the* download, even when they are the only match; they accompany a
  ///   release, they are not it.
  /// * Among equals, an `installer` beats an `archive`, and ties break on name
  ///   so the choice is deterministic across calls.
  static Asset? selectAsset(List<Asset> assets, {String? platform}) {
    final installable = assets.where((a) => !_isAuxiliary(a)).toList();
    if (installable.isEmpty) return null;

    if (platform == null) {
      // No platform declared: only a single unambiguous candidate is safe to
      // offer. Guessing among several platform builds would hand half of them
      // the wrong binary.
      final portable = installable.where((a) => a.platform == null).toList();
      final candidates = portable.isNotEmpty ? portable : installable;
      if (candidates.length > 1) return null;
      return candidates.first;
    }

    final exact = installable.where((a) => a.platform == platform).toList();
    final eligible = exact.isNotEmpty
        ? exact
        : installable.where((a) => a.platform == null).toList();
    if (eligible.isEmpty) return null;

    eligible.sort(_preferInstallers);
    return eligible.first;
  }

  /// Whether an asset accompanies the release rather than being installable.
  static bool _isAuxiliary(Asset asset) {
    const auxiliaryKinds = {'checksums', 'checksum', 'signature', 'sbom'};
    if (asset.kind != null && auxiliaryKinds.contains(asset.kind)) return true;
    const auxiliarySuffixes = [
      '.sha256',
      '.sha512',
      '.md5',
      '.sig',
      '.asc',
      '.sbom.json',
    ];
    final name = asset.name.toLowerCase();
    return auxiliarySuffixes.any(name.endsWith) ||
        name == 'checksums.txt' ||
        name == 'sha256sums.txt';
  }

  static int _preferInstallers(Asset a, Asset b) {
    int rank(Asset asset) => switch (asset.kind) {
      'installer' => 0,
      'archive' => 1,
      null => 2,
      _ => 3,
    };
    final byKind = rank(a).compareTo(rank(b));
    return byKind != 0 ? byKind : a.name.compareTo(b.name);
  }
}
