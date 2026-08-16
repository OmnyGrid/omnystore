import 'dart:async';

import 'package:omnyhub/omnyhub.dart'
    show
        AllowAllAuthorizer,
        AnonymousAuthenticator,
        Authenticator,
        Authorizer,
        HandlerService,
        HttpTransport,
        HubRequest,
        Logger,
        Middleware,
        NoopLogger,
        OmnyHub,
        PathRule,
        RouterService,
        TlsProvider,
        cors;

import '../exceptions/omnystore_exception.dart';
import '../hub/omnystore_hub.dart';
import '../hub/store_node_gateway.dart';
import '../services/omnystore_api.dart';
import '../version.dart';
import 'store_api_service.dart';

/// The HTTP REST server: an OmnyHub hosting the `/api/v1` surface and, when the
/// store is a federating hub, the control endpoint storage nodes dial.
///
/// Both live on **one port**, which is what makes the whole platform deployable
/// as a single container with a single exposed port and one TLS certificate.
///
/// ```dart
/// final server = OmnyStoreServer(
///   store: OmnyStore(
///     repositories: MemoryRepositories(),
///     storage: LocalObjectStorage('/var/lib/omnystore'),
///   ),
///   allowedOrigins: ['https://releases.example.com'],
/// );
/// await server.start(port: 8080);
/// print('listening on ${server.port}');
/// ```
///
/// With automatic TLS and a node endpoint:
///
/// ```dart
/// final hub = OmnyStoreHub()..addProvider(localProvider);
/// final server = OmnyStoreServer(
///   store: hub,
///   tls: LetsEncryptTls(domains: [Domain(domain: 'store.example.com', email: 'ops@example.com')]),
///   nodeAuthenticator: TokenAuthenticator(tokens: {nodeToken: 'node'}),
/// );
/// await server.start(port: 443);
/// ```
///
/// **Read/write separation.** Reads are open by default — a registry that
/// cannot be read anonymously cannot serve public downloads or update checks.
/// Writes go through [writeAuthenticator]/[requireAuthForWrites], so publishing
/// can be locked down without breaking the clients that only consume.
class OmnyStoreServer {
  /// The registry being served. An `OmnyStore` for a single-process
  /// deployment, an [OmnyStoreHub] to federate nodes.
  final OmnyStoreApi store;

  /// The underlying OmnyHub instance. Exposed so an application can register
  /// its own services (a web UI, a metrics endpoint) on the same port.
  final OmnyHub hub;

  /// The REST router.
  final RouterService api;

  /// The unversioned `GET /health` service.
  final HandlerService healthService;

  /// The storage-node control endpoint, or `null` when [store] is not an
  /// [OmnyStoreHub] or nodes were disabled.
  final StoreNodeGateway? nodes;

  /// Structured logging.
  final Logger logger;

  /// Whether every mutating request must carry an authenticated principal.
  final bool requireAuthForWrites;

  /// Roles a principal must hold to perform a mutating request. Empty means
  /// "any authenticated principal".
  final Set<String> writeRoles;

  bool _started = false;

  OmnyStoreServer._({
    required this.store,
    required this.hub,
    required this.api,
    required this.healthService,
    required this.nodes,
    required this.logger,
    required this.requireAuthForWrites,
    required this.writeRoles,
  });

  /// Creates a server for [store].
  ///
  /// [allowedOrigins] enables CORS for a browser app; pass [allowAnyOrigin] for
  /// a fully public registry. CORS is mounted in OmnyHub's *outer* middleware,
  /// so a browser can read error responses and preflights are answered before
  /// authentication — without that, a 401 or 404 reaches the browser as an
  /// opaque network error.
  ///
  /// [enableNodes] hosts the storage-node control endpoint at [nodeMount]. It
  /// only applies when [store] is an [OmnyStoreHub]: a plain `OmnyStore` has no
  /// provider registry for nodes to join.
  factory OmnyStoreServer({
    required OmnyStoreApi store,
    Logger logger = const NoopLogger(),
    Iterable<String> allowedOrigins = const [],
    bool allowAnyOrigin = false,
    Authenticator? authenticator,
    Authenticator? writeAuthenticator,
    Authorizer? authorizer,
    bool requireAuthForWrites = false,
    Set<String> writeRoles = const {},
    bool enableNodes = true,
    String nodeMount = '/_node',
    Authenticator? nodeAuthenticator,
    NodeAdmissionPolicy? nodeAdmissionPolicy,
    Duration redirectLifetime = const Duration(minutes: 15),
    bool recordDownloads = true,
    bool captureClientAddress = true,
    List<Middleware> middleware = const [],
  }) {
    final corsMiddleware = <Middleware>[
      if (allowAnyOrigin || allowedOrigins.isNotEmpty)
        cors(
          allowedOrigins: allowedOrigins,
          allowAnyOrigin: allowAnyOrigin,
          // The checksum header is what lets a browser-based downloader verify
          // an artifact; without exposing it the value is invisible to JS.
          exposedHeaders: const [
            'content-disposition',
            'content-range',
            'x-omnystore-sha256',
          ],
        ),
    ];

    final hub = OmnyHub(
      logger: logger,
      middleware: middleware,
      outerMiddleware: corsMiddleware,
      // OmnyHub's defaults are "everyone anonymous, everything allowed", which
      // is the right default for a registry whose reads are public.
      authenticator: authenticator ?? const AnonymousAuthenticator(),
      authorizer: authorizer ?? const AllowAllAuthorizer(),
    );

    final api = StoreApiService.build(
      store,
      logger: logger,
      redirectLifetime: redirectLifetime,
      recordDownloads: recordDownloads,
      captureClientAddress: captureClientAddress,
      // Applied to mutating routes only. A hub-wide `Authorizer` cannot do
      // this job: it runs on *every* request, so requiring a role there would
      // also gate the anonymous downloads and update checks a public registry
      // exists to serve.
      writeGuard: requireAuthForWrites || writeRoles.isNotEmpty
          ? (request) => _requireWriteAccess(request, writeRoles)
          : null,
    );

    final gateway = enableNodes && store is OmnyStoreHub
        ? StoreNodeGateway(
            store: store,
            mount: nodeMount,
            admissionPolicy: nodeAdmissionPolicy,
            logger: logger,
          )
        : null;

    final health = StoreApiService.health(store, logger: logger);

    final server = OmnyStoreServer._(
      store: store,
      hub: hub,
      api: api,
      healthService: health,
      nodes: gateway,
      logger: logger,
      requireAuthForWrites: requireAuthForWrites,
      writeRoles: Set.unmodifiable(writeRoles),
    );

    // Registration is async on OmnyHub but resolves immediately while the hub
    // is stopped, so the constructor can kick it off and `start` will await a
    // fully-populated hub.
    unawaited(
      hub.registerService(
        api,
        authenticator: writeAuthenticator ?? authenticator,
      ),
    );
    // Always anonymous: a load balancer's health probe carries no credentials,
    // and a probe that 401s reads as an outage.
    unawaited(hub.registerService(health));
    if (gateway != null) {
      unawaited(
        hub.registerService(
          gateway.service,
          when: PathRule(nodeMount),
          // Node registration is the most sensitive endpoint on the server: a
          // peer that joins can claim organizations and receive their releases.
          // Its authenticator is separate so it can be strict while public
          // reads stay open.
          authenticator: nodeAuthenticator,
          priority: 10,
        ),
      );
    }

    return server;
  }

  /// Whether the server is listening.
  bool get isRunning => _started;

  /// The port the server is bound to, or `null` before [start].
  int? get port => hub.port;

  /// Binds [address]:[port] and starts serving.
  ///
  /// Pass `port: 0` for an ephemeral port, which is what tests want; read the
  /// assigned port back from [port] afterwards.
  Future<void> start({
    int port = 8080,
    Object address = '0.0.0.0',
    TlsProvider? tls,
  }) async {
    if (_started) throw StateError('OmnyStoreServer is already running');
    await hub.addTransport(
      tls == null
          ? HttpTransport.http(address: address, port: port)
          : HttpTransport.https(address: address, port: port, tls: tls),
    );
    await hub.start();
    _started = true;
    logger.info(
      'OmnyStore server started',
      context: {
        'version': omnyStoreVersion,
        'port': hub.port,
        'tls': tls != null,
        'nodes': nodes != null,
      },
    );
  }

  /// Stops serving and releases the transport.
  Future<void> stop() async {
    if (!_started) return;
    await hub.stop();
    _started = false;
    logger.info('OmnyStore server stopped');
  }

  /// Stops the server and closes the underlying store.
  Future<void> close() async {
    await stop();
    await store.close();
  }

  /// Fails closed: no principal is a `401`, a principal without the required
  /// role is a `403`.
  static void _requireWriteAccess(HubRequest request, Set<String> roles) {
    final principal = request.principal;
    if (principal == null) {
      throw const UnauthorizedException(
        'This registry requires authentication to publish',
      );
    }
    if (roles.isNotEmpty && !principal.hasAnyRole(roles)) {
      throw ForbiddenException(
        'Publishing requires one of these roles: ${roles.join(', ')}',
      );
    }
  }
}
