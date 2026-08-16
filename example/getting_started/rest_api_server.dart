import 'dart:io';

import 'package:omnystore/omnystore_hub.dart';

/// **3 — Run the REST API server.**
///
/// One process, one port: the `/api/v1` surface, an unversioned `/health`
/// probe, and (because the store is a hub) the control endpoint storage nodes
/// dial. Artifacts and metadata live under a single directory that can be
/// backed up or mounted as a volume.
///
/// ```sh
/// dart run example/getting_started/rest_api_server.dart
///
/// curl localhost:8080/health
/// curl -X POST localhost:8080/api/v1/organizations \
///   -H 'content-type: application/json' -d '{"name":"acme"}'
/// ```
Future<void> main() async {
  const dataDir = '.omnystore-example';

  final local = OmnyStore(
    repositories: await JsonFileRepositories.open('$dataDir/metadata'),
    storage: LocalObjectStorage('$dataDir/objects'),
    logger: StructuredLogger(),
    providerId: 'hub-local',
  );

  // Always a hub, even with no nodes: attaching one later needs no restart
  // into a different mode.
  final hub = OmnyStoreHub(logger: StructuredLogger())
    ..addProvider(
      LocalStoreProvider(
        local,
        descriptor: ProviderDescriptor(
          id: 'hub-local',
          kind: ProviderKind.hub,
          // A catch-all: serves every organization that no node claims.
          servesAll: true,
          priority: -100,
        ),
      ),
    );

  final server = OmnyStoreServer(
    store: hub,
    logger: StructuredLogger(),
    // A browser app on this origin may call the API and read the checksum
    // header, so it can verify what it downloads.
    allowedOrigins: const ['https://releases.example.com'],
    // Reads stay open — a registry nobody can read cannot serve downloads or
    // update checks — while publishing requires a token.
    requireAuthForWrites: true,
    writeAuthenticator: BearerTokenAuthenticator({
      'ci-publish-token': Principal(id: 'ci', roles: const {'publisher'}),
    }),
    nodeAuthenticator: BearerTokenAuthenticator({
      'node-join-token': Principal(id: 'node', roles: const {'node'}),
    }),
  );

  await server.start(port: 8080);

  print('OmnyStore listening on http://localhost:${server.port}');
  print('  API:    http://localhost:${server.port}/api/v1');
  print('  health: http://localhost:${server.port}/health');
  print('  nodes:  ws://localhost:${server.port}/_node');
  print('Press Ctrl-C to stop.');

  await ProcessSignal.sigint.watch().first;
  await server.stop();
  await local.close();
}
