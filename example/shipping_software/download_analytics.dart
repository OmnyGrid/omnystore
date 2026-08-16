import 'dart:convert';

import 'package:omnystore/omnystore.dart';

/// **14 — Download analytics: is the rollout progressing?**
///
/// The server records a download as it serves it, so these numbers come for
/// free. Adoption per version is what tells you whether a release is actually
/// reaching the fleet; per artifact tells you which builds matter enough to
/// keep producing.
///
/// ```sh
/// dart run example/shipping_software/download_analytics.dart
/// ```
Future<void> main() async {
  final clock = _SteppingClock();
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
    clock: clock,
  );

  final organization = await store.createOrganization(name: 'acme');
  final project = await store.createProject(
    organizationId: organization.id,
    name: 'agent',
  );
  await store.createPackage(projectId: project.id, name: 'omnyagent');

  final assets = <String, Asset>{};
  for (final version in ['1.0.0', '1.1.0']) {
    final release = await store.publishRelease(
      packageReference: 'omnyagent',
      version: Version.parse(version),
    );
    for (final platform in ['linux-x64', 'macos-arm64']) {
      assets['$version/$platform'] = await store.attachAsset(
        releaseId: release.id,
        name: 'omnyagent-$platform.tar.gz',
        data: Stream.value(utf8.encode('build $version for $platform')),
        platform: platform,
      );
    }
  }

  // A rollout in progress: the old version is still being pulled while the new
  // one ramps up.
  final traffic = {
    '1.0.0/linux-x64': 40,
    '1.0.0/macos-arm64': 12,
    '1.1.0/linux-x64': 95,
    '1.1.0/macos-arm64': 31,
  };
  for (final entry in traffic.entries) {
    for (var i = 0; i < entry.value; i++) {
      clock.advance(const Duration(minutes: 5));
      await store.recordDownload(
        assetId: assets[entry.key]!.id,
        clientAddress: '203.0.113.${i % 250}',
        userAgent: 'omnyagent/${entry.key.split('/').first}',
      );
    }
  }

  final stats = await store.downloadStats('omnyagent');
  print('Total downloads: ${stats.total}\n');

  print('By version:');
  final byVersion = stats.byVersion.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in byVersion) {
    final share = (entry.value / stats.total * 100).round();
    print(
      '  ${entry.key.padRight(8)} ${entry.value.toString().padLeft(4)}  '
      '${'█' * (share ~/ 2)} $share%',
    );
  }

  print('\nBy artifact:');
  for (final entry in stats.byAsset.entries) {
    final asset = await store.asset(entry.key);
    print('  ${asset!.name.padRight(30)} ${entry.value}');
  }

  // Counters live on the asset too, so a listing shows adoption without a
  // second query.
  print('\nPer-asset counters:');
  for (final asset in assets.values) {
    final current = await store.asset(asset.id);
    print('  ${current!.name.padRight(30)} ${current.downloadCount}');
  }

  // Windowed, for a "downloads this week" panel. `from` is inclusive, `to`
  // exclusive.
  final recent = await store.downloadStats(
    'omnyagent',
    from: clock.now().subtract(const Duration(hours: 6)),
  );
  print('\nLast six hours: ${recent.total} downloads');

  // The raw records carry the client address and user agent for abuse
  // investigation; they are never returned by the public API.
  final latest = await store.listDownloads('omnyagent', limit: 3);
  print('\nMost recent:');
  for (final record in latest) {
    print(
      '  ${record.downloadedAt.toIso8601String()}  ${record.version}  '
      '${record.userAgent}',
    );
  }

  await store.close();
}

/// A clock the example advances by hand, so the timestamps form a plausible
/// timeline rather than all landing in the same millisecond.
class _SteppingClock implements Clock {
  DateTime _now = DateTime.utc(2026, 3, 1);

  @override
  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}
