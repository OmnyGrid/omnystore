import 'dart:io';

import 'package:omnystore/omnystore.dart';

/// **8 — Choosing an object-storage backend.**
///
/// Everything above the storage layer deals in metadata and never touches an
/// artifact byte, so swapping the backend changes nothing else. What it does
/// change is **who carries the bytes**, which is the biggest performance
/// decision in a distribution platform:
///
/// | Backend | Bytes live in | Presigned URLs | Download path |
/// |---|---|---|---|
/// | `MemoryObjectStorage` | the heap | no | through the server |
/// | `LocalObjectStorage` | a directory | no | through the server |
/// | `S3ObjectStorage` | an S3 bucket | yes | client → bucket |
/// | `GcsObjectStorage` | a GCS bucket | with a key | client → bucket |
///
/// With presigning, the hub answers a download with a `302` and never sees the
/// artifact — the registry's bandwidth stops being the platform's ceiling.
///
/// ```sh
/// dart run example/storage/storage_backends.dart
/// ```
Future<void> main() async {
  // ------------------------------------------------- a local directory ---
  // The right starting point for a self-hosted single server: artifacts land
  // in a browsable, rsync-able tree, uploads are atomic, and each object gets
  // a checksum sidecar.
  final local = LocalObjectStorage('/var/lib/omnystore/objects');
  describe('local directory', local);

  // ------------------------------------------------------------- S3 ---
  final s3 = S3ObjectStorage(
    bucket: 'acme-releases',
    region: 'eu-west-1',
    // Reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN.
    credentials: EnvironmentAwsCredentialsProvider(Platform.environment),
    prefix: 'registry',
    storageClass: 'INTELLIGENT_TIERING',
  );
  describe('AWS S3', s3);

  // Any S3-compatible service — MinIO, Cloudflare R2, Backblaze B2, Ceph —
  // needs the endpoint and path-style addressing.
  final minio = S3ObjectStorage(
    bucket: 'releases',
    region: 'us-east-1',
    endpoint: Uri.parse('https://minio.internal:9000'),
    usePathStyle: true,
    credentials: StaticAwsCredentialsProvider.of(
      accessKeyId: Platform.environment['MINIO_KEY'] ?? 'minioadmin',
      secretAccessKey: Platform.environment['MINIO_SECRET'] ?? 'minioadmin',
    ),
  );
  describe('MinIO (S3-compatible)', minio);

  // ---------------------------------------------------- Google Cloud ---
  // With a service-account key, URLs are signed locally and clients fetch
  // straight from the bucket.
  //
  // `service-account*.json` is in this package's .gitignore, so dropping a
  // real key here to try the backend cannot be committed by accident.
  final keyFile = File('service-account.json');
  if (keyFile.existsSync()) {
    final gcs = GcsObjectStorage(
      bucket: 'acme-releases',
      credentials: GcpServiceAccountCredentials.fromJsonString(
        keyFile.readAsStringSync(),
      ),
    );
    describe('Google Cloud Storage (service account)', gcs);
    await gcs.close();
  }

  // Running *on* Google Cloud, the ambient identity needs no key file — but
  // there is then no private key to sign URLs with, so the hub streams
  // instead. Correct, just not free.
  final ambient = GcsObjectStorage(
    bucket: 'acme-releases',
    credentials: GcpMetadataServerCredentials(),
  );
  describe('Google Cloud Storage (workload identity)', ambient);

  await local.close();
  await s3.close();
  await minio.close();
  await ambient.close();
}

void describe(String label, ObjectStorage storage) {
  print(label);
  print('  id:        ${storage.id}');
  print(
    '  downloads: '
    '${storage.supportsPresignedUrls ? 'redirected straight to the store' : 'streamed through the server'}',
  );
}
