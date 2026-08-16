import 'dart:convert';

import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

/// One release, many architectures.
///
/// A [Release] is a version; the artifacts hang off it as [Asset]s, each tagged
/// with the `os-arch` platform it was built for. That is how `macos-x64`
/// (Intel) and `macos-arm64` (Apple Silicon) coexist under a single `1.2.0`,
/// and how an updater is handed the one binary it can actually run.
///
/// The rule that matters: a client is **never** given a build for another
/// architecture. Offering an Intel binary to an Apple Silicon machine — or the
/// reverse — is worse than offering nothing, because it fails after the
/// download, at launch, on the user's machine.
void main() {
  late TestStore harness;
  late OmnyStore store;

  /// The five platforms a desktop agent typically ships.
  const platforms = [
    'linux-x64',
    'linux-arm64',
    'macos-x64',
    'macos-arm64',
    'windows-x64',
  ];

  setUp(() async {
    harness = TestStore();
    store = harness.store;
    await harness.seedPackage(platforms: platforms);
  });

  tearDown(() => harness.close());

  /// Publishes [version] with one artifact per platform in [only].
  Future<Release> publishFor(
    String version, {
    List<String> only = platforms,
  }) async {
    final release = await store.publishRelease(
      packageReference: 'omnyagent',
      version: Version.parse(version),
      notes: 'Release $version.',
    );
    for (final platform in only) {
      await store.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-$platform.tar.gz',
        data: Stream.value(utf8.encode('$version for $platform')),
        platform: platform,
        kind: 'archive',
      );
    }
    return release;
  }

  group('one release carrying every architecture', () {
    test('holds an artifact per platform', () async {
      final release = await publishFor('1.0.0');

      final assets = await store.listAssets(release.id);
      expect(assets, hasLength(platforms.length));
      expect(assets.map((a) => a.platform).toSet(), platforms.toSet());
      // Each is stored separately, so they never collide.
      expect(
        assets.map((a) => a.storageKey).toSet(),
        hasLength(platforms.length),
      );
    });

    test('the package advertises what it builds for', () async {
      final package = await store.resolvePackage('omnyagent');

      // A client can tell whether a build exists for it before downloading
      // anything.
      expect(package.platforms, platforms);
    });
  });

  group('an updater is offered its own architecture', () {
    setUp(() async {
      await publishFor('1.0.0');
      await publishFor('1.1.0');
    });

    test('macOS Intel and Apple Silicon each get their own build', () async {
      final intel = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'macos-x64',
      );
      final appleSilicon = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'macos-arm64',
      );

      expect(intel.asset!.name, 'omnyagent-macos-x64.tar.gz');
      expect(appleSilicon.asset!.name, 'omnyagent-macos-arm64.tar.gz');
      expect(intel.asset!.id, isNot(appleSilicon.asset!.id));

      // Same release, different artifact.
      expect(intel.latestVersion.toString(), '1.1.0');
      expect(appleSilicon.latestVersion.toString(), '1.1.0');
      expect(intel.release!.id, appleSilicon.release!.id);
    });

    test('every platform resolves to its own build', () async {
      for (final platform in platforms) {
        final info = await store.checkForUpdates(
          packageReference: 'omnyagent',
          currentVersion: Version.parse('1.0.0'),
          platform: platform,
        );

        expect(info.isInstallable, isTrue, reason: platform);
        expect(
          info.asset!.platform,
          platform,
          reason: 'a $platform client must not be handed another build',
        );
        expect(
          await readAsString((await store.openAsset(info.asset!.id)).stream),
          '1.1.0 for $platform',
        );
      }
    });
  });

  group('an architecture with no build', () {
    test('reports the update but nothing installable', () async {
      await publishFor('1.0.0');
      // 1.1.0 shipped without the Apple Silicon build — a real situation when
      // one runner in the matrix fails.
      await publishFor(
        '1.1.0',
        only: const ['linux-x64', 'macos-x64', 'windows-x64'],
      );

      final appleSilicon = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'macos-arm64',
      );

      expect(appleSilicon.updateAvailable, isTrue);
      // Crucially not the Intel build. A download button gated on
      // `updateAvailable` would offer a binary that fails at launch.
      expect(appleSilicon.asset, isNull);
      expect(appleSilicon.isInstallable, isFalse);

      // The platforms that did ship are unaffected.
      final intel = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'macos-x64',
      );
      expect(intel.isInstallable, isTrue);
    });

    test('an unknown platform is never guessed at', () async {
      await publishFor('1.0.0');
      await publishFor('1.1.0');

      final exotic = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        platform: 'freebsd-riscv64',
      );

      expect(exotic.updateAvailable, isTrue);
      expect(exotic.asset, isNull);
    });
  });

  group('a portable artifact', () {
    test(
      'is the fallback when no architecture-specific build matches',
      () async {
        await publishFor('1.0.0');
        final release = await store.publishRelease(
          packageReference: 'omnyagent',
          version: Version.parse('1.1.0'),
        );
        await store.attachAsset(
          releaseId: release.id,
          name: 'omnyagent-macos-x64.tar.gz',
          data: Stream.value(utf8.encode('intel')),
          platform: 'macos-x64',
        );
        // A platform-independent build, e.g. a JAR or a script bundle.
        await store.attachAsset(
          releaseId: release.id,
          name: 'omnyagent-any.jar',
          data: Stream.value(utf8.encode('portable')),
        );

        // Apple Silicon has no native build, so the portable one is offered…
        final appleSilicon = await store.checkForUpdates(
          packageReference: 'omnyagent',
          currentVersion: Version.parse('1.0.0'),
          platform: 'macos-arm64',
        );
        expect(appleSilicon.asset!.name, 'omnyagent-any.jar');

        // …while Intel still gets its native one, which is the better choice.
        final intel = await store.checkForUpdates(
          packageReference: 'omnyagent',
          currentVersion: Version.parse('1.0.0'),
          platform: 'macos-x64',
        );
        expect(intel.asset!.name, 'omnyagent-macos-x64.tar.gz');
      },
    );
  });

  group('several artifacts for one architecture', () {
    test('prefers an installer over an archive, deterministically', () async {
      final release = await store.publishRelease(
        packageReference: 'omnyagent',
        version: Version.parse('1.0.0'),
      );
      await store.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-macos-arm64.tar.gz',
        data: Stream.value(utf8.encode('archive')),
        platform: 'macos-arm64',
        kind: 'archive',
      );
      await store.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-macos-arm64.dmg',
        data: Stream.value(utf8.encode('installer')),
        platform: 'macos-arm64',
        kind: 'installer',
      );
      // Auxiliary files sit alongside and must never be offered as the
      // download.
      await store.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-macos-arm64.tar.gz.sha256',
        data: Stream.value(utf8.encode('digest')),
        platform: 'macos-arm64',
        kind: 'checksums',
      );

      final info = await store.checkForUpdates(
        packageReference: 'omnyagent',
        currentVersion: Version.parse('0.9.0'),
        platform: 'macos-arm64',
      );

      expect(info.asset!.name, 'omnyagent-macos-arm64.dmg');
    });
  });

  group('promotion carries every architecture across', () {
    test('a beta promoted to stable keeps all five builds', () async {
      final beta = await publishFor('1.2.0-beta.1');

      final promoted = await store.promoteRelease(
        beta.id,
        ReleaseChannel.release,
      );

      final assets = await store.listAssets(promoted.id);
      expect(assets, hasLength(platforms.length));
      expect(assets.map((a) => a.platform).toSet(), platforms.toSet());
      // Byte-for-byte the same artifacts, verified on copy.
      for (final asset in assets) {
        expect(
          await readAsString((await store.openAsset(asset.id)).stream),
          '1.2.0-beta.1 for ${asset.platform}',
        );
      }
    });
  });
}
