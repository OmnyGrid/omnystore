import 'dart:convert';
import 'dart:io';

import 'package:omnystore/omnystore.dart';
import 'package:path/path.dart' as p;

/// **17 — A registry that survives a restart.**
///
/// One directory holds everything: metadata as readable JSON, artifacts in a
/// browsable tree. Back it up with `rsync`, mount it as a volume, or `tar` it —
/// there is no database to dump.
///
/// [JsonFileRepositories] is a **write-through** store: a mutation does not
/// return until the bytes are on disk, and writes go to a temporary file and
/// are renamed into place, so a crash mid-write leaves the previous version
/// intact rather than a truncated one.
///
/// ```sh
/// dart run example/storage/persistent_registry.dart
/// ```
Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('omnystore_registry_');

  try {
    // ------------------------------------------------------ first run ---
    var store = await _open(root.path);
    final organization = await store.createOrganization(name: 'acme');
    final project = await store.createProject(
      organizationId: organization.id,
      name: 'agent',
    );
    final package = await store.createPackage(
      projectId: project.id,
      name: 'omnyagent',
    );
    final release = await store.publishRelease(
      packageReference: package.id,
      version: Version.parse('1.0.0'),
      notes: 'Durable across restarts.',
    );
    await store.attachAsset(
      releaseId: release.id,
      name: 'omnyagent-linux-x64.tar.gz',
      data: Stream.value(utf8.encode('<the artifact>')),
      platform: 'linux-x64',
    );
    await store.close();

    print('On disk under ${root.path}:');
    for (final entity in root.listSync(recursive: true).whereType<File>()) {
      final relative = p.relative(entity.path, from: root.path);
      print('  ${relative.padRight(58)} ${entity.lengthSync()} B');
    }

    // The metadata is meant to be read by an operator, not just by the server.
    final releases = File(p.join(root.path, 'metadata', 'releases.json'));
    print('\nreleases.json:');
    print(
      releases.readAsLinesSync().take(12).map((line) => '  $line').join('\n'),
    );

    // ----------------------------------------------------- second run ---
    // A fresh process, pointed at the same directory.
    store = await _open(root.path);
    final recovered = await store.latestRelease('omnyagent');
    print('\nAfter "restarting":');
    print('  latestRelease() => ${recovered!.version}');
    print('  notes           => ${recovered.notes}');

    final asset = (await store.listAssets(recovered.id)).single;
    final bytes = <int>[];
    await for (final chunk in (await store.openAsset(asset.id)).stream) {
      bytes.addAll(chunk);
    }
    print('  artifact        => "${utf8.decode(bytes)}"');
    print('  checksum intact => ${asset.sha256 == Checksums.sha256Hex(bytes)}');

    await store.close();
  } finally {
    root.deleteSync(recursive: true);
  }
}

/// Opens the registry rooted at [path].
///
/// The same two lines `omnystore server --data <path>` runs.
Future<OmnyStore> _open(String path) async => OmnyStore(
  repositories: await JsonFileRepositories.open(p.join(path, 'metadata')),
  storage: LocalObjectStorage(p.join(path, 'objects')),
);
