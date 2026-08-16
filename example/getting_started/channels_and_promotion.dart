import 'package:omnystore/omnystore.dart';

/// **2 — Channels, and promoting a build towards stability.**
///
/// A release's channel is *derived from its version*, so the two can never
/// disagree. Channel queries are inclusive downward in stability, which is what
/// lets one stable release reach every subscriber without being re-published
/// per channel.
///
/// ```sh
/// dart run example/getting_started/channels_and_promotion.dart
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

  // The pre-release tag decides the channel. Nothing else does.
  for (final version in ['1.0.0', '1.1.0-dev.4', '1.1.0-beta.2']) {
    final release = await store.publishRelease(
      packageReference: 'omnyagent',
      version: Version.parse(version),
    );
    print(
      '${release.version.toString().padRight(14)} → ${release.channel.name}',
    );
  }

  print('\nWhat each subscriber is offered:');
  for (final channel in ReleaseChannel.values) {
    final release = await store.latestChannel('omnyagent', channel);
    print('  ${channel.name.padRight(8)} → ${release?.version ?? '(none)'}');
  }

  print('\nStrictly that channel only (exact: true):');
  for (final channel in ReleaseChannel.values) {
    final release = await store.latestChannel(
      'omnyagent',
      channel,
      exact: true,
    );
    print('  ${channel.name.padRight(8)} → ${release?.version ?? '(none)'}');
  }

  // Promotion cannot mutate a release — its version *is* its channel — so it
  // publishes 1.1.0 from 1.1.0-beta.2 and copies the artifacts across.
  final beta = await store.latestBeta('omnyagent');
  final promoted = await store.promoteRelease(
    beta!.id,
    ReleaseChannel.release,
    notes: 'Promoted from ${beta.version} after two weeks of testing.',
  );

  print('\nPromoted ${beta.version} → ${promoted.version}');
  print(
    '  the beta release is still there: '
    '${(await store.release(beta.id)) != null}',
  );
  print('  every subscriber now sees it:');
  for (final channel in ReleaseChannel.values) {
    print(
      '    ${channel.name.padRight(8)} → '
      '${(await store.latestChannel('omnyagent', channel))?.version}',
    );
  }

  await store.close();
}
