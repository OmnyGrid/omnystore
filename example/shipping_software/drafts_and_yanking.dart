import 'dart:convert';

import 'package:omnystore/omnystore.dart';

/// **13 — Drafts, and withdrawing a bad release.**
///
/// Two states that matter to anyone shipping software:
///
/// * A **draft** is stored but never offered. Upload its artifacts, check them,
///   then publish — clients see nothing until you say so.
/// * A **yanked** release stays downloadable but is never *offered* again.
///   That is the safe retraction: deleting would break every client that
///   pinned the version, while yanking stops the bleeding without breaking
///   anyone.
///
/// ```sh
/// dart run example/shipping_software/drafts_and_yanking.dart
/// ```
Future<void> main() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
  );

  final organization = await store.createOrganization(name: 'acme');
  final project = await store.createProject(
    organizationId: organization.id,
    name: 'agent',
  );
  await store.createPackage(projectId: project.id, name: 'omnyagent');
  await store.publishRelease(
    packageReference: 'omnyagent',
    version: Version.parse('1.0.0'),
  );

  // ------------------------------------------------------------- draft ---
  final draft = await store.publishRelease(
    packageReference: 'omnyagent',
    version: Version.parse('1.1.0'),
    notes: 'Still being checked.',
    draft: true,
  );
  await store.attachAsset(
    releaseId: draft.id,
    name: 'omnyagent-linux-x64.tar.gz',
    data: Stream.value(utf8.encode('<candidate build>')),
    platform: 'linux-x64',
  );

  print('While 1.1.0 is a draft:');
  print(
    '  latestRelease() => ${(await store.latestRelease('omnyagent'))!.version}',
  );
  print('  publishedAt     => ${draft.publishedAt}');
  print(
    '  visible to publishers: '
    '${(await store.listReleases('omnyagent', query: ReleaseQuery.all)).length} releases',
  );

  final published = await store.updateRelease(draft.id, draft: false);
  print('\nAfter publishing:');
  print(
    '  latestRelease() => ${(await store.latestRelease('omnyagent'))!.version}',
  );
  print('  publishedAt     => ${published.publishedAt}');

  // -------------------------------------------------------------- yank ---
  final bad = await store.updateRelease(
    published.id,
    yanked: true,
    yankedReason: 'Corrupts the config file on first run.',
  );

  print('\nAfter yanking ${bad.version}:');
  print(
    '  latestRelease() => ${(await store.latestRelease('omnyagent'))!.version}',
  );
  print(
    '  still retrievable by version: '
    '${(await store.releaseByVersion('omnyagent', bad.version)) != null}',
  );
  print('  reason: ${bad.yankedReason}');

  // Clients that pinned 1.1.0 keep working — its artifacts are untouched.
  final assets = await store.listAssets(bad.id);
  print('  artifacts still downloadable: ${assets.length}');

  final update = await store.checkForUpdates(
    packageReference: 'omnyagent',
    currentVersion: Version.parse('1.0.0'),
    platform: 'linux-x64',
  );
  print(
    '  a 1.0.0 client is offered: '
    '${update.updateAvailable ? update.latestVersion : 'nothing'}',
  );

  // ------------------------------------------------------------ repair ---
  await store.publishRelease(
    packageReference: 'omnyagent',
    version: Version.parse('1.1.1'),
    notes: 'Fixes the config corruption in 1.1.0.',
  );
  print('\nAfter shipping the fix:');
  print(
    '  latestRelease() => ${(await store.latestRelease('omnyagent'))!.version}',
  );

  // Un-yanking clears the reason, so a re-instated release does not keep a
  // warning that no longer applies.
  final restored = await store.updateRelease(bad.id, yanked: false);
  print(
    '  1.1.0 re-instated, reason cleared: ${restored.yankedReason == null}',
  );

  await store.close();
}
