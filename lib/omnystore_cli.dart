/// The `omnystore` command set, exposed as a library.
///
/// The CLI is a library first and an executable second: `runOmnyStoreCli`
/// takes its arguments, environment and output sinks as parameters, so the
/// whole command surface can be driven in-process — by a test, by a build
/// script, or by an application embedding the commands in its own tool.
///
/// ```dart
/// final out = StringBuffer();
/// final code = await runOmnyStoreCli(
///   ['release', 'latest', '--package', 'omnyagent'],
///   environment: {'OMNYSTORE_URL': 'https://store.example.com'},
///   out: out,
/// );
/// ```
///
/// The executables `bin/omnystore.dart` and `bin/omnystore_server.dart` are
/// thin wrappers over it.
library;

export 'omnystore.dart';
export 'omnystore_hub.dart';
export 'omnystore_node.dart';

export 'src/cli/cli_context.dart';
export 'src/cli/commands/release_commands.dart';
export 'src/cli/commands/resource_commands.dart';
export 'src/cli/commands/server_commands.dart';
export 'src/cli/omnystore_runner.dart';
