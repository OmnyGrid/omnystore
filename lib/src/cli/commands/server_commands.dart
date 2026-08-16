import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:omnyhub/omnyhub.dart'
    show BearerTokenAuthenticator, Principal, StaticTls;

import '../../api/omnystore_server.dart';
import '../../exceptions/omnystore_exception.dart';
import '../../hub/omnystore_hub.dart';
import '../../models/provider_descriptor.dart';
import '../../nodes/omnystore_node.dart';
import '../../nodes/store_provider.dart';
import '../../version.dart';
import '../cli_context.dart';

/// `omnystore server` — run the REST API server.
///
/// Serves a registry rooted at a data directory, and (unless disabled) accepts
/// storage nodes on the same port.
///
/// ```sh
/// omnystore server --data /var/lib/omnystore --port 8080
/// ```
class ServerCommand extends Command<int> {
  @override
  final String name = 'server';

  @override
  final String description =
      'Run the OmnyStore REST API server, and the storage-node endpoint.';

  @override
  String get invocation => 'omnystore server --data <dir> [--port 8080]';

  /// Reads the global `--data`, `--verbose` and `--quiet` options.
  final ArgResultsSource globals;

  /// The environment, for token and path defaults.
  final Map<String, String> environment;

  /// Where the startup banner goes.
  ///
  /// Injected like every other CLI output, so an embedding tool or a test can
  /// capture it and `--quiet` can suppress it. Writing to `stdout` directly
  /// would make the banner the one piece of CLI output that cannot be
  /// redirected.
  final StringSink out;

  /// Creates the command.
  ServerCommand({
    required this.globals,
    required this.environment,
    StringSink? out,
  }) : out = out ?? stdout {
    argParser
      ..addOption(
        'port',
        abbr: 'P',
        help: 'Port to listen on. 0 picks a free one.',
        defaultsTo: '8080',
      )
      ..addOption(
        'address',
        help: 'Address to bind. Defaults to every interface.',
        defaultsTo: '0.0.0.0',
      )
      ..addOption(
        'cors',
        help:
            'Comma-separated allowed origins for browser clients, or "*" for '
            'any.',
      )
      ..addOption(
        'publish-token',
        help:
            'Require this bearer token for every write. Reads stay open, so '
            'downloads and update checks keep working for anonymous clients. '
            r'Defaults to $OMNYSTORE_PUBLISH_TOKEN.',
      )
      ..addOption(
        'node-token',
        help:
            'Require this bearer token from storage nodes. Without it, any '
            'peer that can reach the control endpoint can claim to serve an '
            r'organization. Defaults to $OMNYSTORE_NODE_TOKEN.',
      )
      ..addFlag(
        'nodes',
        help: 'Accept storage nodes on the same port.',
        defaultsTo: true,
      )
      ..addOption(
        'node-mount',
        help: 'Path the storage-node control endpoint is mounted at.',
        defaultsTo: '/_node',
      )
      ..addOption('tls-cert', help: 'PEM certificate chain, to serve HTTPS.')
      ..addOption('tls-key', help: 'PEM private key, to serve HTTPS.')
      ..addOption(
        'provider-id',
        help: 'Id this server advertises for its own local provider.',
        defaultsTo: 'hub-local',
      );
  }

  @override
  Future<int> run() async {
    final dataDir =
        globals.option('data') ?? environment['OMNYSTORE_DATA'] ?? '.omnystore';
    final verbose = globals.flag('verbose');
    final quiet = globals.flag('quiet');
    final logger = CliContext.loggerFor(verbose: verbose || !quiet);

    final port = int.tryParse(argResults!.option('port') ?? '8080');
    if (port == null || port < 0 || port > 65535) {
      throw CliException(
        'Invalid --port "${argResults!.option('port')}".',
        exitCode: 64,
      );
    }

    final providerId = argResults!.option('provider-id') ?? 'hub-local';
    final local = await CliContext.openLocalStore(
      dataDir,
      logger: logger,
      providerId: providerId,
    );

    // Always a hub, even with no nodes: it costs one indirection and means
    // attaching a node later needs no restart into a different mode.
    final hub = OmnyStoreHub(logger: logger)
      ..addProvider(
        LocalStoreProvider(
          local,
          descriptor: ProviderDescriptor(
            id: providerId,
            kind: ProviderKind.hub,
            // A catch-all, so the server works with no configuration and a
            // node added later takes over its own organizations without the
            // hub being reconfigured.
            servesAll: true,
            dataPlane: DataPlaneMode.relay,
            agentVersion: omnyStoreVersion,
            priority: -100,
          ),
        ),
      );

    final publishToken =
        argResults!.option('publish-token') ??
        environment['OMNYSTORE_PUBLISH_TOKEN'];
    final nodeToken =
        argResults!.option('node-token') ?? environment['OMNYSTORE_NODE_TOKEN'];
    final corsOption = argResults!.option('cors');

    final server = OmnyStoreServer(
      store: hub,
      logger: logger,
      allowAnyOrigin: corsOption == '*',
      allowedOrigins: corsOption == null || corsOption == '*'
          ? const []
          : corsOption
                .split(',')
                .map((o) => o.trim())
                .where((o) => o.isNotEmpty),
      requireAuthForWrites: publishToken != null,
      writeAuthenticator: publishToken == null
          ? null
          : BearerTokenAuthenticator({
              publishToken: Principal(
                id: 'publisher',
                roles: const {'publisher'},
              ),
            }),
      enableNodes: argResults!.flag('nodes'),
      nodeMount: argResults!.option('node-mount') ?? '/_node',
      nodeAuthenticator: nodeToken == null
          ? null
          : BearerTokenAuthenticator({
              nodeToken: Principal(id: 'node', roles: const {'node'}),
            }),
    );

    final tls = _tlsFrom(argResults!);
    await server.start(
      port: port,
      address: argResults!.option('address') ?? '0.0.0.0',
      tls: tls,
    );

    final scheme = tls == null ? 'http' : 'https';
    if (!quiet) {
      out.writeln('OmnyStore $omnyStoreVersion');
      out.writeln('  data:     $dataDir');
      out.writeln('  API:      $scheme://localhost:${server.port}/api/v1');
      out.writeln('  health:   $scheme://localhost:${server.port}/health');
      if (server.nodes != null) {
        final wsScheme = tls == null ? 'ws' : 'wss';
        out.writeln(
          '  nodes:    $wsScheme://localhost:${server.port}'
          '${argResults!.option('node-mount') ?? '/_node'}',
        );
      }
      if (publishToken == null) {
        out.writeln(
          '  writes:   OPEN — anyone who can reach this server can publish. '
          'Pass --publish-token to require authentication.',
        );
      }
      out.writeln('Press Ctrl-C to stop.');
    }

    await _awaitInterrupt();
    if (!quiet) out.writeln('\nShutting down…');
    await server.stop();
    await local.close();
    return 0;
  }

  static StaticTls? _tlsFrom(ArgResults results) {
    final cert = results.option('tls-cert');
    final key = results.option('tls-key');
    if (cert == null && key == null) return null;
    if (cert == null || key == null) {
      throw const CliException(
        '--tls-cert and --tls-key must be given together.',
        exitCode: 64,
      );
    }
    for (final path in [cert, key]) {
      if (!File(path).existsSync()) {
        throw CliException('TLS file not found: $path', exitCode: 66);
      }
    }
    return StaticTls.files(cert, key);
  }
}

/// `omnystore node` — run a storage node that serves organizations through a
/// hub.
///
/// ```sh
/// omnystore node \
///   --hub wss://store.example.com/_node \
///   --id node-eu \
///   --org acme --org globex \
///   --data /var/lib/omnystore-node
/// ```
class NodeCommand extends Command<int> {
  @override
  final String name = 'node';

  @override
  final String description =
      'Run a storage node that serves organizations through a hub.';

  @override
  String get invocation =>
      'omnystore node --hub <ws-url> --id <node-id> --org <name> --data <dir>';

  /// Reads the global `--data`, `--verbose` and `--quiet` options.
  final ArgResultsSource globals;

  /// The environment, for token and path defaults.
  final Map<String, String> environment;

  /// Where the startup banner goes; see [ServerCommand.out].
  final StringSink out;

  /// Creates the command.
  NodeCommand({
    required this.globals,
    required this.environment,
    StringSink? out,
  }) : out = out ?? stdout {
    argParser
      ..addOption(
        'hub',
        help:
            r'Hub control endpoint (ws:// or wss://…/_node). Defaults to '
            r'$OMNYSTORE_HUB.',
      )
      ..addOption('id', help: 'This node\'s id, unique within the hub.')
      ..addMultiOption(
        'org',
        abbr: 'o',
        help:
            'An organization this node serves, repeatable. A node may serve '
            'several, and an organization may be served by several nodes.',
      )
      ..addOption(
        'token',
        help:
            r'Bearer token sent to the hub. Defaults to $OMNYSTORE_NODE_TOKEN.',
      )
      ..addOption(
        'public-url',
        help:
            'Publicly reachable base URL for this node. Set it when clients '
            'can reach the node directly, so the hub redirects them instead of '
            'relaying every byte.',
      )
      ..addOption(
        'priority',
        help: 'Selection weight; higher wins when several nodes serve an org.',
        defaultsTo: '0',
      )
      ..addMultiOption(
        'label',
        help: 'Placement label key=value, repeatable (e.g. region=eu).',
      )
      ..addOption('capacity', help: 'Total capacity in bytes.');
  }

  @override
  Future<int> run() async {
    final hubUrl = argResults!.option('hub') ?? environment['OMNYSTORE_HUB'];
    if (hubUrl == null) {
      throw const CliException(
        'Provide the hub endpoint: --hub wss://store.example.com/_node',
        exitCode: 64,
      );
    }
    final nodeId = argResults!.option('id');
    if (nodeId == null) {
      throw const CliException(
        'Provide this node\'s id: --id node-eu',
        exitCode: 64,
      );
    }
    final organizations = argResults!.multiOption('org').toSet();
    if (organizations.isEmpty) {
      throw const CliException(
        'A node must serve at least one organization: --org acme',
        exitCode: 64,
      );
    }

    final dataDir =
        globals.option('data') ??
        environment['OMNYSTORE_DATA'] ??
        '.omnystore-node';
    final logger = CliContext.loggerFor(verbose: !globals.flag('quiet'));

    final store = await CliContext.openLocalStore(
      dataDir,
      logger: logger,
      providerId: nodeId,
    );

    final node = OmnyStoreNode(
      hubUri: Uri.parse(hubUrl),
      nodeId: nodeId,
      store: store,
      organizations: organizations,
      publicBaseUrl: argResults!.option('public-url'),
      labels: _labels(argResults!.multiOption('label')),
      priority: int.tryParse(argResults!.option('priority') ?? '0') ?? 0,
      capacityBytes: int.tryParse(argResults!.option('capacity') ?? ''),
      logger: logger,
      authToken:
          argResults!.option('token') ?? environment['OMNYSTORE_NODE_TOKEN'],
    );

    await node.start();
    final quiet = globals.flag('quiet');
    if (!quiet) {
      out.writeln('OmnyStore node $omnyStoreVersion');
      out.writeln('  id:            $nodeId');
      out.writeln('  hub:           $hubUrl');
      out.writeln('  organizations: ${organizations.join(', ')}');
      out.writeln('  data:          $dataDir');
      out.writeln('Press Ctrl-C to stop.');
    }

    await _awaitInterrupt();
    // Draining first lets the hub stop placing new artifacts here while
    // downloads already in flight finish.
    if (!quiet) out.writeln('\nDraining and shutting down…');
    await node.drain();
    await node.close();
    return 0;
  }

  static Map<String, String> _labels(List<String> entries) {
    final labels = <String, String>{};
    for (final entry in entries) {
      final index = entry.indexOf('=');
      if (index <= 0) {
        throw CliException(
          "Invalid --label '$entry': expected key=value.",
          exitCode: 64,
        );
      }
      labels[entry.substring(0, index)] = entry.substring(index + 1);
    }
    return labels;
  }
}

/// The global options a long-running command reads.
///
/// A tiny indirection over `ArgResults` so `server` and `node` can be
/// constructed before the top-level arguments are parsed, and so tests can
/// drive them with a literal option map instead of a parser.
abstract interface class ArgResultsSource {
  /// The value of global option [name], or `null`.
  String? option(String name);

  /// The value of global flag [name].
  bool flag(String name);
}

/// An [ArgResultsSource] reading from parsed [ArgResults].
class ParsedGlobals implements ArgResultsSource {
  /// The parsed top-level results.
  final ArgResults results;

  /// Wraps [results].
  const ParsedGlobals(this.results);

  @override
  String? option(String name) => results.option(name);

  @override
  bool flag(String name) => results.flag(name);
}

/// An [ArgResultsSource] backed by a literal map, for tests.
class StaticGlobals implements ArgResultsSource {
  /// Option values.
  final Map<String, String> options;

  /// Flag values.
  final Map<String, bool> flags;

  /// Creates static globals.
  const StaticGlobals({this.options = const {}, this.flags = const {}});

  @override
  String? option(String name) => options[name];

  @override
  bool flag(String name) => flags[name] ?? false;
}

/// Completes on the first `SIGINT` (Ctrl-C).
Future<void> _awaitInterrupt() {
  final completer = Completer<void>();
  late final StreamSubscription<ProcessSignal> subscription;
  subscription = ProcessSignal.sigint.watch().listen((_) {
    unawaited(subscription.cancel());
    if (!completer.isCompleted) completer.complete();
  });
  return completer.future;
}
