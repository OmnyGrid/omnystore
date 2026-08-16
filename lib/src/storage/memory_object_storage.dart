import 'dart:typed_data';

import '../exceptions/omnystore_exception.dart';
import '../utils/checksum.dart';
import 'object_storage.dart';

/// An [ObjectStorage] holding every object in the heap.
///
/// The default for tests and for an embedded, ephemeral registry. It implements
/// the contract exactly — ranges, checksum verification, key safety — so a test
/// that passes against it is testing the same semantics the S3 and GCS backends
/// provide, not a simplified stand-in.
///
/// It cannot issue presigned URLs; callers stream bytes through instead.
///
/// **It is bounded by memory.** [maxTotalBytes] caps what it will hold and
/// throws [StorageException] past it, rather than growing until the process is
/// killed. Pass `null` to disable the cap when a test knows what it is doing.
class MemoryObjectStorage implements ObjectStorage {
  final Map<String, _Entry> _objects = {};

  /// The maximum total bytes retained, or `null` for unbounded.
  final int? maxTotalBytes;

  @override
  final String id;

  /// Creates an empty in-memory store holding at most [maxTotalBytes]
  /// (default 256 MiB).
  MemoryObjectStorage({
    this.id = 'memory',
    this.maxTotalBytes = 256 * 1024 * 1024,
  });

  @override
  bool get supportsPresignedUrls => false;

  /// The number of objects held.
  int get length => _objects.length;

  /// The keys held, in insertion order.
  Iterable<String> get keys => _objects.keys;

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
    final (bytes, checksum) = await ChecksumStream.collect(data);

    if (length != null && length != checksum.sizeBytes) {
      throw ValidationException(
        'Declared length $length does not match the '
        '${checksum.sizeBytes} bytes received for $key',
        field: 'length',
      );
    }
    if (expectedSha256 != null) {
      // Nothing has been stored yet, so a mismatch needs no cleanup — but the
      // check still happens before the object becomes visible, which is the
      // invariant the other backends have to work harder to keep.
      Checksums.require(expectedSha256, checksum.sha256);
    }

    final cap = maxTotalBytes;
    if (cap != null) {
      final existing = _objects[key]?.bytes.length ?? 0;
      final projected = _usedBytes() - existing + bytes.length;
      if (projected > cap) {
        throw StorageException(
          'MemoryObjectStorage capacity exceeded: storing $key would use '
          '$projected bytes of $cap',
          key: key,
        );
      }
    }

    final stored = StoredObject(
      key: key,
      sizeBytes: checksum.sizeBytes,
      sha256: checksum.sha256,
      contentType: contentType,
      modifiedAt: DateTime.now().toUtc(),
      etag: checksum.sha256,
    );
    _objects[key] = _Entry(bytes, stored, metadata);
    return stored;
  }

  @override
  Future<ObjectReader> get(String key, {ByteRange? range}) async {
    // Validated on every entry point, not just `put`. A backend that rejects
    // an unsafe key on write but tolerates it on read would make this
    // implementation a weaker test double than the backends it stands in for,
    // and a contract test passing here would prove nothing about them.
    StorageKeys.requireSafe(key);
    final entry = _objects[key];
    if (entry == null) throw AssetNotFoundException(key);

    final total = entry.bytes.length;
    if (range == null) {
      return ObjectReader(
        object: entry.object,
        stream: Stream.value(entry.bytes),
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
      object: entry.object,
      // `sublist` copies, so a later `put` replacing this key cannot mutate a
      // slice a reader is still holding.
      stream: Stream.value(
        Uint8List.sublistView(entry.bytes, range.start, range.start + count),
      ),
      length: count,
      range: range,
    );
  }

  @override
  Future<StoredObject?> head(String key) async {
    StorageKeys.requireSafe(key);
    return _objects[key]?.object;
  }

  @override
  Future<bool> exists(String key) async {
    StorageKeys.requireSafe(key);
    return _objects.containsKey(key);
  }

  @override
  Future<void> delete(String key) async {
    StorageKeys.requireSafe(key);
    _objects.remove(key);
  }

  @override
  Future<List<String>> list({String? prefix, int? limit}) async {
    final matched =
        _objects.keys
            .where((k) => prefix == null || k.startsWith(prefix))
            .toList()
          ..sort();
    if (limit == null || limit >= matched.length) return matched;
    return matched.sublist(0, limit < 0 ? 0 : limit);
  }

  @override
  Future<Uri?> presignedUrl(
    String key, {
    Duration expiresIn = const Duration(minutes: 15),
    String? filename,
    String? contentType,
  }) async => null;

  @override
  Future<int?> usedBytes() async => _usedBytes();

  @override
  Future<void> close() async => _objects.clear();

  int _usedBytes() =>
      _objects.values.fold(0, (sum, entry) => sum + entry.bytes.length);
}

class _Entry {
  final Uint8List bytes;
  final StoredObject object;
  final Map<String, String> metadata;

  _Entry(this.bytes, this.object, this.metadata);
}
