import 'dart:convert';
import 'dart:io';

import 'package:omnystore/omnystore_cli.dart';

/// **18 — Driving the CLI.**
///
/// The CLI is a library first and an executable second: `runOmnyStoreCli` takes
/// its arguments, environment and output sinks as parameters, so the whole
/// command surface runs in-process — in a test, a build script, or a tool that
/// embeds the commands in its own.
///
/// The equivalent shell session:
///
/// ```sh
/// export OMNYSTORE_DATA=./registry
///
/// omnystore org create acme
/// omnystore project create agent --org acme
/// omnystore package create omnyagent --project <project-id> --platform linux-x64
///
/// omnystore release publish --package omnyagent --version 1.0.0 \
///   --notes @CHANGELOG.md \
///   --asset build/omnyagent-linux-x64.tar.gz:linux-x64
///
/// omnystore release list   --package omnyagent
/// omnystore release latest --package omnyagent --channel beta
/// omnystore asset list     --package omnyagent --version 1.0.0
/// omnystore check-update   --package omnyagent --current 0.9.0   # exits 10
/// omnystore providers
/// ```
///
/// ```sh
/// dart run example/operating/cli_workflow.dart
/// ```
Future<void> main() async {
  final registry = Directory.systemTemp.createTempSync('omnystore_cli_');
  final artifact = File('${registry.path}/omnyagent-linux-x64.tar.gz')
    ..writeAsStringSync('<the artifact bytes>');

  /// Runs one command against the temporary registry, echoing it first.
  Future<int> run(List<String> arguments) async {
    final out = StringBuffer();
    final err = StringBuffer();
    stdout.writeln('\n\$ omnystore ${arguments.join(' ')}');

    final code = await runOmnyStoreCli(
      ['--data', registry.path, ...arguments],
      // An empty environment, so an ambient OMNYSTORE_URL cannot redirect this
      // at a real registry.
      environment: const {},
      out: out,
      err: err,
    );

    if (out.isNotEmpty) stdout.write(out);
    if (err.isNotEmpty) stdout.write(err);
    if (code != 0) stdout.writeln('(exit $code)');
    return code;
  }

  try {
    await run(['org', 'create', 'acme']);
    await run(['org', 'list']);

    // `--json` makes every list and create machine-readable, so a script never
    // parses the human format.
    final projectJson = StringBuffer();
    await runOmnyStoreCli(
      [
        '--data',
        registry.path,
        '--json',
        'project',
        'create',
        'agent',
        '--org',
        'acme',
      ],
      environment: const {},
      out: projectJson,
    );
    final projectId = jsonDecode(projectJson.toString())['id'] as String;
    stdout.writeln('\n(project id: $projectId)');

    await run([
      'package',
      'create',
      'omnyagent',
      '--project',
      projectId,
      '--platform',
      'linux-x64',
    ]);

    await run([
      'release',
      'publish',
      '--package',
      'omnyagent',
      '--version',
      '1.0.0',
      '--notes',
      'First stable release.',
      '--asset',
      '${artifact.path}:linux-x64',
    ]);

    await run([
      'release',
      'publish',
      '--package',
      'omnyagent',
      '--version',
      '1.1.0-beta.1',
    ]);

    await run(['release', 'list', '--package', 'omnyagent']);
    // Defaults to the release channel, so a deploy script that forgets the
    // flag never picks up the beta.
    await run(['release', 'latest', '--package', 'omnyagent']);
    await run([
      'release',
      'latest',
      '--package',
      'omnyagent',
      '--channel',
      'beta',
    ]);
    await run([
      'release',
      'latest',
      '--package',
      'omnyagent',
      '--channel',
      'any',
    ]);
    await run([
      'asset',
      'list',
      '--package',
      'omnyagent',
      '--version',
      '1.0.0',
    ]);
    await run(['providers']);

    // check-update exits 0 when current and 10 when an update exists, so a
    // shell script can branch without parsing output.
    await run(['check-update', '--package', 'omnyagent', '--current', '1.0.0']);
    await run(['check-update', '--package', 'omnyagent', '--current', '0.9.0']);
  } finally {
    registry.deleteSync(recursive: true);
  }
}
