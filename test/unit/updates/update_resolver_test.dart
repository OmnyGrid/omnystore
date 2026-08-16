import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

/// An asset record with only the fields selection depends on.
Asset assetNamed(
  String name, {
  String? platform,
  String? kind,
  String id = 'asset',
}) => Asset(
  id: id,
  releaseId: 'rel-1',
  packageId: 'pkg-1',
  organizationId: 'org-1',
  name: name,
  storageKey: 'k/$name',
  sizeBytes: 1,
  sha256: 'x',
  platform: platform,
  kind: kind,
  createdAt: DateTime.utc(2026),
);

Release releaseAt(String version, {String? notes}) => Release(
  id: 'rel-1',
  packageId: 'pkg-1',
  organizationId: 'org-1',
  version: Version.parse(version),
  notes: notes,
  createdAt: DateTime.utc(2026),
  publishedAt: DateTime.utc(2026),
);

void main() {
  group('UpdateResolver.resolve', () {
    test('offers a strictly newer release', () {
      final info = UpdateResolver.resolve(
        packageName: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        channel: ReleaseChannel.release,
        latest: releaseAt('1.1.0', notes: 'Fixes a crash.'),
        assets: [assetNamed('agent.tar.gz')],
      );

      expect(info.updateAvailable, isTrue);
      expect(info.latestVersion.toString(), '1.1.0');
      expect(info.notes, 'Fixes a crash.');
      expect(info.asset!.name, 'agent.tar.gz');
      expect(info.isInstallable, isTrue);
    });

    test('reports current when the versions are equal', () {
      final info = UpdateResolver.resolve(
        packageName: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        channel: ReleaseChannel.release,
        latest: releaseAt('1.0.0'),
      );

      expect(info.updateAvailable, isFalse);
      expect(info.latestVersion.toString(), '1.0.0');
      expect(info.release, isNotNull);
    });

    test('never offers a downgrade to a client that is ahead', () {
      // A developer on a local build must not be pushed backwards.
      final info = UpdateResolver.resolve(
        packageName: 'omnyagent',
        currentVersion: Version.parse('2.0.0-dev.1'),
        channel: ReleaseChannel.dev,
        latest: releaseAt('1.9.0'),
      );

      expect(info.updateAvailable, isFalse);
    });

    test('treats no offerable release as a state, not an error', () {
      final info = UpdateResolver.resolve(
        packageName: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        channel: ReleaseChannel.release,
        latest: null,
      );

      expect(info.updateAvailable, isFalse);
      expect(info.latestVersion, isNull);
      expect(info.release, isNull);
    });

    test('distinguishes two builds of the same version', () {
      // Strict semver calls these equal, which would strand a fleet on a
      // broken build.
      final info = UpdateResolver.resolve(
        packageName: 'omnyagent',
        currentVersion: Version.parse('1.0.0+build1'),
        channel: ReleaseChannel.release,
        latest: releaseAt('1.0.0+build2'),
      );

      expect(info.updateAvailable, isTrue);
    });

    test('flags an update with nothing installable for this platform', () {
      final info = UpdateResolver.resolve(
        packageName: 'omnyagent',
        currentVersion: Version.parse('1.0.0'),
        channel: ReleaseChannel.release,
        latest: releaseAt('1.1.0'),
        assets: [assetNamed('agent-linux.tar.gz', platform: 'linux-x64')],
        platform: 'macos-arm64',
      );

      expect(info.updateAvailable, isTrue);
      expect(info.asset, isNull);
      // The distinction a download button must gate on.
      expect(info.isInstallable, isFalse);
    });
  });

  group('UpdateResolver.selectAsset', () {
    test('picks the artifact matching the platform', () {
      final asset = UpdateResolver.selectAsset([
        assetNamed('agent-linux.tar.gz', platform: 'linux-x64', id: 'a'),
        assetNamed('agent-macos.tar.gz', platform: 'macos-arm64', id: 'b'),
      ], platform: 'macos-arm64');

      expect(asset!.id, 'b');
    });

    test('falls back to a platform-independent artifact', () {
      final asset = UpdateResolver.selectAsset([
        assetNamed('agent-linux.tar.gz', platform: 'linux-x64', id: 'a'),
        assetNamed('agent-any.jar', id: 'b'),
      ], platform: 'macos-arm64');

      expect(asset!.id, 'b');
    });

    test('never hands a platform build to the wrong platform', () {
      final asset = UpdateResolver.selectAsset([
        assetNamed('agent-linux.tar.gz', platform: 'linux-x64'),
      ], platform: 'macos-arm64');

      expect(asset, isNull);
    });

    test('refuses to guess among several platform builds', () {
      // With no platform declared, guessing would hand half the fleet the
      // wrong binary.
      final asset = UpdateResolver.selectAsset([
        assetNamed('agent-linux.tar.gz', platform: 'linux-x64'),
        assetNamed('agent-macos.tar.gz', platform: 'macos-arm64'),
      ]);

      expect(asset, isNull);
    });

    test('picks a single unambiguous artifact with no platform declared', () {
      final asset = UpdateResolver.selectAsset([assetNamed('agent.jar')]);
      expect(asset!.name, 'agent.jar');
    });

    test('never selects an auxiliary artifact as the download', () {
      // A checksum file accompanies a release; it is not the release.
      for (final name in [
        'agent.tar.gz.sha256',
        'agent.tar.gz.sig',
        'agent.tar.gz.asc',
        'checksums.txt',
        'SHA256SUMS.txt',
        'agent.sbom.json',
      ]) {
        expect(
          UpdateResolver.selectAsset([assetNamed(name)]),
          isNull,
          reason: name,
        );
      }
    });

    test('ignores auxiliary artifacts by kind as well as by name', () {
      final asset = UpdateResolver.selectAsset([
        assetNamed('extra.bin', kind: 'signature', id: 'sig'),
        assetNamed('agent.bin', kind: 'installer', id: 'real'),
      ], platform: null);

      expect(asset!.id, 'real');
    });

    test('prefers an installer over an archive, deterministically', () {
      final assets = [
        assetNamed('b-agent.tar.gz', platform: 'linux-x64', kind: 'archive'),
        assetNamed('a-agent.run', platform: 'linux-x64', kind: 'installer'),
      ];

      expect(
        UpdateResolver.selectAsset(assets, platform: 'linux-x64')!.name,
        'a-agent.run',
      );
      expect(
        UpdateResolver.selectAsset(
          assets.reversed.toList(),
          platform: 'linux-x64',
        )!.name,
        'a-agent.run',
        reason: 'selection must not depend on input order',
      );
    });

    test('returns null for an empty or all-auxiliary release', () {
      expect(UpdateResolver.selectAsset(const []), isNull);
      expect(UpdateResolver.selectAsset([assetNamed('checksums.txt')]), isNull);
    });
  });

  group('UpdateChecker', () {
    late TestStore harness;

    setUp(() async {
      harness = TestStore();
      await harness.seedPackage(platforms: ['linux-x64']);
      await harness.publish(
        'omnyagent',
        '1.0.0',
        assets: {'agent-linux.tar.gz': 'v1'},
        platform: 'linux-x64',
      );
    });

    tearDown(() => harness.close());

    UpdateChecker checkerAt(String version, {ReleaseChannel? channel}) =>
        UpdateChecker.forVersion(
          store: harness.store,
          packageReference: 'omnyagent',
          currentVersion: version,
          channel: channel,
          platform: 'linux-x64',
        );

    test('answers the basic questions', () async {
      expect(await checkerAt('1.0.0').hasUpdate(), isFalse);
      expect((await checkerAt('1.0.0').latestVersion()).toString(), '1.0.0');

      await harness.publish(
        'omnyagent',
        '1.1.0',
        assets: {'agent-linux.tar.gz': 'v2'},
        platform: 'linux-x64',
      );

      final info = await checkerAt('1.0.0').checkForUpdates();
      expect(info.updateAvailable, isTrue);
      expect(info.asset!.name, 'agent-linux.tar.gz');
    });

    test('looks at another channel without switching to it', () async {
      await harness.publish('omnyagent', '2.0.0-beta.1');

      final checker = checkerAt('1.0.0');
      expect(await checker.hasUpdate(), isFalse);
      expect(
        (await checker.latestChannel(ReleaseChannel.beta))!.version.toString(),
        '2.0.0-beta.1',
      );
    });

    test(
      'resolves the asset for a release the same way the server does',
      () async {
        final release = await harness.store.latestRelease('omnyagent');
        final asset = await checkerAt('1.0.0').assetFor(release!);

        expect(asset!.name, 'agent-linux.tar.gz');
      },
    );

    test('rejects an unparsable current version up front', () {
      expect(
        () => UpdateChecker.forVersion(
          store: harness.store,
          packageReference: 'omnyagent',
          currentVersion: 'not-a-version',
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    group('watch', () {
      test('emits immediately and then only on change', () async {
        final checker = checkerAt('1.0.0');
        final seen = <UpdateInfo>[];
        final subscription = checker
            .watch(interval: const Duration(milliseconds: 20))
            .listen(seen.add);
        addTearDown(subscription.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(seen, hasLength(1), reason: 'a steady answer emits once');
        expect(seen.single.updateAvailable, isFalse);

        await harness.publish('omnyagent', '1.1.0');
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(seen, hasLength(2));
        expect(seen.last.updateAvailable, isTrue);
        expect(seen.last.latestVersion.toString(), '1.1.0');
      });

      test('survives a failing poll instead of closing the stream', () async {
        final checker = UpdateChecker.forVersion(
          store: harness.store,
          // A package that does not exist, so every check throws.
          packageReference: 'ghost',
          currentVersion: '1.0.0',
        );
        final errors = <Object>[];
        var closed = false;

        final subscription = checker
            .watch(
              interval: const Duration(milliseconds: 20),
              onError: (error, _) => errors.add(error),
            )
            .listen((_) {}, onDone: () => closed = true);
        addTearDown(subscription.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 100));

        // A background updater must not die because the registry was briefly
        // unreachable.
        expect(errors, isNotEmpty);
        expect(errors.first, isA<PackageNotFoundException>());
        expect(closed, isFalse);
      });

      test('stops polling when the subscription is cancelled', () async {
        final checker = checkerAt('1.0.0');
        final seen = <UpdateInfo>[];
        final subscription = checker
            .watch(interval: const Duration(milliseconds: 10))
            .listen(seen.add);

        await Future<void>.delayed(const Duration(milliseconds: 40));
        await subscription.cancel();
        final countAtCancel = seen.length;

        await harness.publish('omnyagent', '1.1.0');
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(seen, hasLength(countAtCancel));
      });
    });
  });
}
