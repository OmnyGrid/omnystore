import 'dart:convert';

import 'package:omnystore/omnystore.dart';

/// **16 — Testing a release workflow.**
///
/// The in-memory stack is not a mock: it implements the same contracts as the
/// production adapters, so a test that passes against it is testing the real
/// semantics. With an injected [Clock] and [IdGenerator] there is no wall clock
/// and no randomness, so assertions can be exact.
///
/// Write your release logic against [OmnyStoreApi] and the same code runs
/// against this store in a test, an embedded store in production, and a remote
/// registry over HTTP.
///
/// ```sh
/// dart run example/building_on_it/testing_a_release_workflow.dart
/// ```
Future<void> main() async {
  final clock = _FixedClock();
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
    clock: clock,
    idGenerator: _SequentialIds(),
  );

  final organization = await store.createOrganization(name: 'acme');
  final project = await store.createProject(
    organizationId: organization.id,
    name: 'agent',
  );
  await store.createPackage(projectId: project.id, name: 'omnyagent');

  // Deterministic ids and timestamps.
  print('organization id: ${organization.id}');
  print('created at:      ${organization.createdAt.toIso8601String()}');

  // The workflow under test, written against the interface.
  await shipRelease(store, version: '1.0.0', platforms: ['linux-x64']);
  clock.advance(const Duration(days: 7));
  await shipRelease(
    store,
    version: '1.1.0-beta.1',
    platforms: ['linux-x64', 'macos-arm64'],
  );

  print('\nWhat each channel offers:');
  for (final channel in ReleaseChannel.values) {
    final release = await store.latestChannel('omnyagent', channel);
    print('  ${channel.name.padRight(8)} ${release?.version ?? '(none)'}');
  }

  // Assertions a test would make.
  final beta = await store.latestBeta('omnyagent');
  assert(beta!.version.toString() == '1.1.0-beta.1');
  assert(beta!.publishedAt == clock.now());

  final stable = await store.checkForUpdates(
    packageReference: 'omnyagent',
    currentVersion: Version.parse('1.0.0'),
    platform: 'linux-x64',
  );
  // A stable client is not offered a beta, however new it is.
  assert(!stable.updateAvailable);

  final tester = await store.checkForUpdates(
    packageReference: 'omnyagent',
    currentVersion: Version.parse('1.0.0'),
    channel: ReleaseChannel.beta,
    platform: 'macos-arm64',
  );
  assert(tester.updateAvailable);
  assert(tester.asset!.platform == 'macos-arm64');

  print('\nAll assertions held.');
  await store.close();
}

/// The workflow under test: publish a version and attach one build per
/// platform.
Future<Release> shipRelease(
  OmnyStoreApi store, {
  required String version,
  required List<String> platforms,
}) async {
  final release = await store.publishRelease(
    packageReference: 'omnyagent',
    version: Versions.parse(version),
    notes: 'Automated release of $version.',
  );
  for (final platform in platforms) {
    await store.attachAsset(
      releaseId: release.id,
      name: 'omnyagent-$platform.tar.gz',
      data: Stream.value(utf8.encode('build $version for $platform')),
      platform: platform,
    );
  }
  return release;
}

/// A clock fixed at a chosen instant, advanced explicitly.
class _FixedClock implements Clock {
  DateTime _now = DateTime.utc(2026, 1, 1, 12);

  @override
  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

/// Ids of the form `prefix-1`, `prefix-2`, so expectations can name them.
class _SequentialIds implements IdGenerator {
  final Map<String, int> _counters = {};

  @override
  String next([String prefix = 'id']) {
    final next = (_counters[prefix] ?? 0) + 1;
    _counters[prefix] = next;
    return '$prefix-$next';
  }
}
