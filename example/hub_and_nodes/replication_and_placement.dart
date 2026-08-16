import 'dart:convert';

import 'package:omnystore/omnystore_hub.dart';

/// **12 — Placement and replication across an organization's nodes.**
///
/// Metadata writes go to exactly **one** provider — the owner — so ids stay
/// unique and unambiguous across the federation. Artifact *bytes* have no such
/// constraint, so replication is a separate, explicit step: copy them to
/// another provider that serves the same organization, verified on arrival.
///
/// Placement itself is decided by priority, then free space, then id — never
/// by registration order, so the same fleet makes the same decision every time.
///
/// ```sh
/// dart run example/hub_and_nodes/replication_and_placement.dart
/// ```
Future<void> main() async {
  final registry = ProviderRegistry();
  final hub = OmnyStoreHub(providers: registry);

  // Two nodes serve `acme`; one of them also serves `globex`.
  final primary = _provider('node-eu', {'acme', 'globex'}, priority: 10);
  final secondary = _provider('node-us', {'acme'}, priority: 1);
  final coldStore = _provider(
    'node-archive',
    {'acme'},
    priority: 5,
    labels: {'tier': 'cold'},
  );

  for (final provider in [primary, secondary, coldStore]) {
    hub.addProvider(provider);
  }

  print('Providers serving acme, best first:');
  for (final provider in registry.providersFor('acme')) {
    print(
      '  ${provider.id.padRight(14)} priority ${provider.descriptor.priority}',
    );
  }
  print('A write for acme goes to: ${registry.primaryFor('acme').id}');
  print(
    'A write for acme on cold storage goes to: '
    "${registry.primaryFor('acme', labels: {'tier': 'cold'}).id}",
  );

  // ------------------------------------------------------------ publish ---
  final organization = await hub.createOrganization(name: 'acme');
  final project = await hub.createProject(
    organizationId: organization.id,
    name: 'agent',
  );
  final package = await hub.createPackage(
    projectId: project.id,
    name: 'omnyagent',
  );
  final release = await hub.publishRelease(
    packageReference: package.id,
    version: Version.parse('1.0.0'),
  );
  final asset = await hub.attachAsset(
    releaseId: release.id,
    name: 'omnyagent-linux-x64.tar.gz',
    data: Stream.value(utf8.encode('the artifact bytes')),
    platform: 'linux-x64',
  );

  print('\nAfter publishing, only the owner holds the bytes:');
  _report([primary, secondary, coldStore]);

  // ---------------------------------------------------------- replicate ---
  // The target gets the organization → project → package → release chain
  // created for it, located by *name* and version: each provider mints its own
  // ids, so they never have to agree.
  final replica = await hub.replicateAsset(asset.id, secondary.id);
  print('\nReplicated to ${secondary.id}: sha256 ${replica.sha256}');
  print('  digests match: ${replica.sha256 == asset.sha256}');
  _report([primary, secondary, coldStore]);

  // Re-running converges rather than failing: replication is a reconciliation
  // pass, and an already-present, digest-matching replica is a success.
  final again = await hub.replicateAsset(asset.id, secondary.id);
  print('  re-running is idempotent: ${again.id == replica.id}');

  // Aggregated listings deduplicate by natural key, so the organization now
  // held by two providers still appears once.
  print(
    '\nOrganizations across the federation: '
    '${(await hub.listOrganizations()).map((o) => o.name).join(', ')}',
  );

  // -------------------------------------------------------------- drain ---
  // Retiring a node: stop new placements, keep serving what it has, replicate
  // elsewhere, then remove it.
  primary.updateDescriptor(
    primary.descriptor.copyWith(status: ProviderStatus.draining),
  );
  print(
    '\nnode-eu draining; a write for acme now goes to: '
    '${registry.primaryFor('acme').id}',
  );

  await hub.close();
}

LocalStoreProvider _provider(
  String id,
  Set<String> organizations, {
  int priority = 0,
  Map<String, String> labels = const {},
}) => LocalStoreProvider(
  OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
    providerId: id,
  ),
  descriptor: ProviderDescriptor(
    id: id,
    kind: ProviderKind.node,
    organizations: organizations,
    priority: priority,
    labels: labels,
  ),
);

void _report(List<LocalStoreProvider> providers) {
  for (final provider in providers) {
    final storage = provider.store.storage as MemoryObjectStorage;
    print('  ${provider.id.padRight(14)} ${storage.length} object(s)');
  }
}
