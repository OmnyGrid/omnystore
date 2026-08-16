import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../exceptions/omnystore_exception.dart';
import '../version.dart';
import 'cli_context.dart';
import 'commands/release_commands.dart';
import 'commands/resource_commands.dart';
import 'commands/server_commands.dart';

/// The `omnystore` command-line interface.
///
/// ```sh
/// omnystore server --data /var/lib/omnystore
/// omnystore node --hub wss://store.example.com/_node --id node-eu --org acme
///
/// omnystore org create acme
/// omnystore project create agent --org acme
/// omnystore package create omnyagent --project <project-id>
///
/// omnystore release publish --package omnyagent --version 1.0.0 \
///   --asset build/omnyagent-linux-x64.tar.gz:linux-x64
/// omnystore release latest --package omnyagent --channel beta
/// omnystore release promote <release-id> --to release
///
/// omnystore asset upload --release <id> --file dist/agent.tar.gz
/// omnystore download --package omnyagent --platform linux-x64 -o /tmp
/// omnystore check-update --package omnyagent --current 1.0.0
/// ```
///
/// Every command works against a remote server (`--server`) or a local data
/// directory (`--data`); the same code path drives both, so a workflow
/// developed locally runs unchanged against production.
class OmnyStoreCliRunner extends CommandRunner<int> {
  /// The environment options fall back to.
  final Map<String, String> environment;

  /// Where normal output goes.
  final StringSink out;

  /// Where errors go.
  final StringSink err;

  CliContext? _context;

  /// Creates the runner.
  OmnyStoreCliRunner({
    Map<String, String>? environment,
    StringSink? out,
    StringSink? err,
  }) : environment = environment ?? Platform.environment,
       out = out ?? stdout,
       err = err ?? stderr,
       super(
         'omnystore',
         'OmnyStore $omnyStoreVersion — release management and software '
             'distribution.',
       ) {
    CliContext.addGlobalOptions(argParser);

    Future<CliContext> context() async => _context ??= await CliContext.resolve(
      _topLevel!,
      this.environment,
      out: this.out,
      err: this.err,
    );

    addCommand(OrgCommand(context));
    addCommand(ProjectCommand(context));
    addCommand(PackageCommand(context));
    addCommand(ReleaseCommand(context));
    addCommand(AssetCommand(context));
    addCommand(DownloadCommand(context));
    addCommand(CheckUpdateCommand(context));
    addCommand(ProvidersCommand(context));

    // `server` and `node` read the *global* `--data`/`--verbose` options,
    // which do not exist until the top-level arguments are parsed. They get a
    // holder that is filled in by [runCommand] before either can run, so every
    // command is registered up front and `--help` lists them all.
    addCommand(ServerCommand(globals: _globals, environment: this.environment));
    addCommand(NodeCommand(globals: _globals, environment: this.environment));
  }

  final _LateGlobals _globals = _LateGlobals();

  ArgResults? _topLevel;

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    _topLevel = topLevelResults;
    _globals.results = topLevelResults;

    if (topLevelResults.flag('version')) {
      out.writeln('omnystore $omnyStoreVersion');
      return 0;
    }
    return super.runCommand(topLevelResults);
  }

  /// Runs [arguments], returning the process exit code.
  ///
  /// Every failure is translated into an exit code and a one-line message:
  /// `64` for a usage error, the exception's own code for a [CliException],
  /// `1` otherwise. Nothing escapes as a stack trace, because a CLI that
  /// prints one for a mistyped flag is unusable.
  Future<int> execute(List<String> arguments) async {
    try {
      return await run(arguments) ?? 0;
    } on UsageException catch (e) {
      err.writeln(e);
      return 64;
    } on CliException catch (e) {
      err.writeln('error: ${e.message}');
      return e.exitCode;
    } on OmnyStoreException catch (e) {
      err.writeln('error: ${e.message}');
      return 1;
    } on FormatException catch (e) {
      err.writeln('error: ${e.message}');
      return 65;
    } finally {
      await _context?.close();
    }
  }
}

/// An [ArgResultsSource] filled in once the top-level arguments are parsed.
///
/// Lets `server` and `node` be registered before parsing — so `--help` lists
/// them — while still reading global options at run time.
class _LateGlobals implements ArgResultsSource {
  ArgResults? results;

  @override
  String? option(String name) => results?.option(name);

  @override
  bool flag(String name) => results?.flag(name) ?? false;
}

/// Runs the CLI with [arguments] and returns the exit code.
///
/// The entry point `bin/omnystore.dart` calls; exposed so tests can drive the
/// whole CLI in-process without spawning a subprocess.
Future<int> runOmnyStoreCli(
  List<String> arguments, {
  Map<String, String>? environment,
  StringSink? out,
  StringSink? err,
}) => OmnyStoreCliRunner(
  environment: environment,
  out: out,
  err: err,
).execute(arguments);
