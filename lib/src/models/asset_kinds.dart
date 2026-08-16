import 'asset.dart';

/// The conventional values of [Asset.kind], and the rules that read them.
///
/// `kind` is free-form on purpose — a release can carry anything — but three
/// parts of the system have to agree on what a given value *means*: the update
/// service, which must never offer a signature file as the thing to install;
/// the CLI's `--kind` filter; and anyone reading a listing. Writing the
/// vocabulary down once is what keeps those three from drifting.
///
/// Untagged artifacts are not left uninterpreted. A release published before
/// `kind` existed, or by a pipeline that does not set it, still carries
/// `agent.tar.gz.sha256` next to `agent.tar.gz`, and treating that as an
/// installable artifact would be wrong in a way the user never asked for. So
/// the auxiliary kinds are also inferred from the filename; the installable
/// ones are not, because guessing `installer` from an extension would be a
/// guess with consequences.
class AssetKinds {
  const AssetKinds._();

  /// A ready-to-run installer: `.dmg`, `.msi`, `.deb`.
  static const String installer = 'installer';

  /// A compressed build the client unpacks itself.
  static const String archive = 'archive';

  /// A checksum manifest.
  static const String checksums = 'checksums';

  /// A detached signature.
  static const String signature = 'signature';

  /// A software bill of materials.
  static const String sbom = 'sbom';

  /// Kinds that accompany a release rather than being the thing installed.
  ///
  /// `checksum` is accepted alongside `checksums` because both spellings are
  /// in the wild and a publisher should not have to guess which one the
  /// update service recognises.
  static const Set<String> auxiliary = {checksums, 'checksum', signature, sbom};

  /// Filename endings that identify an auxiliary artifact when [Asset.kind] is
  /// not set.
  static const Map<String, String> _suffixes = {
    '.sha256': checksums,
    '.sha512': checksums,
    '.md5': checksums,
    '.sig': signature,
    '.asc': signature,
    '.sbom.json': sbom,
  };

  /// Whole filenames that identify a checksum manifest when untagged.
  static const Set<String> _checksumFilenames = {
    'checksums.txt',
    'sha256sums.txt',
  };

  /// The effective kind of [asset]: its [Asset.kind] when set, otherwise the
  /// auxiliary kind its filename implies, otherwise `null`.
  ///
  /// ```dart
  /// AssetKinds.of(Asset(name: 'agent.tar.gz.sha256', ...)); // => 'checksums'
  /// AssetKinds.of(Asset(name: 'agent.tar.gz', ...));        // => null
  /// ```
  static String? of(Asset asset) {
    final tagged = asset.kind;
    if (tagged != null && tagged.isNotEmpty) return tagged;

    final name = asset.name.toLowerCase();
    if (_checksumFilenames.contains(name)) return checksums;
    for (final entry in _suffixes.entries) {
      if (name.endsWith(entry.key)) return entry.value;
    }
    return null;
  }

  /// Whether [asset] accompanies the release rather than being installable.
  ///
  /// A checksum file or a signature is never *the* download, even when it is
  /// the only artifact matching a platform.
  static bool isAuxiliary(Asset asset) => auxiliary.contains(of(asset));

  /// Whether [asset] is of [kind], by its tag or by the filename convention.
  static bool matches(Asset asset, String kind) => of(asset) == kind;

  /// Orders installable artifacts by how ready-to-use they are: an installer
  /// beats an archive, which beats an untagged artifact, which beats anything
  /// else. Ties break on name so the choice is stable across calls.
  static int byPreference(Asset a, Asset b) {
    int rank(Asset asset) => switch (of(asset)) {
      installer => 0,
      archive => 1,
      null => 2,
      _ => 3,
    };
    final byKind = rank(a).compareTo(rank(b));
    return byKind != 0 ? byKind : a.name.compareTo(b.name);
  }
}
