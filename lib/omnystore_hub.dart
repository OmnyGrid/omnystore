/// OmnyStore Hub — the discovery point that federates storage nodes and serves
/// the REST API.
///
/// A hub owns the routing table (which nodes serve which organizations) and
/// aggregates them into one registry. It can also be a **provider itself**, so
/// a small deployment runs a single process with no separate node beside it.
///
/// ```dart
/// final hub = OmnyStoreHub();
///
/// // The hub hosts everything itself, to begin with.
/// hub.addProvider(LocalStoreProvider(
///   OmnyStore(
///     repositories: MemoryRepositories(),
///     storage: LocalObjectStorage('/var/lib/omnystore'),
///   ),
///   descriptor: ProviderDescriptor(
///     id: 'hub-local', kind: ProviderKind.hub, servesAll: true,
///   ),
/// ));
///
/// // Serve it over HTTP, and accept storage nodes on the same port.
/// final server = OmnyStoreServer(store: hub);
/// await server.start(port: 8080);
/// ```
///
/// Nodes dial the hub's control endpoint and register the organizations they
/// serve; from then on the hub routes those organizations' traffic to them. See
/// `package:omnystore/omnystore_node.dart` for the node side.
library;

export 'omnystore.dart';

// REST API server.
export 'src/api/api_errors.dart';
export 'src/api/omnystore_server.dart';
export 'src/api/store_api_service.dart';

// Federation.
export 'src/hub/omnystore_hub.dart';
export 'src/hub/store_node_gateway.dart';
export 'src/nodes/provider_registry.dart';
export 'src/nodes/remote_store_provider.dart';
export 'src/nodes/store_protocol.dart';
export 'src/nodes/store_provider.dart';
export 'src/nodes/store_rpc_server.dart';

// The OmnyHub pieces a deployment configures directly: authentication for
// publishing and for node admission, TLS, and the hub itself when an
// application mounts its own services on the same port. Re-exported so
// configuring a server needs one import, not three.
export 'package:omnyhub/omnyhub.dart'
    show
        AllowAllAuthorizer,
        AnonymousAuthenticator,
        Authenticator,
        Authorizer,
        BasicAuthAuthenticator,
        BearerTokenAuthenticator,
        CompositeAuthenticator,
        DenyAllAuthorizer,
        Domain,
        HandlerService,
        HttpTransport,
        HubRequest,
        HubResponse,
        LetsEncryptTls,
        Middleware,
        OmnyHub,
        PathRule,
        PredicateAuthorizer,
        ReloadableFileTls,
        RoleBasedAuthorizer,
        RouterService,
        StaticTls,
        TlsProvider,
        cors;
