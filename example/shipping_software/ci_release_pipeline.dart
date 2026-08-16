import 'dart:io';

import 'package:omnystore/omnystore.dart';

/// **10 — A CI release pipeline.**
///
/// What a build job runs after producing its artifacts: derive the version and
/// channel from the branch, publish, upload every platform build, and attach a
/// checksums file. Idempotent enough to re-run, and it fails loudly rather
/// than publishing something unverified.
///
/// ```sh
/// OMNYSTORE_URL=https://store.example.com \
/// OMNYSTORE_TOKEN=$CI_PUBLISH_TOKEN \
/// dart run example/shipping_software/ci_release_pipeline.dart 1.4.0 build/
/// ```
///
/// The equivalent with the CLI, which most pipelines will prefer:
///
/// ```sh
/// omnystore release publish --package omnyagent --version 1.4.0-beta.7 \
///   --notes @CHANGELOG.md \
///   --asset build/omnyagent-linux-x64.tar.gz:linux-x64 \
///   --asset build/omnyagent-macos-arm64.tar.gz:macos-arm64
/// ```
Future<void> main(List<String> arguments) async {
  final environment = Platform.environment;
  final serverUrl = environment['OMNYSTORE_URL'];
  if (serverUrl == null) {
    stderr.writeln('Set OMNYSTORE_URL to the registry base URL.');
    exit(64);
  }

  final baseVersion = Versions.parse(
    arguments.isNotEmpty
        ? arguments.first
        : (environment['VERSION'] ?? '0.0.0'),
  );
  final artifactDir = Directory(arguments.length > 1 ? arguments[1] : 'build');

  // The branch decides the channel; the channel stamps the version. One
  // pipeline produces 1.4.0-dev.41, 1.4.0-beta.3 and 1.4.0 with no string
  // surgery at the call site.
  final branch = environment['CI_BRANCH'] ?? 'main';
  final buildNumber = int.tryParse(environment['CI_BUILD_NUMBER'] ?? '');
  final channel = switch (branch) {
    'release' || 'stable' => ReleaseChannel.release,
    'beta' => ReleaseChannel.beta,
    _ => ReleaseChannel.dev,
  };
  final version = Versions.stamp(baseVersion, channel, buildNumber);

  final client = OmnyStoreClient(
    baseUrl: serverUrl,
    auth: TokenAuthProvider(environment['OMNYSTORE_TOKEN'] ?? ''),
  );

  try {
    stdout.writeln('Publishing omnyagent $version (${channel.name})…');

    final release = await client.publishRelease(
      packageReference: 'omnyagent',
      version: version,
      notes: await _changelog(),
      tag: environment['CI_COMMIT_TAG'],
      metadata: {
        'commit': environment['CI_COMMIT_SHA'] ?? 'unknown',
        'pipeline': environment['CI_PIPELINE_ID'] ?? 'local',
      },
    );

    for (final file in artifactDir.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      final platform = _platformOf(name);

      // The checksum is computed locally and sent with the upload, so a
      // corrupted transfer fails the build instead of publishing bad bytes.
      final expected = await DownloadManager().checksumOf(file.path);

      final asset = await client.attachAsset(
        releaseId: release.id,
        name: name,
        data: file.openRead(),
        length: await file.length(),
        expectedSha256: expected,
        platform: platform,
        kind: name.endsWith('.sha256') ? 'checksums' : 'archive',
      );
      stdout.writeln('  + ${asset.name}  ${asset.sizeBytes} B  $platform');
    }

    stdout.writeln('Published ${release.version}.');

    // Publishing to beta does not touch what stable subscribers are offered.
    final stable = await client.latestRelease('omnyagent');
    stdout.writeln('Stable channel still on: ${stable?.version ?? '(none)'}');
  } on ConflictException catch (e) {
    // Releases are immutable, so a re-run of the same build is a conflict —
    // which is the correct outcome, not a failure to paper over.
    stderr.writeln('Already published: ${e.message}');
    exit(1);
  } on ChecksumMismatchException catch (e) {
    stderr.writeln('Upload corrupted in transit: ${e.message}');
    exit(1);
  } on OmnyStoreException catch (e) {
    stderr.writeln('Release failed: ${e.message}');
    exit(1);
  } finally {
    await client.close();
  }
}

/// Reads the changelog, if the repository has one.
Future<String?> _changelog() async {
  final file = File('CHANGELOG.md');
  return file.existsSync() ? file.readAsString() : null;
}

/// Infers the platform from a conventional artifact name.
String? _platformOf(String filename) {
  for (final platform in [
    'linux-x64',
    'linux-arm64',
    'macos-x64',
    'macos-arm64',
    'windows-x64',
  ]) {
    if (filename.contains(platform)) return platform;
  }
  return null;
}
