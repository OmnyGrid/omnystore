import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:omnyhub/omnyhub.dart' show Logger, LogLevel, NoopLogger;

import '../auth/auth_provider.dart';
import '../client/omnystore_client.dart';
import '../exceptions/omnystore_exception.dart';
import '../repositories/file/json_file_repositories.dart';
import '../services/omnystore.dart';
import '../services/omnystore_api.dart';
import '../storage/local_object_storage.dart';
import '../version.dart';

/// Where the CLI's global options come from, and how they resolve to a store.
///
/// The CLI works two ways and the same commands drive both:
///
/// * **Remote** (`--server https://store.example.com`) — an [OmnyStoreClient].
///   What CI and operators use.
/// * **Local** (`--data /var/lib/omnystore`) — an embedded [OmnyStore] over a
///   directory. What a single-machine registry uses, and what `omnystore
///   server` serves.
///
/// Options fall back to environment variables (`OMNYSTORE_URL`,
/// `OMNYSTORE_TOKEN`, `OMNYSTORE_DATA`), because a CI job should set a secret
/// once rather than repeat `--token` on every command — and because a token on
/// a command line is visible in the process table to every user on the machine.
class CliContext {
  /// The resolved store: a client or an embedded store.
  final OmnyStoreApi store;

  /// Whether output should be JSON rather than human-readable text.
  final bool jsonOutput;

  /// Whether to suppress progress and informational output.
  final bool quiet;

  /// Where normal output goes.
  final StringSink out;

  /// Where errors and progress go.
  final StringSink err;

  final Future<void> Function()? _onClose;

  /// Creates a context.
  CliContext({
    required this.store,
    this.jsonOutput = false,
    this.quiet = false,
    StringSink? out,
    StringSink? err,
    Future<void> Function()? onClose,
  }) : out = out ?? stdout,
       err = err ?? stderr,
       _onClose = onClose;

  /// Adds the global options every command shares to [parser].
  static void addGlobalOptions(ArgParser parser) {
    parser
      ..addOption(
        'server',
        abbr: 's',
        help:
            'Base URL of the OmnyStore server '
            '(default: \$OMNYSTORE_URL).',
        valueHelp: 'url',
      )
      ..addOption(
        'token',
        abbr: 't',
        help:
            'Bearer token for authentication '
            '(default: \$OMNYSTORE_TOKEN). Prefer the environment variable: a '
            'token on the command line is visible to every user on the '
            'machine.',
        valueHelp: 'token',
      )
      ..addOption(
        'data',
        abbr: 'd',
        help:
            'Run against a local registry directory instead of a server '
            '(default: \$OMNYSTORE_DATA).',
        valueHelp: 'dir',
      )
      ..addFlag(
        'json',
        help: 'Emit JSON instead of human-readable text.',
        negatable: false,
      )
      ..addFlag(
        'quiet',
        abbr: 'q',
        help: 'Suppress progress output.',
        negatable: false,
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Log what the CLI and server are doing.',
        negatable: false,
      )
      ..addFlag(
        'version',
        abbr: 'V',
        help: 'Print the omnystore version and exit.',
        negatable: false,
      );
  }

  /// Builds a context from parsed global [options] and the [environment].
  ///
  /// Throws [CliException] with an exit code of `64` (`EX_USAGE`) when neither
  /// a server nor a data directory is available — a usage error, not a runtime
  /// one, and worth distinguishing so CI can tell a misconfiguration from a
  /// failed publish.
  static Future<CliContext> resolve(
    ArgResults options,
    Map<String, String> environment, {
    StringSink? out,
    StringSink? err,
  }) async {
    final serverUrl = options.option('server') ?? environment['OMNYSTORE_URL'];
    final dataDir = options.option('data') ?? environment['OMNYSTORE_DATA'];
    final token = options.option('token') ?? environment['OMNYSTORE_TOKEN'];
    final jsonOutput = options.flag('json');
    final quiet = options.flag('quiet');

    if (serverUrl != null && dataDir != null) {
      throw const CliException(
        'Pass either --server or --data, not both: they select different '
        'registries and there is no sensible way to combine them.',
        exitCode: 64,
      );
    }

    if (dataDir != null) {
      final store = await openLocalStore(dataDir);
      return CliContext(
        store: store,
        jsonOutput: jsonOutput,
        quiet: quiet,
        out: out,
        err: err,
        onClose: store.close,
      );
    }

    if (serverUrl == null) {
      throw const CliException(
        'No registry selected. Pass --server <url> to use a remote registry, '
        'or --data <dir> to use a local one; or set OMNYSTORE_URL / '
        'OMNYSTORE_DATA.',
        exitCode: 64,
      );
    }

    final client = OmnyStoreClient(
      baseUrl: serverUrl,
      auth: token == null
          ? const AnonymousAuthProvider()
          : TokenAuthProvider(token),
      userAgent: 'omnystore-cli/$omnyStoreVersion',
    );
    return CliContext(
      store: client,
      jsonOutput: jsonOutput,
      quiet: quiet,
      out: out,
      err: err,
      onClose: client.close,
    );
  }

  /// Opens an embedded store rooted at [path].
  ///
  /// Metadata lives in `metadata/` as JSON and artifacts in `objects/`, so the
  /// whole registry is one directory that can be backed up, copied or mounted
  /// as a volume.
  static Future<OmnyStore> openLocalStore(
    String path, {
    Logger logger = const NoopLogger(),
    String providerId = 'local',
  }) async => OmnyStore(
    repositories: await JsonFileRepositories.open('$path/metadata'),
    storage: LocalObjectStorage('$path/objects'),
    logger: logger,
    providerId: providerId,
  );

  /// A logger writing structured lines to stderr, or a no-op when not
  /// [verbose].
  ///
  /// Logs go to stderr so `--json` output on stdout stays machine-parsable
  /// even with `--verbose` on.
  static Logger loggerFor({required bool verbose, StringSink? sink}) =>
      verbose ? _StderrLogger(sink ?? stderr) : const NoopLogger();

  /// Writes [message] followed by a newline, unless [quiet].
  void info(String message) {
    if (!quiet) out.writeln(message);
  }

  /// Writes [message] to stderr as progress, unless [quiet].
  void progress(String message) {
    if (!quiet) err.writeln(message);
  }

  /// Emits [data] as pretty-printed JSON.
  void writeJson(Object? data) =>
      out.writeln(const JsonEncoder.withIndent('  ').convert(data));

  /// Emits [models] as JSON when `--json` is set, otherwise renders [rows] as
  /// an aligned table.
  ///
  /// Every list command goes through here, so `--json` behaves identically
  /// across the CLI and a script never has to parse the human format.
  void writeTable(
    List<dynamic> models, {
    required List<String> headers,
    required List<List<String>> rows,
    String emptyMessage = 'Nothing to show.',
  }) {
    if (jsonOutput) {
      writeJson([for (final model in models) (model as dynamic).toJson()]);
      return;
    }
    if (rows.isEmpty) {
      info(emptyMessage);
      return;
    }

    final widths = List<int>.generate(headers.length, (i) => headers[i].length);
    for (final row in rows) {
      for (var i = 0; i < row.length && i < widths.length; i++) {
        if (row[i].length > widths[i]) widths[i] = row[i].length;
      }
    }

    String render(List<String> cells) => [
      for (var i = 0; i < cells.length; i++)
        i == cells.length - 1 ? cells[i] : cells[i].padRight(widths[i]),
    ].join('  ');

    out.writeln(render(headers));
    out.writeln([for (final width in widths) '-' * width].join('  '));
    for (final row in rows) {
      out.writeln(render(row));
    }
  }

  /// Emits a single [model] as JSON, or [text] when not in JSON mode.
  void writeOne(dynamic model, String text) {
    if (jsonOutput) {
      writeJson((model as dynamic).toJson());
    } else {
      out.writeln(text);
    }
  }

  /// Releases the store's resources.
  Future<void> close() async => _onClose?.call();
}

/// A [Logger] writing one structured line per record to a sink.
class _StderrLogger implements Logger {
  final StringSink _sink;
  final Map<String, Object?> _base;

  const _StderrLogger(this._sink, [this._base = const {}]);

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    final merged = {..._base, ...context};
    final suffix = merged.isEmpty
        ? ''
        : ' ${merged.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    _sink.writeln('[${level.name}] $message$suffix');
  }

  @override
  void debug(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.debug, message, context: context);

  @override
  void info(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.info, message, context: context);

  @override
  void warn(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.warn, message, context: context);

  @override
  void error(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.error, message, context: context);

  @override
  Logger child(Map<String, Object?> context) =>
      _StderrLogger(_sink, {..._base, ...context});
}
