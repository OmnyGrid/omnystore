@Tags(['server'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omnystore/omnystore_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The two long-running commands, `omnystore server` and `omnystore node`,
/// driven for real: a bound port answering HTTP, and a node registering with a
/// hub over a WebSocket.
///
/// They are the commands an operator actually runs, and the ones a unit test
/// cannot reach — everything they do happens after a socket is listening.
void main() {
  late Directory dataDir;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('omnystore_cli_server_');
  });

  tearDown(() async {
    if (dataDir.existsSync()) await dataDir.delete(recursive: true);
  });

  /// Runs [arguments] in the background and returns a handle that stops it.
  ///
  /// The commands block until interrupted, so the test drives them
  /// concurrently and shuts them down by killing the process group at the end.
  ({Future<int> exitCode, StringBuffer out}) launch(List<String> arguments) {
    final out = StringBuffer();
    final code = runOmnyStoreCli(
      arguments,
      environment: const {},
      out: out,
      err: out,
    );
    return (exitCode: code, out: out);
  }

  /// Polls [probe] until it succeeds, or fails the test.
  Future<T> until<T>(
    Future<T?> Function() probe, {
    String reason = 'condition was never met',
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final value = await probe();
        if (value != null) return value;
      } on Object {
        // Not ready yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail(reason);
  }

  /// Finds a free port by binding and releasing one.
  Future<int> freePort() async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  group('omnystore server', () {
    test('serves the API over a real port and persists to --data', () async {
      final port = await freePort();
      final server = launch([
        '--data',
        dataDir.path,
        'server',
        '--port',
        '$port',
        '--address',
        '127.0.0.1',
      ]);

      final base = 'http://127.0.0.1:$port';
      final health = await until(() async {
        final response = await http.get(Uri.parse('$base/health'));
        return response.statusCode == 200 ? response : null;
      }, reason: 'the server never became healthy');

      final body = jsonDecode(health.body) as Map<String, dynamic>;
      expect(body['status'], 'ok');
      expect(body['version'], omnyStoreVersion);
      expect(body['providers'], 1);

      // The banner tells the operator where things are, and warns that writes
      // are open when no token was set.
      expect(server.out.toString(), contains('/api/v1'));
      expect(server.out.toString(), contains(dataDir.path));
      expect(server.out.toString(), contains('writes:   OPEN'));

      // Writes land in the data directory, not just in memory.
      final created = await http.post(
        Uri.parse('$base/api/v1/organizations'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': 'acme'}),
      );
      expect(created.statusCode, 201);
      expect(
        File(
          p.join(dataDir.path, 'metadata', 'organizations.json'),
        ).existsSync(),
        isTrue,
      );

      // The node endpoint is mounted on the same port by default.
      final nodes = await http.get(Uri.parse('$base/_node'));
      expect(nodes.statusCode, 200);
    });

    test('requires a token for writes when one is configured', () async {
      final port = await freePort();
      launch([
        '--data',
        dataDir.path,
        'server',
        '--port',
        '$port',
        '--address',
        '127.0.0.1',
        '--publish-token',
        'secret-token',
      ]);

      final base = 'http://127.0.0.1:$port';
      await until(() async {
        final response = await http.get(Uri.parse('$base/health'));
        return response.statusCode == 200 ? response : null;
      });

      // Reads stay open — that is the point of a distribution platform.
      expect(
        (await http.get(Uri.parse('$base/api/v1/organizations'))).statusCode,
        200,
      );

      final anonymous = await http.post(
        Uri.parse('$base/api/v1/organizations'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': 'acme'}),
      );
      expect(anonymous.statusCode, 401);

      final authorised = await http.post(
        Uri.parse('$base/api/v1/organizations'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer secret-token',
        },
        body: jsonEncode({'name': 'acme'}),
      );
      expect(authorised.statusCode, 201);
    });

    test('serves CORS headers when an origin is allowed', () async {
      final port = await freePort();
      launch([
        '--data',
        dataDir.path,
        'server',
        '--port',
        '$port',
        '--address',
        '127.0.0.1',
        '--cors',
        'https://releases.example.com',
      ]);

      final base = 'http://127.0.0.1:$port';
      await until(() async {
        final response = await http.get(Uri.parse('$base/health'));
        return response.statusCode == 200 ? response : null;
      });

      final response = await http.get(
        Uri.parse('$base/api/v1/organizations'),
        headers: {'origin': 'https://releases.example.com'},
      );
      expect(
        response.headers['access-control-allow-origin'],
        'https://releases.example.com',
      );
    });

    test('can turn the node endpoint off', () async {
      final port = await freePort();
      final server = launch([
        '--data',
        dataDir.path,
        'server',
        '--port',
        '$port',
        '--address',
        '127.0.0.1',
        '--no-nodes',
      ]);

      final base = 'http://127.0.0.1:$port';
      await until(() async {
        final response = await http.get(Uri.parse('$base/health'));
        return response.statusCode == 200 ? response : null;
      });

      expect(server.out.toString(), isNot(contains('nodes:')));
      expect((await http.get(Uri.parse('$base/_node'))).statusCode, 404);
    });

    test('rejects an invalid port as a usage error', () async {
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        ['--data', dataDir.path, 'server', '--port', 'not-a-port'],
        environment: const {},
        out: out,
        err: out,
      );

      expect(code, 64);
      expect(out.toString(), contains('Invalid --port'));
    });

    test('rejects a half-configured TLS setup', () async {
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        [
          '--data',
          dataDir.path,
          'server',
          '--port',
          '0',
          '--tls-cert',
          '/nonexistent.pem',
        ],
        environment: const {},
        out: out,
        err: out,
      );

      expect(code, 64);
      expect(out.toString(), contains('must be given together'));
    });

    test('reports a missing TLS file as EX_NOINPUT', () async {
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        [
          '--data',
          dataDir.path,
          'server',
          '--port',
          '0',
          '--tls-cert',
          '/nonexistent.pem',
          '--tls-key',
          '/nonexistent.key',
        ],
        environment: const {},
        out: out,
        err: out,
      );

      expect(code, 66);
      expect(out.toString(), contains('TLS file not found'));
    });
  });

  group('omnystore node', () {
    test('registers with a hub and serves its organization', () async {
      final port = await freePort();
      launch([
        '--data',
        p.join(dataDir.path, 'hub'),
        'server',
        '--port',
        '$port',
        '--address',
        '127.0.0.1',
      ]);

      final base = 'http://127.0.0.1:$port';
      await until(() async {
        final response = await http.get(Uri.parse('$base/health'));
        return response.statusCode == 200 ? response : null;
      });

      launch([
        '--data',
        p.join(dataDir.path, 'node'),
        'node',
        '--hub',
        'ws://127.0.0.1:$port/_node',
        '--id',
        'node-eu',
        '--org',
        'acme',
        '--label',
        'region=eu',
        '--priority',
        '10',
      ]);

      // The node appears in the hub's provider list once it has registered.
      final providers = await until(() async {
        final response = await http.get(Uri.parse('$base/api/v1/providers'));
        final result = jsonDecode(response.body)['result'] as List<dynamic>;
        return result.any((p) => (p as Map)['id'] == 'node-eu') ? result : null;
      }, reason: 'the node never registered with the hub');

      final node =
          providers.firstWhere((p) => (p as Map)['id'] == 'node-eu')
              as Map<String, dynamic>;
      expect(node['kind'], 'node');
      expect(node['organizations'], ['acme']);
      expect((node['labels'] as Map)['region'], 'eu');
      expect(node['priority'], 10);

      // `acme` is now routed to the node rather than the hub's catch-all.
      final created = await http.post(
        Uri.parse('$base/api/v1/organizations'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': 'acme'}),
      );
      expect(created.statusCode, 201);

      await until(() async {
        final file = File(
          p.join(dataDir.path, 'node', 'metadata', 'organizations.json'),
        );
        if (!file.existsSync()) return null;
        return file.readAsStringSync().contains('acme') ? true : null;
      }, reason: 'the organization never landed on the node');
    });

    test('requires a hub endpoint', () async {
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        ['--data', dataDir.path, 'node', '--id', 'node-eu', '--org', 'acme'],
        environment: const {},
        out: out,
        err: out,
      );

      expect(code, 64);
      expect(out.toString(), contains('--hub'));
    });

    test('requires an id', () async {
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        [
          '--data',
          dataDir.path,
          'node',
          '--hub',
          'ws://127.0.0.1:1/_node',
          '--org',
          'acme',
        ],
        environment: const {},
        out: out,
        err: out,
      );

      expect(code, 64);
      expect(out.toString(), contains("node's id"));
    });

    test('requires at least one organization', () async {
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        [
          '--data',
          dataDir.path,
          'node',
          '--hub',
          'ws://127.0.0.1:1/_node',
          '--id',
          'node-eu',
        ],
        environment: const {},
        out: out,
        err: out,
      );

      expect(code, 64);
      expect(out.toString(), contains('at least one organization'));
    });

    test('rejects a malformed label', () async {
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        [
          '--data',
          dataDir.path,
          'node',
          '--hub',
          'ws://127.0.0.1:1/_node',
          '--id',
          'node-eu',
          '--org',
          'acme',
          '--label',
          'no-equals-sign',
        ],
        environment: const {},
        out: out,
        err: out,
      );

      expect(code, 64);
      expect(out.toString(), contains('key=value'));
    });
  });

  group('environment fallbacks', () {
    test('reads the registry and token from the environment', () async {
      final port = await freePort();
      launch([
        '--data',
        dataDir.path,
        'server',
        '--port',
        '$port',
        '--address',
        '127.0.0.1',
        '--publish-token',
        'env-token',
      ]);

      await until(() async {
        final response = await http.get(
          Uri.parse('http://127.0.0.1:$port/health'),
        );
        return response.statusCode == 200 ? response : null;
      });

      // No --server or --token flags: both come from the environment, which is
      // where a CI job puts a secret rather than on a visible command line.
      final out = StringBuffer();
      final code = await runOmnyStoreCli(
        ['org', 'create', 'acme'],
        environment: {
          'OMNYSTORE_URL': 'http://127.0.0.1:$port',
          'OMNYSTORE_TOKEN': 'env-token',
        },
        out: out,
        err: out,
      );

      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('Created organization acme'));
    });
  });
}
