import 'package:omnystore/omnystore.dart';

/// **5 — An application checking itself for updates.**
///
/// The shape a real updater takes: ask once at startup, then watch on an
/// interval. `watch` emits only when the answer *changes*, so a subscriber can
/// drive a "restart to update" banner directly, and a failed poll is swallowed
/// rather than killing the stream — over a long-running process the registry
/// will be briefly unreachable at some point.
///
/// ```sh
/// dart run example/shipping_software/update_checker.dart
/// ```
Future<void> main() async {
  // Against a remote registry this would be:
  //   final store = OmnyStoreClient(baseUrl: 'https://store.example.com');
  final store = await _seededStore();

  final checker = UpdateChecker.forVersion(
    store: store,
    packageReference: 'omnyagent',
    // In a real application this is the generated version constant.
    currentVersion: '1.0.0',
    channel: ReleaseChannel.release,
    platform: 'linux-x64',
  );

  final update = await checker.checkForUpdates();
  if (!update.updateAvailable) {
    print('${update.packageName} ${update.currentVersion} is up to date.');
  } else if (!update.isInstallable) {
    // An update exists, but not one this client can install. Gating a download
    // button on `updateAvailable` alone would offer a dead end.
    print(
      '${update.latestVersion} is available, but ships no artifact for '
      'linux-x64.',
    );
  } else {
    print(
      '${update.latestVersion} is available (you have '
      '${update.currentVersion}).',
    );
    print('  notes:    ${update.notes}');
    print('  download: ${update.asset!.name} (${update.asset!.sizeBytes} B)');
    print('  sha256:   ${update.asset!.sha256}');
  }

  // Poll in the background. Cancelling the subscription stops the timer.
  final subscription = checker
      .watch(
        interval: const Duration(hours: 6),
        onError: (error, _) => print('Update check failed: $error'),
      )
      .listen((info) {
        if (info.updateAvailable) {
          print('A new version is available: ${info.latestVersion}');
        }
      });

  await Future<void>.delayed(const Duration(milliseconds: 50));
  await subscription.cancel();
  await store.close();
}

/// A throwaway registry holding 1.0.0 and 1.1.0, so the example runs alone.
Future<OmnyStore> _seededStore() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
  );
  final organization = await store.createOrganization(name: 'acme');
  final project = await store.createProject(
    organizationId: organization.id,
    name: 'agent',
  );
  final package = await store.createPackage(
    projectId: project.id,
    name: 'omnyagent',
  );

  for (final version in ['1.0.0', '1.1.0']) {
    final release = await store.publishRelease(
      packageReference: package.id,
      version: Version.parse(version),
      notes: 'Release notes for $version.',
    );
    await store.attachAsset(
      releaseId: release.id,
      name: 'omnyagent-linux-x64.tar.gz',
      data: Stream.value(List.filled(1024, 0)),
      platform: 'linux-x64',
    );
  }
  return store;
}
