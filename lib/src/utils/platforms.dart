import 'dart:io';

/// The `os-arch` platform tokens OmnyStore tags artifacts with, and how to
/// work out which one the current process is.
///
/// Every artifact carries a [Asset.platform] like `macos-arm64`, and the update
/// service matches it exactly — a client is never handed a build for another
/// architecture. That only helps if a client can say what it *is*, which is
/// what [current] answers.
///
/// The convention is `<os>-<arch>`, lower-case:
///
/// | os | arch |
/// |---|---|
/// | `linux`, `macos`, `windows`, `android`, `ios`, `fuchsia` | `x64`, `arm64`, `arm`, `x86`, `riscv64` |
///
/// Uses `dart:io`, so it is not part of the web client barrel. A browser has
/// no meaningful architecture; pass [web] explicitly there.
class Platforms {
  const Platforms._();

  /// The token for a browser, where there is no native architecture.
  static const String web = 'web';

  /// The token used when the architecture cannot be determined.
  ///
  /// Deliberately *not* a guess. An artifact tagged with the wrong
  /// architecture fails at launch on the user's machine, which is worse than
  /// failing to match at all.
  static const String unknown = 'unknown';

  static String? _cached;

  /// The platform this process is running on, e.g. `macos-arm64`.
  ///
  /// Computed once and cached; it cannot change while the process runs.
  ///
  /// ```dart
  /// final update = await client.checkForUpdates(
  ///   packageReference: 'omnyagent',
  ///   currentVersion: Version.parse(myVersion),
  ///   platform: Platforms.current,
  /// );
  /// ```
  static String get current => _cached ??= detect();

  /// Works out the platform from [version] and [operatingSystem], defaulting
  /// to this process's own.
  ///
  /// Taking both as parameters keeps the parsing testable against the strings
  /// other SDKs and machines produce, rather than only the one this machine
  /// happens to report.
  ///
  /// `Platform.version` ends with the target triple in quotes —
  /// `3.13.0 (stable) (…) on "macos_arm64"` — which is the only place the Dart
  /// VM exposes the CPU architecture. When it cannot be parsed the OS is still
  /// reported, paired with [unknown].
  static String detect({String? version, String? operatingSystem}) {
    final os = normalizeOs(operatingSystem ?? Platform.operatingSystem);
    final raw = version ?? Platform.version;

    final match = RegExp(r'"([a-z0-9_]+)"\s*$').firstMatch(raw.trim());
    final triple = match?.group(1);
    if (triple == null) return '$os-$unknown';

    // The triple is `<os>_<arch>`, but the arch half can itself contain an
    // underscore, so it is matched as a suffix rather than split on the last
    // separator.
    final split = _splitArch(triple);
    if (split == null) return '$os-$unknown';

    return '$os-${normalizeArch(split.arch)}';
  }

  /// Maps an operating-system name onto the token OmnyStore uses.
  ///
  /// Accepts the aliases other toolchains emit — `darwin` from Apple's tools,
  /// `win32` from Node — so a platform string copied from another build system
  /// lines up instead of silently never matching.
  static String normalizeOs(String os) => switch (os.trim().toLowerCase()) {
    'macos' || 'darwin' || 'osx' || 'mac' => 'macos',
    'windows' || 'win32' || 'win' => 'windows',
    'linux' => 'linux',
    'android' => 'android',
    'ios' => 'ios',
    'fuchsia' => 'fuchsia',
    final other => other,
  };

  /// Every architecture spelling recognised, longest first.
  ///
  /// Order matters: `x86_64` has to be tried before `x86`, or a token ending
  /// in it would be split down the middle. Some of these contain a separator
  /// themselves, which is exactly why splitting a platform token on its last
  /// `-`/`_` is not good enough — see [_splitArch].
  static const List<String> _archAliases = [
    'x86_64',
    'aarch64',
    'riscv64',
    'riscv32',
    'armv7l',
    'armv7',
    'amd64',
    'arm64',
    'i686',
    'i386',
    'ia32',
    'x64',
    'x86',
    'arm',
  ];

  /// Maps a CPU architecture name onto the token OmnyStore uses.
  static String normalizeArch(String arch) =>
      switch (arch.trim().toLowerCase()) {
        'x64' || 'x86_64' || 'amd64' => 'x64',
        'arm64' || 'aarch64' => 'arm64',
        'ia32' || 'x86' || 'i386' || 'i686' => 'x86',
        'arm' || 'armv7' || 'armv7l' => 'arm',
        'riscv64' => 'riscv64',
        'riscv32' => 'riscv32',
        final other => other,
      };

  /// Normalises a whole `os-arch` token, so `Darwin-aarch64`, `osx-x86_64` and
  /// `macos-arm64` are each recognised for what they are.
  ///
  /// A token with no architecture is treated as a bare OS, which is what a
  /// value like `linux` alone means in practice.
  static String normalize(String platform) {
    final trimmed = platform.trim().toLowerCase();
    if (trimmed.isEmpty) return unknown;
    if (trimmed == web) return web;

    final split = _splitArch(trimmed);
    if (split == null) return normalizeOs(trimmed);

    return '${normalizeOs(split.os)}-${normalizeArch(split.arch)}';
  }

  /// Splits [platform] into its OS and architecture parts, or `null` when it
  /// carries no architecture.
  ///
  /// Matches a known architecture suffix rather than splitting on the last
  /// separator, because several spellings contain one: `osx-x86_64` splits
  /// after `osx`, not after `x86`.
  static ({String os, String arch})? _splitArch(String platform) {
    for (final alias in _archAliases) {
      for (final separator in const ['-', '_']) {
        final suffix = '$separator$alias';
        if (platform.endsWith(suffix) && platform.length > suffix.length) {
          return (
            os: platform.substring(0, platform.length - suffix.length),
            arch: alias,
          );
        }
      }
    }

    // An architecture this version does not know about still has to survive,
    // so fall back to the last separator — `freebsd-riscv128` should not lose
    // its arch just because it is unrecognised.
    final index = platform.lastIndexOf(RegExp('[-_]'));
    if (index <= 0 || index == platform.length - 1) return null;
    return (
      os: platform.substring(0, index),
      arch: platform.substring(index + 1),
    );
  }

  /// Whether an artifact tagged [assetPlatform] can run on [clientPlatform].
  ///
  /// Only an exact match after normalisation. There is deliberately no
  /// compatibility fallback — an `x64` build *can* run on Apple Silicon under
  /// Rosetta, but choosing that silently would ship the slower binary to every
  /// Apple Silicon user forever, and hide a missing native build from whoever
  /// publishes it. A publisher who wants that fallback ships an artifact with
  /// no platform, which `UpdateResolver` already prefers second.
  static bool matches(String assetPlatform, String clientPlatform) =>
      normalize(assetPlatform) == normalize(clientPlatform);
}
