import 'dart:io';

import 'package:omnystore/omnystore_hub.dart';

/// **15 — Mounting the registry into an application you already have.**
///
/// The REST surface is an OmnyHub `Service`, so it does not need a server of
/// its own. Register it into the hub your application already runs and the
/// registry shares its port, its TLS certificate, its authentication and its
/// middleware.
///
/// ```sh
/// dart run example/operating/mount_into_existing_app.dart
///
/// curl localhost:8080/                 # the application's own route
/// curl localhost:8080/health           # the registry's health probe
/// curl localhost:8080/api/v1/providers # the registry API
/// ```
Future<void> main() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
  );

  // An application's existing hub, with its own services and middleware.
  final app = OmnyHub(
    logger: StructuredLogger(),
    outerMiddleware: [cors(allowAnyOrigin: true)],
  );

  await app.registerService(
    HandlerService(
      name: 'app',
      mount: '/',
      handler: (request) async =>
          HubResponse.json({'app': 'acme-console', 'registry': '/api/v1'}),
    ),
  );

  // The registry, as two more services on the same port. `priority` puts them
  // ahead of the application's catch-all route at `/`.
  await app.registerService(
    StoreApiService.build(store, logger: StructuredLogger()),
    priority: 10,
  );
  await app.registerService(StoreApiService.health(store), priority: 10);

  // A storage-node endpoint can be mounted the same way when the store is a
  // hub:
  //
  //   final gateway = StoreNodeGateway(store: omnyStoreHub);
  //   await app.registerService(gateway.service,
  //       when: PathRule('/_node'), priority: 20);

  await app.addTransport(HttpTransport.http(port: 8080));
  await app.start();

  print('acme-console on http://localhost:8080');
  print('  app:      /');
  print('  registry: /api/v1');
  print('  health:   /health');
  print('Press Ctrl-C to stop.');

  await ProcessSignal.sigint.watch().first;
  await app.stop();
  await store.close();
}
