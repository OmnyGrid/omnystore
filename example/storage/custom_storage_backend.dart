import 'dart:convert';

import 'package:omnystore/omnystore.dart';

/// **9 — Implementing your own storage backend.**
///
/// [ObjectStorage] is deliberately small. Honour the five rules below and the
/// registry, the channels, the update service and the federation all work
/// unchanged over your backend — Azure Blob Storage, a content-addressed store,
/// an internal artifact service, whatever you have.
///
/// 1. `put` **streams** — never buffer the whole object — computes the SHA-256
///    of what it actually wrote, and verifies it against `expectedSha256`,
///    leaving nothing behind on mismatch.
/// 2. `get` throws [AssetNotFoundException] for a missing key rather than
///    returning an empty stream, and honours [ByteRange] when it can.
/// 3. `delete` is idempotent.
/// 4. `presignedUrl` returns `null` when it cannot issue one — the caller then
///    streams the bytes itself. Returning `null` is a normal answer, not a
///    failure.
/// 5. Every entry point rejects an unsafe key with `StorageKeys.requireSafe`.
///
/// ```sh
/// dart run example/storage/custom_storage_backend.dart
/// ```
Future<void> main() async {
  final store = OmnyStore(
    repositories: MemoryRepositories(),
    // The registry cannot tell this apart from S3.
    storage: CountingObjectStorage(MemoryObjectStorage()),
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
  final asset = await store.attachAsset(
    releaseId: release.id,
    name: 'agent.tar.gz',
    data: Stream.value(utf8.encode('payload')),
  );
  await (await store.openAsset(asset.id)).stream.drain<void>();

  final storage = store.storage as CountingObjectStorage;
  print('writes: ${storage.writes}, reads: ${storage.reads}');

  await store.close();
}

/// A decorator that counts operations, delegating everything else.
///
/// The shape most real custom backends take when they add caching, metrics or
/// a second tier: wrap an existing [ObjectStorage] rather than reimplementing
/// the contract.
class CountingObjectStorage implements ObjectStorage {
  /// The backend being wrapped.
  final ObjectStorage inner;

  /// How many objects have been written.
  int writes = 0;

  /// How many objects have been opened for reading.
  int reads = 0;

  /// Wraps [inner].
  CountingObjectStorage(this.inner);

  @override
  String get id => 'counting(${inner.id})';

  @override
  bool get supportsPresignedUrls => inner.supportsPresignedUrls;

  @override
  Future<StoredObject> put(
    String key,
    Stream<List<int>> data, {
    int? length,
    String contentType = 'application/octet-stream',
    String? expectedSha256,
    Map<String, String> metadata = const {},
  }) async {
    writes++;
    return inner.put(
      key,
      data,
      length: length,
      contentType: contentType,
      expectedSha256: expectedSha256,
      metadata: metadata,
    );
  }

  @override
  Future<ObjectReader> get(String key, {ByteRange? range}) {
    reads++;
    return inner.get(key, range: range);
  }

  @override
  Future<StoredObject?> head(String key) => inner.head(key);

  @override
  Future<bool> exists(String key) => inner.exists(key);

  @override
  Future<void> delete(String key) => inner.delete(key);

  @override
  Future<List<String>> list({String? prefix, int? limit}) =>
      inner.list(prefix: prefix, limit: limit);

  @override
  Future<Uri?> presignedUrl(
    String key, {
    Duration expiresIn = const Duration(minutes: 15),
    String? filename,
    String? contentType,
  }) => inner.presignedUrl(
    key,
    expiresIn: expiresIn,
    filename: filename,
    contentType: contentType,
  );

  @override
  Future<int?> usedBytes() => inner.usedBytes();

  @override
  Future<void> close() => inner.close();
}
