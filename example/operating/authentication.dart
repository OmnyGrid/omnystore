import 'package:omnystore/omnystore_hub.dart';

/// **11 — Authentication: open reads, guarded writes.**
///
/// A release registry has an asymmetry most services do not: **reads must stay
/// open**. Downloads and update checks are served to anonymous clients — that
/// is the product. What needs guarding is publishing, and the endpoint storage
/// nodes join on, because a peer that joins can claim an organization and start
/// receiving its releases.
///
/// ```sh
/// dart run example/operating/authentication.dart
/// ```
Future<void> main() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
  );
  final hub = OmnyStoreHub()
    ..addProvider(
      LocalStoreProvider(
        store,
        descriptor: ProviderDescriptor(
          id: 'hub-local',
          kind: ProviderKind.hub,
          servesAll: true,
        ),
      ),
    );

  final server = OmnyStoreServer(
    store: hub,

    // Writes require a principal. Reads are untouched.
    requireAuthForWrites: true,
    writeAuthenticator: CompositeAuthenticator([
      // A long-lived CI token.
      BearerTokenAuthenticator({
        'ci-publish-token': Principal(
          id: 'ci',
          displayName: 'Release pipeline',
          roles: const {'publisher'},
        ),
      }),
      // …and whatever else the deployment already has. A resolver is the seam
      // for an OIDC introspection call or a database lookup.
      BearerTokenAuthenticator.resolver((token) async {
        if (!token.startsWith('omny_pat_')) return null;
        return Principal(
          id: 'user:${token.substring(9)}',
          roles: {'publisher'},
        );
      }),
    ]),

    // Fails closed on the mutating routes only: an authenticated principal
    // without this role gets a 403, while anonymous reads keep working.
    //
    // A hub-wide `Authorizer` cannot express this — it runs on every request,
    // so a role requirement there would also gate downloads and update checks.
    writeRoles: const {'publisher'},

    // The node endpoint gets its own, stricter credential. Leaving this null
    // on a reachable endpoint lets any peer claim to serve an organization.
    nodeAuthenticator: BearerTokenAuthenticator({
      'node-join-token': Principal(id: 'node', roles: const {'node'}),
    }),
    // And a second gate: even an authenticated node only serves what policy
    // allows, whatever it declared.
    nodeAdmissionPolicy: (nodeId, declared, principal) {
      final allowed = switch (nodeId) {
        'node-eu' => {'acme', 'globex'},
        'node-us' => {'acme'},
        _ => <String>{},
      };
      return declared.intersection(allowed);
    },
  );

  await server.start(port: 0, address: '127.0.0.1');
  print('Listening on http://127.0.0.1:${server.port}');

  // ---------------------------------------------------------- clients ---
  // An anonymous client can read, which is what a public registry needs.
  final anonymous = OmnyStoreClient(baseUrl: 'http://127.0.0.1:${server.port}');
  print(
    'anonymous read:  ${(await anonymous.listOrganizations()).length} orgs',
  );

  try {
    await anonymous.createOrganization(name: 'acme');
  } on UnauthorizedException catch (e) {
    print('anonymous write: refused — ${e.message}');
  }

  // A publisher can write.
  final publisher = OmnyStoreClient(
    baseUrl: 'http://127.0.0.1:${server.port}',
    auth: const TokenAuthProvider('ci-publish-token'),
  );
  final organization = await publisher.createOrganization(name: 'acme');
  print('publisher write: created ${organization.name}');

  // A short-lived credential refreshes itself and the client retries once on a
  // 401, so an expiring token does not surface as a spurious failure.
  final rotating = OmnyStoreClient(
    baseUrl: 'http://127.0.0.1:${server.port}',
    auth: RefreshingAuthProvider(() async => 'ci-publish-token'),
  );
  print('rotating read:   ${(await rotating.listOrganizations()).length} orgs');

  await anonymous.close();
  await publisher.close();
  await rotating.close();
  await server.stop();
  await store.close();
}
