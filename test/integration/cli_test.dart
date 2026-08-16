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

  group('download', () {
    const platforms = ['linux-x64', 'macos-x64', 'macos-arm64', 'windows-x64'];

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

      final assets = <String>[];
      for (final platform in platforms) {
        final file = File(p.join(dataDir.path, 'omnyagent-$platform.tar.gz'))
          ..writeAsStringSync('build for $platform');
        assets.addAll(['--asset', '${file.path}:$platform']);
      }
      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
        ...assets,
      ]);
    });

    test('defaults to this machine, without being told', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli(['download', '--package', 'omnyagent', '-o', out.path]),
        0,
      );

      // Downloading an artifact almost always means "the one I can run".
      final downloaded = out.listSync().whereType<File>().single;
      expect(p.basename(downloaded.path), contains(Platforms.current));
      expect(downloaded.readAsStringSync(), 'build for ${Platforms.current}');
    });

    test('honours an explicit platform', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'windows-x64',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(
        out.listSync().whereType<File>().single.readAsStringSync(),
        'build for windows-x64',
      );
    });

    test('accepts a platform spelled another way', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      // `darwin-x86_64` is what several other toolchains call macos-x64.
      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'darwin-x86_64',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(
        out.listSync().whereType<File>().single.readAsStringSync(),
        'build for macos-x64',
      );
    });

    test(
      'reports an architecture with no build, listing what exists',
      () async {
        final code = await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'linux-arm64',
          '-o',
          dataDir.path,
        ]);

        expect(code, 1);
        expect(err.toString(), contains('no artifact for linux-arm64'));
        // Telling the user what *is* available saves a second round-trip.
        expect(err.toString(), contains('macos-arm64'));
      },
    );

    test('verifies the checksum as it copies', () async {
      final destination = Directory(p.join(dataDir.path, 'out'))..createSync();
      out.clear();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '-o',
          destination.path,
        ]),
        0,
      );

      // The bytes are checked against the digest on the asset record before
      // the command reports success.
      expect(out.toString(), contains('sha256 verified'));
    });

    test('--platform any falls back to choosing by name', () async {
      final code = await cli([
        'download',
        '--package',
        'omnyagent',
        '--platform',
        'any',
        '-o',
        dataDir.path,
      ]);

      // Four artifacts and no way to choose: a usage error listing them, not a
      // silent guess.
      expect(code, 64);
      expect(err.toString(), contains('4 artifacts'));
    });

    test('takes a list of platforms in one invocation', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'linux-x64',
          '--platform',
          'macos-arm64',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(
        out.listSync().whereType<File>().map((f) => p.basename(f.path)).toSet(),
        {'omnyagent-linux-x64.tar.gz', 'omnyagent-macos-arm64.tar.gz'},
      );
    });

    test('takes a comma-separated list too', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'linux-x64,windows-x64',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(out.listSync().whereType<File>(), hasLength(2));
    });

    test('--platform all takes every artifact in the release', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'all',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(
        out.listSync().whereType<File>().map((f) => p.basename(f.path)).toSet(),
        {for (final platform in platforms) 'omnyagent-$platform.tar.gz'},
      );
    });

    test(
      'creates the output directory for a multi-artifact download',
      () async {
        // `--platform all -o dist/` is how a release bundle is spelled, and
        // requiring `mkdir dist` first would be friction with no purpose.
        final out = Directory(p.join(dataDir.path, 'dist', 'nested'));
        expect(out.existsSync(), isFalse);

        expect(
          await cli([
            'download',
            '--package',
            'omnyagent',
            '--platform',
            'all',
            '-o',
            out.path,
          ]),
          0,
        );

        expect(out.listSync().whereType<File>(), hasLength(platforms.length));
      },
    );

    test('verifies every artifact of a multi-platform download', () async {
      final destination = Directory(p.join(dataDir.path, 'out'))..createSync();
      out.clear();

      await cli([
        'download',
        '--package',
        'omnyagent',
        '--platform',
        'all',
        '-o',
        destination.path,
      ]);

      // One verification line per artifact: a bundle where only the first was
      // checked would be a silent hole.
      expect(
        'sha256 verified'.allMatches(out.toString()),
        hasLength(platforms.length),
      );
    });

    test('deduplicates aliases that name the same artifact', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'macos-x64,darwin-x86_64',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(out.listSync().whereType<File>(), hasLength(1));
    });

    test('rejects "all" combined with a specific platform', () async {
      final code = await cli([
        'download',
        '--package',
        'omnyagent',
        '--platform',
        'all,linux-x64',
        '-o',
        dataDir.path,
      ]);

      expect(code, 64);
      expect(err.toString(), contains('selects on its own'));
    });

    test('fails the whole download if one platform has no build', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      final code = await cli([
        'download',
        '--package',
        'omnyagent',
        '--platform',
        'linux-x64,linux-arm64',
        '-o',
        out.path,
      ]);

      // Resolution happens before any byte is fetched, so a typo in the second
      // platform does not leave half a bundle on disk.
      expect(code, 1);
      expect(err.toString(), contains('no artifact for linux-arm64'));
      expect(out.listSync(), isEmpty);
    });
  });

  group('download by kind', () {
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

      // One platform carrying an installer, an archive, and the checksum file
      // that accompanies them.
      File(
        p.join(dataDir.path, 'omnyagent.dmg'),
      ).writeAsStringSync('installer');
      File(
        p.join(dataDir.path, 'omnyagent.tar.gz'),
      ).writeAsStringSync('archive');
      File(
        p.join(dataDir.path, 'omnyagent.tar.gz.sha256'),
      ).writeAsStringSync('digest');

      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
        '--asset',
        '${p.join(dataDir.path, 'omnyagent.dmg')}:macos-arm64:installer',
        '--asset',
        '${p.join(dataDir.path, 'omnyagent.tar.gz')}:macos-arm64:archive',
        '--asset',
        '${p.join(dataDir.path, 'omnyagent.tar.gz.sha256')}:macos-arm64',
      ]);
    });

    /// The filenames in [directory], for comparing a selection.
    Set<String> filesIn(Directory directory) => directory
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toSet();

    test('publishes the kind given in the asset spec', () async {
      final assets = await cliJson([
        'asset',
        'list',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
      ]);

      expect(
        {for (final a in assets) a['name']: a['kind']},
        {
          'omnyagent.dmg': 'installer',
          'omnyagent.tar.gz': 'archive',
          // Untagged, and inferred as auxiliary from its suffix.
          'omnyagent.tar.gz.sha256': null,
        },
      );
    });

    test('--kind installer takes only the installer', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'macos-arm64',
          '--kind',
          'installer',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(filesIn(out), {'omnyagent.dmg'});
    });

    test('--kind archive takes only the archive', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'macos-arm64',
          '--kind',
          'archive',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(filesIn(out), {'omnyagent.tar.gz'});
    });

    test('prefers the installer when no kind is given', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'macos-arm64',
          '-o',
          out.path,
        ]),
        0,
      );

      // The same order the update service uses, so `download` and
      // `check-update` cannot disagree about which artifact *is* the release.
      expect(filesIn(out), {'omnyagent.dmg'});
    });

    test('never picks a checksum file as the build itself', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      await cli([
        'download',
        '--package',
        'omnyagent',
        '--platform',
        'macos-arm64',
        '-o',
        out.path,
      ]);

      expect(filesIn(out), isNot(contains('omnyagent.tar.gz.sha256')));
    });

    test('--kind checksums fetches the accompanying file on request', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      // Untagged on publish; recognised by its suffix.
      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'macos-arm64',
          '--kind',
          'checksums',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(filesIn(out), {'omnyagent.tar.gz.sha256'});
    });

    test('takes a list of kinds', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'all',
          '--kind',
          'installer,archive',
          '-o',
          out.path,
        ]),
        0,
      );

      expect(filesIn(out), {'omnyagent.dmg', 'omnyagent.tar.gz'});
    });

    test('--platform all keeps the checksum files in the bundle', () async {
      final out = Directory(p.join(dataDir.path, 'out'))..createSync();

      expect(
        await cli([
          'download',
          '--package',
          'omnyagent',
          '--platform',
          'all',
          '-o',
          out.path,
        ]),
        0,
      );

      // A mirror wants the digests too; "all" means all.
      expect(filesIn(out), {
        'omnyagent.dmg',
        'omnyagent.tar.gz',
        'omnyagent.tar.gz.sha256',
      });
    });

    test('reports a kind with no artifact, listing what is present', () async {
      final code = await cli([
        'download',
        '--package',
        'omnyagent',
        '--kind',
        'sbom',
        '-o',
        dataDir.path,
      ]);

      expect(code, 1);
      expect(err.toString(), contains('no artifact of kind sbom'));
      expect(err.toString(), contains('installer'));
    });
  });

  group('check-update defaults to this machine', () {
    test('offers only a build this platform can install', () async {
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

      // A release built for one architecture only — and not this one.
      final other = Platforms.current == 'linux-x64'
          ? 'windows-x64'
          : 'linux-x64';
      final file = File(p.join(dataDir.path, 'omnyagent-$other.tar.gz'))
        ..writeAsStringSync('build for $other');
      await cli([
        'release',
        'publish',
        '--package',
        'omnyagent',
        '--version',
        '1.0.0',
        '--asset',
        '${file.path}:$other',
      ]);

      out.clear();
      expect(
        await cli([
          'check-update',
          '--package',
          'omnyagent',
          '--current',
          '0.9.0',
        ]),
        10,
      );
      // The update exists, but not one this machine can install.
      expect(out.toString(), contains('nothing to install'));
    });
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
