import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnystore/omnystore_hub.dart';

/// **20 — Ranged downloads, which are what make resume work.**
///
/// The server advertises `accept-ranges: bytes` and answers a `Range` request
/// with `206 Partial Content` and a `content-range`. That is the whole
/// mechanism behind resuming a 4 GB installer interrupted at 90% for 400 MB
/// rather than 4 GB.
///
/// A ranged request is always served *by the registry*, never redirected: the
/// presigned URL covers the whole object, so redirecting would silently ignore
/// the range the client asked for and hand it the entire artifact.
///
/// ```sh
/// dart run example/shipping_software/ranged_downloads.dart
/// ```
Future<void> main() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    storage: MemoryObjectStorage(),
  );
  final server = OmnyStoreServer(store: store);
  await server.start(port: 0, address: '127.0.0.1');

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

  const payload = 'HEADER::the middle of the artifact::FOOTER';
  final asset = await store.attachAsset(
    releaseId: release.id,
    name: 'omnyagent-linux-x64.tar.gz',
    data: Stream.value(utf8.encode(payload)),
  );

  final url = Uri.parse(
    'http://127.0.0.1:${server.port}/api/v1/assets/${asset.id}/download',
  );

  // ------------------------------------------------------------- whole ---
  final whole = await http.get(url);
  print('GET (no range)  → ${whole.statusCode}');
  print('  accept-ranges:      ${whole.headers['accept-ranges']}');
  print('  content-length:     ${whole.headers['content-length']}');
  print('  x-omnystore-sha256: ${whole.headers['x-omnystore-sha256']}');
  print('  content-disposition: ${whole.headers['content-disposition']}');

  // ------------------------------------------------------------ ranged ---
  final head = await http.get(url, headers: {'range': 'bytes=0-7'});
  print('\nGET bytes=0-7   → ${head.statusCode}');
  print('  content-range: ${head.headers['content-range']}');
  print('  body:          "${head.body}"');

  // Open-ended: "everything from here", which is what a resume sends.
  final resume = await http.get(url, headers: {'range': 'bytes=36-'});
  print('\nGET bytes=36-   → ${resume.statusCode}');
  print('  content-range: ${resume.headers['content-range']}');
  print('  body:          "${resume.body}"');

  // A range past the end is clamped to what exists rather than erroring.
  final clamped = await http.get(url, headers: {'range': 'bytes=36-9999'});
  print('\nGET bytes=36-9999 → ${clamped.statusCode}');
  print('  content-range: ${clamped.headers['content-range']}');

  // A malformed or multi-range header is *ignored* and the whole
  // representation served, as RFC 9110 requires — not rejected.
  final ignored = await http.get(url, headers: {'range': 'bytes=0-5,10-15'});
  print('\nGET a multi-range → ${ignored.statusCode} (whole body served)');

  // ------------------------------------------------- resume in practice ---
  // Simulating a client that already has the first 20 bytes on disk.
  final partial = payload.substring(0, 20);
  final remainder = await http.get(
    url,
    headers: {'range': 'bytes=${partial.length}-'},
  );
  final reassembled = partial + remainder.body;
  print('\nResumed from ${partial.length} bytes:');
  print('  reassembled matches: ${reassembled == payload}');
  print(
    '  checksum matches:    '
    '${Checksums.sha256OfString(reassembled) == asset.sha256}',
  );

  await server.stop();
  await store.close();
}
