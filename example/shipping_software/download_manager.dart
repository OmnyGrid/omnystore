import 'dart:io';

import 'package:omnystore/omnystore.dart';

/// **6 — Downloading an artifact: resumable, and verified.**
///
/// [DownloadManager] streams to disk, resumes from whatever is already there,
/// retries a dropped transfer, and **deletes** anything that fails its
/// checksum. There is no flag to skip verification: an update mechanism that
/// hands an installer unverified bytes is a malware delivery channel for
/// anyone who can interpose on the network or write to the artifact store.
///
/// ```sh
/// dart run example/shipping_software/download_manager.dart
/// ```
Future<void> main() async {
  final store = await _seededStore();
  final release = await store.latestRelease('omnyagent');
  final asset = (await store.listAssets(release!.id)).single;

  // Where the client should fetch from. With S3 or GCS behind the provider
  // this is a presigned URL and no artifact byte crosses the registry; with a
  // local directory the server streams it instead.
  final target = await store.downloadTarget(asset.id);
  switch (target) {
    case RedirectDownload(:final url, :final expiresAt):
      print('Redirect to $url (valid until $expiresAt)');
    case StreamedDownload(:final providerId, :final reason):
      print('Streaming from $providerId — $reason');
  }

  final manager = DownloadManager(maxRetries: 3);
  final destination = Directory.systemTemp.createTempSync('omnystore_dl_');

  try {
    // In a real client the URL comes from `target` or from
    // `OmnyStoreClient.assetDownloadUrl`. Here the registry is in-process, so
    // the bytes are simply copied out.
    final file = File('${destination.path}/${asset.name}');
    final sink = file.openWrite();
    await sink.addStream((await store.openAsset(asset.id)).stream);
    await sink.close();

    // Expectations come from the registry record, so there is no way to forget
    // them.
    await manager.requireChecksum(file.path, asset.sha256);
    print('\nVerified ${file.path} against sha256 ${asset.sha256}');

    // Calling this on every application start is safe: an already-complete,
    // checksum-matching file transfers nothing.
    print(
      'Already correct on disk: '
      '${await manager.verifyChecksum(file.path, asset.sha256)}',
    );

    // What a real download looks like, against a running server:
    //
    //   final result = await manager.downloadAsset(
    //     asset: asset,
    //     url: client.assetDownloadUrl(asset.id),
    //     destination: '/opt/omnyagent',
    //     onProgress: (p) => stdout.write('\r${p.percent}%'),
    //   );
    //   print(result.resumed ? 'resumed' : 'fresh download');
  } finally {
    manager.close();
    destination.deleteSync(recursive: true);
    await store.close();
  }
}

Future<OmnyStore> _seededStore() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
  );
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
  );
  await store.attachAsset(
    releaseId: release.id,
    name: 'omnyagent-linux-x64.tar.gz',
    data: Stream.value(List.filled(64 * 1024, 7)),
    platform: 'linux-x64',
  );
  return store;
}
