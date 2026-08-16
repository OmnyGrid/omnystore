import 'dart:io';

import 'package:omnystore/omnystore_cli.dart';

/// The `omnystore` CLI.
///
/// ```sh
/// omnystore --help
/// omnystore server --data /var/lib/omnystore
/// omnystore release publish --package omnyagent --version 1.0.0
/// omnystore check-update --package omnyagent --current 1.0.0
/// ```
///
/// Exit codes: `0` success, `1` a runtime failure, `10` from `check-update`
/// when an update is available, `64` a usage error, `65` malformed input,
/// `66` a missing input file.
Future<void> main(List<String> arguments) async {
  exitCode = await runOmnyStoreCli(arguments);
}
