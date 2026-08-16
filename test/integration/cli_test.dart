import 'dart:convert';
import 'dart:io';

import 'package:omnystore/omnystore_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives the whole CLI in-process against a local data directory.
///
/// `runOmnyStoreCli` takes its arguments, environment and output sinks as
/// parameters precisely so this is possible: the commands, the JSON file
/// repositories and the local object storage are all exercised for real, with
/// no subprocess and no mocking.
void main() {
  late Directory dataDir;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('omnystore_cli_');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    if (dataDir.existsSync()) await dataDir.delete(recursive: true);
  });

  /// Runs the CLI against the temporary data directory.
  Future<int> cli(List<String> arguments) => runOmnyStoreCli(
    ['--data', dataDir.path, ...arguments],
    // An empty environment, so a developer's own OMNYSTORE_URL cannot make
    // these tests talk to a real registry.
    environment: const {},
    out: out,
    err: err,
  );

  /// Runs the CLI with `--json` and decodes the result.
  Future<dynamic> cliJson(List<String> arguments) async {
    out.clear();
    final code = await cli(['--json', ...arguments]);
    expect(code, 0, reason: 'command failed: $err');
    return jsonDecode(out.toString());
  }

  group('usage', () {
    test('prints the version', () async {
      expect(await runOmnyStoreCli(['--version'], out: out, err: err), 0);
      expect(out.toString().trim(), 'omnystore $omnyStoreVersion');
    });

    test('reports a missing registry as a usage error', () async {
      final code = await runOmnyStoreCli(
        ['org', 'list'],
        environment: const {},
        out: out,
        err: err,
      );

      expect(code, 64, reason: 'EX_USAGE, distinguishable from a real failure');
      expect(err.toString(), contains('--server'));
      expect(err.toString(), contains('--data'));
    });

    test('rejects --server together with --data', () async {
      final code = await runOmnyStoreCli(
        ['--server', 'http://x', '--data', dataDir.path, 'org', 'list'],
        environment: const {},
        out: out,
        err: err,
      );

      expect(code, 64);
      expect(err.toString(), contains('not both'));
    });

    test('reports an unknown command without a stack trace', () async {
      final code = await runOmnyStoreCli(
        ['frobnicate'],
        environment: const {},
        out: out,
        err: err,
      );

      expect(code, 64);
      expect(err.toString(), contains('Could not find a command'));
      expect(err.toString(), isNot(contains('#0')));
    });
  });

  group('release lifecycle', () {
    late String projectId;

    setUp(() async {
      expect(await cli(['org', 'create', 'acme']), 0);
      final project = await cliJson([
        'project',
        'create',
        'agent',
        '--org',
        'acme',
      ]);
      projectId = project['id'] as String;
      expect(
        await cli([
          'package',
          'create',
          'omnyagent',
          '--project',
          projectId,
          '--platform',
          'linux-x64',
        ]),
        0,
      );
    });

    test('publishes a release with an artifact and reads it back', () async {
      final artifact = File(p.join(dataDir.path, 'agent-linux-x64.tar.gz'))
        ..writeAsStringSync('the payload');

      expect(
        await cli([
          'release',
          'publish',
          '--package',
          'omnyagent',
          '--version',
          '1.0.0',
          '--notes',
          'First release.',
          '--asset',
          '${artifact.path}:linux-x64',
        ]),
        0,
      );

      final latest = await cliJson([
        'release',
        'latest',
        '--package',
        'omnyagent',
      ]);
      expect(latest['version'], '1.0.0');
      expect(latest['channel'], 'release');
      expect(latest['notes'], 'First release.');

      final assets = await cliJson([
        'asset',
        'list',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
      ]);
      expect(assets, hasLength(1));
      expect(assets[0]['name'], 'agent-linux-x64.tar.gz');
      expect(assets[0]['platform'], 'linux-x64');
      expect(assets[0]['sha256'], Checksums.sha256OfString('the payload'));
    });

    test('derives the channel from the version', () async {
      for (final version in ['1.0.0', '1.1.0-beta.1', '1.2.0-dev.4']) {
        expect(
          await cli([
            'release',
            'publish',
            '--package',
            'omnyagent',
            '--version',
            version,
          ]),
          0,
        );
      }

      final releases = await cliJson([
        'release',
        'list',
        '--package',
        'omnyagent',
      ]);
      expect(
        {for (final r in releases) r['version']: r['channel']},
        {'1.2.0-dev.4': 'dev', '1.1.0-beta.1': 'beta', '1.0.0': 'release'},
      );
    });

    test('reports no release with a non-zero exit, not an error', () async {
      final code = await cli([
        'release',
        'latest',
        '--package',
        'omnyagent',
        '--channel',
        'beta',
      ]);

      // Non-zero so `if omnystore release latest …` works in a script, but not
      // an error message a CI log would flag as a failure.
      expect(code, 1);
      expect(err.toString(), contains('No beta release'));
    });

    test('release latest defaults to the stable channel', () async {
      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
      ]);
      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '2.0.0-beta.1',
      ]);

      // A deploy script that forgets --channel must never pick up a
      // pre-release.
      expect(
        (await cliJson([
          'release',
          'latest',
          '--package',
          'omnyagent',
        ]))['version'],
        '1.0.0',
      );
      expect(
        (await cliJson([
          'release',
          'latest',
          '--package',
          'omnyagent',
          '--channel',
          'any',
        ]))['version'],
        '2.0.0-beta.1',
      );
    });

    test('promotes a beta to stable, carrying artifacts across', () async {
      final artifact = File(p.join(dataDir.path, 'agent.tar.gz'))
        ..writeAsStringSync('payload');

      final beta = await cliJson([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.2.0-beta.3',
        '--asset',
        artifact.path,
      ]);

      final promoted = await cliJson([
        'release',
        'promote',
        beta['id'] as String,
        '--to',
        'release',
      ]);
      expect(promoted['version'], '1.2.0');

      final assets = await cliJson([
        'asset',
        'list',
        '--release',
        promoted['id'] as String,
      ]);
      expect(assets, hasLength(1));
      expect(assets[0]['sha256'], Checksums.sha256OfString('payload'));
    });

    test('yanks a release out of update offers and re-instates it', () async {
      final release = await cliJson([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
      ]);

      expect(
        await cli([
          'release',
          'yank',
          release['id'] as String,
          '--reason',
          'bad build',
        ]),
        0,
      );
      expect(
        await cli(['release', 'latest', '--package', 'omnyagent']),
        1,
        reason: 'a yanked release is no longer offered',
      );

      expect(
        await cli(['release', 'yank', release['id'] as String, '--undo']),
        0,
      );
      expect(await cli(['release', 'latest', '--package', 'omnyagent']), 0);
    });

    test('uploads an artifact and verifies its checksum', () async {
      final release = await cliJson([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
      ]);
      final artifact = File(p.join(dataDir.path, 'installer.bin'))
        ..writeAsStringSync('binary');

      final asset = await cliJson([
        'asset',
        'upload',
        '--release',
        release['id'] as String,
        '--file',
        artifact.path,
        '--platform',
        'linux-x64',
        '--kind',
        'installer',
      ]);

      expect(asset['name'], 'installer.bin');
      expect(asset['kind'], 'installer');
      expect(asset['sha256'], Checksums.sha256OfString('binary'));
    });

    test('reports a missing artifact file as EX_NOINPUT', () async {
      final release = await cliJson([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
      ]);

      final code = await cli([
        'asset',
        'upload',
        '--release',
        release['id'] as String,
        '--file',
        p.join(dataDir.path, 'does-not-exist.bin'),
      ]);

      expect(code, 66);
      expect(err.toString(), contains('File not found'));
    });
  });

  group('update checks', () {
    setUp(() async {
      await cli(['org', 'create', 'acme']);
      final project = await cliJson([
        'project',
        'create',
        'agent',
        '--org',
        'acme',
      ]);
      await cli([
        'package',
        'create',
        'omnyagent',
        '--project',
        project['id'] as String,
      ]);
      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
      ]);
    });

    test('exits 0 when current and 10 when an update exists', () async {
      expect(
        await cli([
          'check-update',
          '--package',
          'omnyagent',
          '--current',
          '1.0.0',
        ]),
        0,
      );
      expect(out.toString(), contains('up to date'));

      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.1.0',
      ]);

      out.clear();
      expect(
        await cli([
          'check-update',
          '--package',
          'omnyagent',
          '--current',
          '1.0.0',
        ]),
        10,
        reason: 'a distinct code lets a script branch without parsing output',
      );
      expect(out.toString(), contains('1.1.0 is available'));
    });

    test(
      'does not offer a pre-release unless the channel asks for it',
      () async {
        await cli([
          'release',
          'publish',
          '--package',
          'omnyagent',
          '--version',
          '2.0.0-beta.1',
        ]);

        expect(
          await cli([
            'check-update',
            '--package',
            'omnyagent',
            '--current',
            '1.0.0',
          ]),
          0,
        );
        expect(
          await cli([
            'check-update',
            '--package',
            'omnyagent',
            '--current',
            '1.0.0',
            '--channel',
            'beta',
          ]),
          10,
        );
      },
    );
  });

  group('persistence', () {
    test('a registry survives a restart', () async {
      await cli(['org', 'create', 'acme']);
      final project = await cliJson([
        'project',
        'create',
        'agent',
        '--org',
        'acme',
      ]);
      await cli([
        'package',
        'create',
        'omnyagent',
        '--project',
        project['id'] as String,
      ]);

      final artifact = File(p.join(dataDir.path, 'agent.tar.gz'))
        ..writeAsStringSync('durable payload');
      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
        '--asset',
        artifact.path,
      ]);

      // Every command above ran in its own CliContext, opening and closing the
      // JSON repositories each time — so this already proves durability across
      // process boundaries, not just within one run.
      final reread = await cliJson([
        'release',
        'latest',
        '--package',
        'omnyagent',
      ]);
      expect(reread['version'], '1.0.0');

      expect(
        File(p.join(dataDir.path, 'metadata', 'releases.json')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            dataDir.path,
            'objects',
            'orgs',
            'acme',
            'packages',
            'omnyagent',
            '1.0.0',
            'agent.tar.gz',
          ),
        ).readAsStringSync(),
        'durable payload',
      );
    });

    test('refuses to start on a corrupt metadata file', () async {
      await cli(['org', 'create', 'acme']);
      File(
        p.join(dataDir.path, 'metadata', 'organizations.json'),
      ).writeAsStringSync('{not json');

      final code = await cli(['org', 'list']);

      // Starting with an empty catalogue would look, to every client, exactly
      // like every organization having been deleted.
      expect(code, 1);
      expect(err.toString(), contains('Cannot parse'));
    });
  });

  group('providers', () {
    test('lists the local provider', () async {
      final providers = await cliJson(['providers']);

      expect(providers, hasLength(1));
      expect(providers[0]['kind'], 'hub');
      expect(providers[0]['servesAll'], isTrue);
    });
  });
}
