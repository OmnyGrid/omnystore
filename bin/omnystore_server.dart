import 'dart:io';

import 'package:omnystore/omnystore_cli.dart';

/// The `omnystore_server` entry point: `omnystore server` without the
/// subcommand.
///
/// Provided as its own executable because that is what a container image, a
/// systemd unit or a `Procfile` wants — one command with no argument to
/// remember.
///
/// ```sh
/// omnystore_server --data /var/lib/omnystore --port 8080
/// dart run omnystore:omnystore_server --data ./registry
/// ```
///
/// Every option `omnystore server` accepts works here unchanged.
Future<void> main(List<String> arguments) async {
  exitCode = await runOmnyStoreCli(['server', ...arguments]);
}
