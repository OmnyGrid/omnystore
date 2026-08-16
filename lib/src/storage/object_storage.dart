import 'package:meta/meta.dart';

import '../exceptions/omnystore_exception.dart';

/// A half-open-at-the-end byte range, in HTTP `Range` semantics: [start] and
/// [end] are both **inclusive**, and `end == null` means "to the end of the
/// object".
///
/// Inclusive-end is unusual for Dart, where ranges are normally half-open. It is
/// deliberate: this value is written straight into (and parsed straight out of)
/// a `Range: bytes=0-1023` header, and converting between conventions at each
/// boundary is exactly how off-by-one bugs get into a resumable downloader.
@immutable
class ByteRange {
  /// First byte to read, inclusive. Never negative.
  final int start;

  /// Last byte to read, inclusive, or `null` for "to the end".
  final int? end;

  /// Creates a range, validating that it is well-formed.
  ByteRange(this.start, [this.end]) {
    if (start < 0) {
      throw ValidationException(
        'Range start must not be negative (got $start)',
        field: 'range',
      );
    }
    final last = end;
    if (last != null && last < start) {
      throw ValidationException(
        'Range end ($last) must not precede its start ($start)',
        field: 'range',
      );
    }
  }

  /// A range covering everything from [start] onwards — the resume case.
  factory ByteRange.from(int start) => ByteRange(start);

  /// Parses an HTTP `Range` header value (`bytes=0-1023`, `bytes=500-`).
  ///
  /// Returns `null` for an absent, malformed, multi-range or suffix
  /// (`bytes=-500`) header. Returning `null` rather than throwing is
  /// deliberate: RFC 9110 says a range a server cannot satisfy must be
  /// *ignored* and the full representation served, not rejected.
  static ByteRange? parseHeader(String? header) {
    if (header == null) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    if (start == null) return null;
    final endText = match.group(2)!;
    if (endText.isEmpty) return ByteRange(start);
    final end = int.tryParse(endText);
    if (end == null || end < start) return null;
    return ByteRange(start, end);
  }

  /// The number of bytes this range covers given a total object size of
  /// [totalSize], clamped to what actually exists.
  int lengthFor(int totalSize) {
    if (start >= totalSize) return 0;
    final last = end == null || end! >= totalSize ? totalSize - 1 : end!;
    return last - start + 1;
  }

  /// Whether this range starts beyond the end of an object of [totalSize] —
  /// the condition that warrants a `416 Range Not Satisfiable`.
  bool isUnsatisfiableFor(int totalSize) => start >= totalSize && totalSize > 0;

  /// This range as an HTTP `Range` header value.
  String toHeaderValue() => 'bytes=$start-${end ?? ''}';

  /// The `Content-Range` header value for a response serving this range out of
  /// an object of [totalSize].
  String toContentRange(int totalSize) {
    final last = end == null || end! >= totalSize ? totalSize - 1 : end!;
    return 'bytes $start-$last/$totalSize';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ByteRange($start-${end ?? ''})';
}

/// Metadata about a stored object, as the backend reports it.
@immutable
class StoredObject {
  /// The key the object is stored under.
  final String key;

  /// Size in bytes.
  final int sizeBytes;

  /// Lower-case hex SHA-256 of the content, or `null` if the backend does not
  /// know it.
  ///
  /// [ObjectStorage.put] always computes it while streaming, so an object this
  /// package wrote has one. [ObjectStorage.head] may not: S3 and GCS only
  /// return the digest they were told at upload time, and an object placed in
  /// the bucket by some other tool has none.
  final String? sha256;

  /// MIME type, if the backend records one.
  final String? contentType;

  /// Last modification time (UTC), if known.
  final DateTime? modifiedAt;

  /// The backend's opaque entity tag, if any — used for conditional requests.
  final String? etag;

  /// Creates object metadata.
  const StoredObject({
    required this.key,
    required this.sizeBytes,
    this.sha256,
    this.contentType,
    this.modifiedAt,
    this.etag,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredObject &&
          other.key == key &&
          other.sizeBytes == sizeBytes &&
          other.sha256 == sha256 &&
          other.contentType == contentType &&
          other.modifiedAt == modifiedAt &&
          other.etag == etag;

  @override
  int get hashCode =>
      Object.hash(key, sizeBytes, sha256, contentType, modifiedAt, etag);

  @override
  String toString() => 'StoredObject($key, $sizeBytes bytes)';
}

/// An open read over a stored object: its metadata plus the byte stream.
///
/// The stream is live and unbuffered — a download of a 4 GB installer must not
/// materialise in the server's heap on its way to the client — so it can be
/// consumed exactly once.
class ObjectReader {
  /// Metadata for the object being read.
  final StoredObject object;

  /// The range actually being served, or `null` for the whole object.
  ///
  /// May be narrower than the range requested: a request for `bytes=500-9999`
  /// against a 1 KB object serves `500-1023`.
  final ByteRange? range;

  /// Bytes covering [range] (or the whole object). Consumable once.
  final Stream<List<int>> stream;

  /// The number of bytes [stream] will yield.
  final int length;

  /// Creates a reader.
  const ObjectReader({
    required this.object,
    required this.stream,
    required this.length,
    this.range,
  });

  /// Whether this read covers only part of the object — the caller must answer
  /// `206 Partial Content` rather than `200`.
  bool get isPartial => range != null && length != object.sizeBytes;

  @override
  String toString() =>
      'ObjectReader(${object.key}, $length bytes'
      '${range == null ? '' : ', $range'})';
}

/// The pluggable binary backend: where asset bytes actually live.
///
/// Everything above this line — the registry, the channels, the update service
/// — deals in metadata and never touches a byte of artifact content. That
/// separation is what lets one deployment keep artifacts in a directory on
/// disk, another in S3, another in GCS, and a fourth spread across a fleet of
/// nodes, with identical business logic. Implementations bundled here:
///
/// | Implementation | Bytes live in | Presigned URLs |
/// |---|---|---|
/// | `MemoryObjectStorage` | the heap | no |
/// | `LocalObjectStorage` | a local directory | no |
/// | `S3ObjectStorage` | an AWS S3 bucket | yes |
/// | `GcsObjectStorage` | a Google Cloud Storage bucket | yes |
///
/// **Implementing your own.** The contract is small on purpose. Honour these
/// and the rest of the system works unchanged:
///
/// * [put] streams — never buffer the whole object — computes the SHA-256 of
///   what it actually wrote, and verifies it against `expectedSha256` when one
///   is given, leaving nothing behind on mismatch.
/// * [get] throws [AssetNotFoundException] for a missing key rather than
///   returning an empty stream, and honours [ByteRange] when it can.
/// * [delete] is idempotent: deleting a key that is not there is a success.
/// * [presignedUrl] returns `null` when the backend cannot issue one, rather
///   than throwing. The caller then streams the bytes through itself.
abstract interface class ObjectStorage {
  /// A short identifier for this backend, used in logs and provider
  /// descriptors (`local`, `s3:my-bucket`, `gcs:my-bucket`).
  String get id;

  /// Whether this backend can issue presigned download URLs, so the caller can
  /// decide between redirecting a client and proxying the bytes without first
  /// asking for a URL and handling `null`.
  bool get supportsPresignedUrls;

  /// Streams [data] into [key], replacing anything already there.
  ///
  /// Returns the metadata of what was written, including the SHA-256 computed
  /// over the bytes as they streamed past.
  ///
  /// [length] is the expected size when the caller knows it (a `content-length`
  /// header, a file's size); backends that need it up front — S3 without
  /// multipart — use it, and it is verified against the bytes actually written.
  /// [expectedSha256] is verified after the last byte; on mismatch the object
  /// is removed and [ChecksumMismatchException] is thrown, so a corrupted
  /// upload never becomes a downloadable artifact.
  Future<StoredObject> put(
    String key,
    Stream<List<int>> data, {
    int? length,
    String contentType = 'application/octet-stream',
    String? expectedSha256,
    Map<String, String> metadata = const {},
  });

  /// Opens [key] for reading, optionally restricted to [range].
  ///
  /// Throws [AssetNotFoundException] if the key does not exist.
  Future<ObjectReader> get(String key, {ByteRange? range});

  /// Metadata for [key], or `null` if it does not exist.
  Future<StoredObject?> head(String key);

  /// Whether [key] exists.
  Future<bool> exists(String key);

  /// Deletes [key]. Succeeds whether or not it existed.
  Future<void> delete(String key);

  /// Keys under [prefix], at most [limit] of them, in lexicographic order.
  Future<List<String>> list({String? prefix, int? limit});

  /// A time-limited URL a client can fetch [key] from directly, or `null` if
  /// this backend cannot issue one.
  ///
  /// [filename] sets the `content-disposition` so the browser saves the
  /// artifact under its release name rather than its storage key.
  Future<Uri?> presignedUrl(
    String key, {
    Duration expiresIn = const Duration(minutes: 15),
    String? filename,
    String? contentType,
  });

  /// Total bytes stored, or `null` if the backend cannot compute it cheaply.
  ///
  /// Reported in the provider descriptor so placement can avoid a full node.
  /// `null` is a perfectly good answer — S3 has no cheap bucket size — and
  /// placement treats an unknown usage as "has room".
  Future<int?> usedBytes();

  /// Releases any resources (HTTP clients, file handles).
  Future<void> close();
}

/// Builds and parses the storage keys OmnyStore assigns to asset bytes.
///
/// The layout is hierarchical and human-readable:
///
/// ```text
/// orgs/{organization}/packages/{package}/{version}/{filename}
/// ```
///
/// Readability is not cosmetic here. When something goes wrong the operator is
/// looking at a bucket listing or a directory tree, and a flat namespace of
/// opaque ids gives them nothing to work with. The prefix structure also makes
/// "delete this release's artifacts" a prefix delete, and makes per-organization
/// lifecycle rules and cost attribution expressible in the cloud console.
class StorageKeys {
  const StorageKeys._();

  /// The key for [filename] within [version] of [package] under
  /// [organization].
  static String forAsset({
    required String organization,
    required String package,
    required String version,
    required String filename,
  }) => 'orgs/$organization/packages/$package/$version/$filename';

  /// The prefix covering every asset of one release.
  static String releasePrefix({
    required String organization,
    required String package,
    required String version,
  }) => 'orgs/$organization/packages/$package/$version/';

  /// The prefix covering every asset of one package.
  static String packagePrefix({
    required String organization,
    required String package,
  }) => 'orgs/$organization/packages/$package/';

  /// The prefix covering every asset of one organization.
  static String organizationPrefix(String organization) =>
      'orgs/$organization/';

  /// Rejects a key that could escape its prefix.
  ///
  /// A key reaches storage from an asset name that a publisher chose, and for
  /// the local-directory backend it becomes a filesystem path. `..` segments,
  /// absolute paths and backslashes are refused here, once, so no backend has
  /// to remember to do it. Returns [key] when it is safe.
  static String requireSafe(String key) {
    final unsafe =
        key.isEmpty ||
        key.startsWith('/') ||
        key.contains(r'\') ||
        key.contains('//') ||
        key.split('/').any((segment) => segment == '..' || segment == '.') ||
        key.codeUnits.any((c) => c < 0x20);
    if (unsafe) {
      throw ValidationException(
        "Unsafe storage key '$key': must be a relative, normalised, "
        "slash-separated path with no '.', '..' or control characters",
        field: 'storageKey',
      );
    }
    return key;
  }
}
