import 'dart:convert';

import 'package:omnystore/omnystore.dart';

/// **1 — An embedded registry, end to end.**
///
/// The whole platform in one process and about thirty lines: create the
/// hierarchy, publish a release, attach an artifact, and read the latest back.
/// No server, no network, no database.
///
/// ```sh
/// dart run example/getting_started/embedded_registry.dart
/// ```
Future<void> main() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
  );

  final organization = await store.createOrganization(
    name: 'acme',
    displayName: 'Acme Corporation',
  );
  final project = await store.createProject(
    organizationId: organization.id,
    name: 'agent',
    repository: 'https://github.com/acme/agent',
  );
  final package = await store.createPackage(
    projectId: project.id,
    name: 'omnyagent',
    description: 'The Acme monitoring agent',
    platforms: ['linux-x64', 'macos-arm64'],
  );

  final release = await store.publishRelease(
    packageReference: package.id,
    version: Version.parse('1.0.0'),
    notes: 'First stable release.',
  );

  final asset = await store.attachAsset(
    releaseId: release.id,
    name: 'omnyagent-linux-x64.tar.gz',
    data: Stream.value(utf8.encode('<the artifact bytes>')),
    contentType: 'application/gzip',
    platform: 'linux-x64',
  );

  print('Published ${package.name} ${release.version}');
  print('  channel:  ${release.channel.name}');
  print('  artifact: ${asset.name} (${asset.sizeBytes} bytes)');
  print('  sha256:   ${asset.sha256}');

  final latest = await store.latestRelease('omnyagent');
  print('\nlatestRelease() => ${latest!.version}');

  // Reading the bytes back streams them; nothing is buffered whole.
  final download = await store.openAsset(asset.id);
  final bytes = <int>[];
  await for (final chunk in download.stream) {
    bytes.addAll(chunk);
  }
  print('Downloaded ${bytes.length} bytes: ${utf8.decode(bytes)}');

  await store.close();
}
