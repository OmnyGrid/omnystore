import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions/omnystore_exception.dart';
import '../utils/checksum.dart';
import 'object_storage.dart';

/// An [ObjectStorage] backed by a directory on the local filesystem.
///
/// The simplest production-viable backend, and the one a self-hosted single
/// server should start with: artifacts land under [root] in the same
/// hierarchical layout `StorageKeys` describes, so the tree is directly
/// browsable, `rsync`-able and backup-able.
///
/// ```text
/// /var/lib/omnystore/
///   orgs/acme/packages/omnyagent/1.2.0/omnyagent-linux-x64.tar.gz
///   orgs/acme/packages/omnyagent/1.2.0/.omnystore-meta.json
/// ```
///
/// **Durability.** Uploads are written to a temporary file in the same
/// directory and renamed into place only after the last byte lands and the
/// checksum verifies. `rename` within one filesystem is atomic, so a reader
/// never observes a half-written artifact and a crash mid-upload leaves a
/// stray temp file rather than a corrupt release. Temp files from earlier
/// crashed runs are swept by [sweepIncomplete].
///
/// **Sidecars.** The SHA-256 and content type are recorded in a
/// `.omnystore-meta.json` sidecar beside each object, because a filesystem has
/// nowhere else to put them. A missing sidecar is not an error — [head] then
/// reports a `null` checksum, exactly as an S3 object uploaded by another tool
/// would.
///
/// This backend cannot issue presigned URLs; the server streams the bytes.
class LocalObjectStorage implements ObjectStorage {
  /// The directory every object is stored under.
  final Directory root;

  /// Permissions applied to created directories, POSIX only.
  final int? directoryMode;

  @override
  final String id;

  /// Creates a store rooted at [root], creating the directory if needed.
  LocalObjectStorage(String root, {this.id = 'local', this.directoryMode})
    : root = Directory(p.normalize(p.absolute(root)));

  /// Creates a store rooted at an existing [Directory].
  LocalObjectStorage.fromDirectory(
    this.root, {
    this.id = 'local',
    this.directoryMode,
  });

  @override
  bool get supportsPresignedUrls => false;

  /// The suffix used for the metadata sidecar written beside each object.
  static const String metadataSuffix = '.omnystore-meta.json';

  /// The suffix used for in-progress uploads.
  static const String temporarySuffix = '.omnystore-partial';

  @override
  Future<StoredObject> put(
    String key,
    Stream<List<int>> data, {
    int? length,
    String contentType = 'application/octet-stream',
    String? expectedSha256,
    Map<String, String> metadata = const {},
  }) async {
    StorageKeys.requireSafe(key);
    final target = _fileFor(key);
    await target.parent.create(recursive: true);

    // A unique temp name per attempt, so two concurrent uploads of one key do
    // not write over each other's partial data before either renames.
    final temp = File(
      '${target.path}$temporarySuffix.'
      '${DateTime.now().microsecondsSinceEpoch}',
    );

    final digest = Sha256Accumulator();
    IOSink? sink;
    try {
      sink = temp.openWrite();
      await for (final chunk in data) {
        digest.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final checksum = digest.finish();
      if (length != null && length != checksum.sizeBytes) {
        throw ValidationException(
          'Declared length $length does not match the ${checksum.sizeBytes} '
          'bytes received for $key',
          field: 'length',
        );
      }
      if (expectedSha256 != null) {
        Checksums.require(expectedSha256, checksum.sha256);
      }

      final modifiedAt = DateTime.now().toUtc();
      // Rename last: until this succeeds, `key` either does not exist or still
      // holds the previous version. There is no window in which it holds a
      // partial one.
      await temp.rename(target.path);
      await _writeSidecar(
        key,
        sha256: checksum.sha256,
        sizeBytes: checksum.sizeBytes,
        contentType: contentType,
        modifiedAt: modifiedAt,
        metadata: metadata,
      );

      return StoredObject(
        key: key,
        sizeBytes: checksum.sizeBytes,
        sha256: checksum.sha256,
        contentType: contentType,
        modifiedAt: modifiedAt,
        etag: checksum.sha256,
      );
    } on OmnyStoreException {
      await _discard(sink, temp);
      rethrow;
    } on FileSystemException catch (e) {
      await _discard(sink, temp);
      throw StorageException('Cannot write $key: ${e.message}', key: key);
    }
  }

  @override
  Future<ObjectReader> get(String key, {ByteRange? range}) async {
    StorageKeys.requireSafe(key);
    final file = _fileFor(key);
    final stored = await _describe(key, file);
    if (stored == null) throw AssetNotFoundException(key);

    final total = stored.sizeBytes;
    if (range == null) {
      return ObjectReader(
        object: stored,
        stream: file.openRead(),
        length: total,
      );
    }
    if (range.isUnsatisfiableFor(total)) {
      throw ValidationException(
        'Range $range is not satisfiable for $key ($total bytes)',
        field: 'range',
      );
    }
    final count = range.lengthFor(total);
    return ObjectReader(
      object: stored,
      // `openRead`'s end is exclusive while ByteRange's is inclusive.
      stream: file.openRead(range.start, range.start + count),
      length: count,
      range: range,
    );
  }

  @override
  Future<StoredObject?> head(String key) async {
    StorageKeys.requireSafe(key);
    return _describe(key, _fileFor(key));
  }

  @override
  Future<bool> exists(String key) async {
    StorageKeys.requireSafe(key);
    return _fileFor(key).exists();
  }

  @override
  Future<void> delete(String key) async {
    StorageKeys.requireSafe(key);
    final file = _fileFor(key);
    if (await file.exists()) await file.delete();
    final sidecar = File('${file.path}$metadataSuffix');
    if (await sidecar.exists()) await sidecar.delete();
    // Prune the now-empty release/package/org directories so a store that has
    // had everything deleted does not leave an skeleton of empty folders.
    await _pruneEmptyParents(file.parent);
  }

  @override
  Future<List<String>> list({String? prefix, int? limit}) async {
    if (!await root.exists()) return const [];
    final keys = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root.path);
      final key = p.split(relative).join('/');
      if (key.endsWith(metadataSuffix) || key.contains(temporarySuffix)) {
        continue;
      }
      if (prefix != null && !key.startsWith(prefix)) continue;
      keys.add(key);
    }
    keys.sort();
    if (limit == null || limit >= keys.length) return keys;
    return keys.sublist(0, limit < 0 ? 0 : limit);
  }

  @override
  Future<Uri?> presignedUrl(
    String key, {
    Duration expiresIn = const Duration(minutes: 15),
    String? filename,
    String? contentType,
  }) async => null;

  @override
  Future<int?> usedBytes() async {
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  @override
  Future<void> close() async {}

  /// Deletes leftover `.omnystore-partial` files older than [olderThan],
  /// returning how many were removed.
  ///
  /// A crash between "open temp file" and "rename into place" leaves a partial
  /// file behind. Nothing reads them — [list] and [get] ignore the suffix — but
  /// they consume disk forever, so a long-lived server should call this at
  /// startup and periodically.
  Future<int> sweepIncomplete({
    Duration olderThan = const Duration(hours: 24),
  }) async {
    if (!await root.exists()) return 0;
    final cutoff = DateTime.now().subtract(olderThan);
    var removed = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.contains(temporarySuffix)) continue;
      final stat = await entity.stat();
      if (stat.modified.isAfter(cutoff)) continue;
      await entity.delete();
      removed++;
    }
    return removed;
  }

  File _fileFor(String key) {
    // `requireSafe` has already rejected `..`, absolute paths and backslashes,
    // so joining cannot escape. This re-checks the resolved path anyway: the
    // cost of being wrong here is arbitrary filesystem write access.
    final path = p.normalize(p.join(root.path, p.joinAll(key.split('/'))));
    if (!p.isWithin(root.path, path)) {
      throw ValidationException(
        "Storage key '$key' resolves outside the storage root",
        field: 'storageKey',
      );
    }
    return File(path);
  }

  Future<StoredObject?> _describe(String key, File file) async {
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final sidecar = await _readSidecar(file);
    return StoredObject(
      key: key,
      sizeBytes: stat.size,
      sha256: sidecar?['sha256'] as String?,
      contentType: sidecar?['contentType'] as String? ?? _guessContentType(key),
      modifiedAt: stat.modified.toUtc(),
      etag: sidecar?['sha256'] as String?,
    );
  }

  Future<Map<String, dynamic>?> _readSidecar(File file) async {
    final sidecar = File('${file.path}$metadataSuffix');
    if (!await sidecar.exists()) return null;
    try {
      final decoded = jsonDecode(await sidecar.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      // A corrupt sidecar must not make an otherwise readable artifact
      // undownloadable — degrade to "checksum unknown".
      return null;
    }
  }

  Future<void> _writeSidecar(
    String key, {
    required String sha256,
    required int sizeBytes,
    required String contentType,
    required DateTime modifiedAt,
    required Map<String, String> metadata,
  }) async {
    final sidecar = File('${_fileFor(key).path}$metadataSuffix');
    await sidecar.writeAsString(
      jsonEncode({
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'contentType': contentType,
        'modifiedAt': modifiedAt.toIso8601String(),
        if (metadata.isNotEmpty) 'metadata': metadata,
      }),
      flush: true,
    );
  }

  Future<void> _discard(IOSink? sink, File temp) async {
    try {
      await sink?.close();
    } on Object {
      // Already failing; a close error here would mask the real cause.
    }
    if (await temp.exists()) {
      try {
        await temp.delete();
      } on FileSystemException {
        // Swept later by `sweepIncomplete`.
      }
    }
  }

  Future<void> _pruneEmptyParents(Directory directory) async {
    var current = directory;
    while (p.isWithin(root.path, current.path)) {
      if (!await current.exists()) return;
      if (!await current.list().isEmpty) return;
      final parent = current.parent;
      try {
        await current.delete();
      } on FileSystemException {
        return;
      }
      current = parent;
    }
  }

  /// A best-effort MIME type from the key's extension, used when no sidecar
  /// recorded one.
  static String _guessContentType(String key) {
    final extension = p.extension(key).toLowerCase();
    return switch (extension) {
      '.gz' || '.tgz' => 'application/gzip',
      '.zip' => 'application/zip',
      '.tar' => 'application/x-tar',
      '.json' => 'application/json',
      '.txt' || '.md' => 'text/plain; charset=utf-8',
      '.exe' || '.msi' => 'application/vnd.microsoft.portable-executable',
      '.dmg' => 'application/x-apple-diskimage',
      '.deb' => 'application/vnd.debian.binary-package',
      '.rpm' => 'application/x-rpm',
      '.apk' => 'application/vnd.android.package-archive',
      '.sig' || '.asc' => 'application/pgp-signature',
      _ => 'application/octet-stream',
    };
  }
}
