import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../exceptions/omnystore_exception.dart';
import '../../utils/checksum.dart';
import '../../utils/http_dates.dart';
import '../object_storage.dart';
import 'aws_credentials.dart';
import 'sig_v4.dart';

/// An [ObjectStorage] backed by an AWS S3 bucket, or any S3-compatible service
/// (MinIO, Cloudflare R2, Backblaze B2, Ceph, DigitalOcean Spaces).
///
/// ```dart
/// final storage = S3ObjectStorage(
///   bucket: 'acme-releases',
///   region: 'eu-west-1',
///   credentials: EnvironmentAwsCredentialsProvider(Platform.environment),
/// );
/// ```
///
/// For an S3-compatible service, give the [endpoint] and force path-style
/// addressing:
///
/// ```dart
/// final storage = S3ObjectStorage(
///   bucket: 'releases',
///   region: 'us-east-1',
///   endpoint: Uri.parse('https://minio.internal:9000'),
///   usePathStyle: true,
///   credentials: StaticAwsCredentialsProvider.of(
///     accessKeyId: '…', secretAccessKey: '…',
///   ),
/// );
/// ```
///
/// **Presigned downloads.** [supportsPresignedUrls] is `true`, so the hub
/// answers a download with a `302` at the bucket instead of streaming the
/// artifact through itself. This is the whole reason to use S3 here: the
/// registry's bandwidth stops being the distribution platform's ceiling.
///
/// **Uploads are single-part.** Artifacts stream in one signed `PUT` with an
/// `UNSIGNED-PAYLOAD` signature, which S3 caps at 5 GB. Larger artifacts need
/// the multipart API; [put] fails cleanly with a [StorageException] rather than
/// truncating, so the limit is visible rather than silent.
class S3ObjectStorage implements ObjectStorage {
  /// The bucket objects live in.
  final String bucket;

  /// The AWS region used for signing (`eu-west-1`). S3-compatible services that
  /// do not care still need a value; `us-east-1` is the conventional one.
  final String region;

  /// Supplies the credentials each request is signed with.
  final AwsCredentialsProvider credentials;

  /// A key prefix applied to every object, so one bucket can host several
  /// registries. Normalised to end with `/`, or empty.
  final String prefix;

  /// The service endpoint, or `null` for the standard AWS one.
  final Uri? endpoint;

  /// Whether to address objects as `endpoint/bucket/key` rather than
  /// `bucket.endpoint/key`.
  ///
  /// Required by most self-hosted S3-compatible services, which have no
  /// wildcard DNS for virtual-host addressing.
  final bool usePathStyle;

  /// The `x-amz-storage-class` applied to uploads (`STANDARD`,
  /// `INTELLIGENT_TIERING`, `GLACIER_IR`), or `null` for the bucket default.
  final String? storageClass;

  /// The server-side encryption mode (`AES256`, `aws:kms`), or `null` for the
  /// bucket default.
  final String? serverSideEncryption;

  final http.Client _http;
  final bool _ownsClient;

  /// The maximum size of a single-part `PUT`, which is what [put] uses.
  static const int maxSinglePartBytes = 5 * 1024 * 1024 * 1024;

  /// The user-metadata key the SHA-256 is recorded under.
  ///
  /// S3's own `etag` is an MD5 for single-part uploads and something else
  /// entirely for multipart ones, so it is never a SHA-256 — the digest has to
  /// travel in user metadata to survive at all.
  static const String _sha256Metadata = 'sha256';

  /// Creates an S3-backed store.
  ///
  /// Pass [httpClient] to share a connection pool with the rest of the process;
  /// otherwise one is created and closed with this store.
  S3ObjectStorage({
    required this.bucket,
    required this.region,
    required this.credentials,
    String prefix = '',
    this.endpoint,
    this.usePathStyle = false,
    this.storageClass,
    this.serverSideEncryption,
    http.Client? httpClient,
  }) : prefix = _normalizePrefix(prefix),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  @override
  String get id => 's3:$bucket';

  @override
  bool get supportsPresignedUrls => true;

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
    if (length != null && length > maxSinglePartBytes) {
      throw StorageException(
        'Object $key is $length bytes, above the $maxSinglePartBytes-byte '
        'single-part upload limit; multipart upload is not implemented',
        key: key,
      );
    }

    // S3 needs `content-length` up front, and a signed streaming upload cannot
    // discover it as it goes. When the caller knows the size the bytes stream
    // straight through; when it does not, they are buffered so the length can
    // be computed — which is why every internal caller passes it.
    final ChecksumResult checksum;
    final http.BaseRequest request;
    final url = _urlFor(key);

    if (length != null) {
      late ChecksumResult observed;
      final counted = ChecksumStream.transform(data, (r) => observed = r);
      final streamed = http.StreamedRequest('PUT', url);
      unawaitedPipe(counted, streamed);
      streamed.contentLength = length;
      request = streamed;
      // Populated by the time the response arrives, because the request cannot
      // complete before the body stream closes.
      checksum = await _sendAndDescribe(request, key, contentType, {
        ...metadata,
        // Only recordable when the caller already knows it: headers go out
        // before the first byte of a streamed body, so the digest computed
        // *during* the upload cannot be attached to the same request. S3 has
        // no metadata-only update — changing it means a server-side COPY of
        // the whole object — so paying that on every upload to populate an
        // informational field would be a bad trade. See `head`.
        if (expectedSha256 != null)
          _sha256Metadata: expectedSha256.toLowerCase(),
      }, () => observed);
      if (checksum.sizeBytes != length) {
        // The object is already in the bucket at this point; remove it rather
        // than leave a truncated artifact that would fail every download.
        await delete(key);
        throw ValidationException(
          'Declared length $length does not match the ${checksum.sizeBytes} '
          'bytes uploaded for $key',
          field: 'length',
        );
      }
    } else {
      final (bytes, computed) = await ChecksumStream.collect(data);
      if (bytes.length > maxSinglePartBytes) {
        throw StorageException(
          'Object $key is ${bytes.length} bytes, above the '
          '$maxSinglePartBytes-byte single-part upload limit',
          key: key,
        );
      }
      final plain = http.Request('PUT', url)..bodyBytes = bytes;
      request = plain;
      checksum = await _sendAndDescribe(
        request,
        key,
        contentType,
        // The body was buffered, so the digest is known before the request is
        // sent and can be recorded for `head` to read back.
        {...metadata, _sha256Metadata: computed.sha256},
        () => computed,
      );
    }

    if (expectedSha256 != null &&
        !Checksums.matches(expectedSha256, checksum.sha256)) {
      await delete(key);
      throw ChecksumMismatchException(
        expected: expectedSha256.toLowerCase(),
        actual: checksum.sha256,
      );
    }

    return StoredObject(
      key: key,
      sizeBytes: checksum.sizeBytes,
      sha256: checksum.sha256,
      contentType: contentType,
      modifiedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<ObjectReader> get(String key, {ByteRange? range}) async {
    StorageKeys.requireSafe(key);
    final request = http.Request('GET', _urlFor(key));
    if (range != null) request.headers['range'] = range.toHeaderValue();
    final response = await _send(
      request,
      key,
      payloadHash: SigV4.emptyPayloadHash,
    );

    if (response.statusCode == 404) {
      await response.stream.drain<void>();
      throw AssetNotFoundException(key);
    }
    if (response.statusCode == 416) {
      await response.stream.drain<void>();
      throw ValidationException(
        'Range $range is not satisfiable for $key',
        field: 'range',
      );
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw await _errorFor(response, key, 'read');
    }

    final total = _totalSizeOf(response);
    final length = response.contentLength ?? total;
    return ObjectReader(
      object: StoredObject(
        key: key,
        sizeBytes: total,
        sha256: _checksumHeaderOf(response.headers),
        contentType: response.headers['content-type'],
        modifiedAt: _parseHttpDate(response.headers['last-modified']),
        etag: _unquote(response.headers['etag']),
      ),
      stream: response.stream,
      length: length,
      range: response.statusCode == 206 ? range : null,
    );
  }

  @override
  Future<StoredObject?> head(String key) async {
    StorageKeys.requireSafe(key);
    final response = await _send(
      http.Request('HEAD', _urlFor(key)),
      key,
      payloadHash: SigV4.emptyPayloadHash,
    );
    await response.stream.drain<void>();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw await _errorFor(response, key, 'stat');
    }
    return StoredObject(
      key: key,
      sizeBytes: response.contentLength ?? 0,
      sha256: _checksumHeaderOf(response.headers),
      contentType: response.headers['content-type'],
      modifiedAt: _parseHttpDate(response.headers['last-modified']),
      etag: _unquote(response.headers['etag']),
    );
  }

  @override
  Future<bool> exists(String key) async => await head(key) != null;

  @override
  Future<void> delete(String key) async {
    StorageKeys.requireSafe(key);
    final response = await _send(
      http.Request('DELETE', _urlFor(key)),
      key,
      payloadHash: SigV4.emptyPayloadHash,
    );
    await response.stream.drain<void>();
    // S3 answers 204 whether or not the key existed, which is the idempotent
    // delete the contract asks for.
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw await _errorFor(response, key, 'delete');
    }
  }

  @override
  Future<List<String>> list({String? prefix, int? limit}) async {
    final keys = <String>[];
    String? continuationToken;

    // ListObjectsV2 pages at 1000 keys; keep going until the caller's limit is
    // met or the bucket is exhausted.
    do {
      final query = <String, String>{
        'list-type': '2',
        'prefix': '${this.prefix}${prefix ?? ''}',
        if (limit != null) 'max-keys': '${limit - keys.length}',
        'continuation-token': ?continuationToken,
      };
      final response = await _send(
        http.Request('GET', _bucketUrl().replace(queryParameters: query)),
        '',
        payloadHash: SigV4.emptyPayloadHash,
      );
      final body = await response.stream.bytesToString();
      if (response.statusCode != 200) {
        throw StorageException(
          'S3 list failed with ${response.statusCode}: ${_messageIn(body)}',
        );
      }
      for (final raw in _xmlValues(body, 'Key')) {
        final key = raw.startsWith(this.prefix)
            ? raw.substring(this.prefix.length)
            : raw;
        keys.add(key);
      }
      continuationToken = _xmlValues(body, 'NextContinuationToken').firstOrNull;
      if (limit != null && keys.length >= limit) break;
    } while (continuationToken != null);

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
  }) async {
    StorageKeys.requireSafe(key);
    return SigV4.presign(
      credentials: await credentials.credentials(),
      method: 'GET',
      url: _urlFor(key),
      region: region,
      service: 's3',
      now: DateTime.now().toUtc(),
      expiresIn: expiresIn,
      extraQuery: {
        if (filename != null)
          'response-content-disposition':
              'attachment; filename="${_sanitizeFilename(filename)}"',
        'response-content-type': ?contentType,
      },
    );
  }

  @override
  Future<int?> usedBytes() async {
    // S3 has no cheap bucket-size call, and walking every key of a large bucket
    // on each provider heartbeat would be worse than not knowing. Placement
    // treats `null` as "has room", which is the right default for a bucket.
    return null;
  }

  @override
  Future<void> close() async {
    if (_ownsClient) _http.close();
  }

  /// Feeds [source] into [request]'s sink and closes it, without awaiting —
  /// the request is sent concurrently with the body being produced.
  ///
  /// Named rather than inlined so the deliberate lack of an `await` is
  /// obvious: awaiting here would deadlock, because the sink is not drained
  /// until the request is sent.
  static void unawaitedPipe(
    Stream<List<int>> source,
    http.StreamedRequest request,
  ) {
    source.listen(
      request.sink.add,
      onError: request.sink.addError,
      onDone: request.sink.close,
      cancelOnError: true,
    );
  }

  Future<ChecksumResult> _sendAndDescribe(
    http.BaseRequest request,
    String key,
    String contentType,
    Map<String, String> metadata,
    ChecksumResult Function() checksum,
  ) async {
    request.headers['content-type'] = contentType;
    if (storageClass != null) {
      request.headers['x-amz-storage-class'] = storageClass!;
    }
    if (serverSideEncryption != null) {
      request.headers['x-amz-server-side-encryption'] = serverSideEncryption!;
    }
    for (final entry in metadata.entries) {
      request.headers['x-amz-meta-${entry.key.toLowerCase()}'] = entry.value;
    }

    final response = await _send(
      request,
      key,
      payloadHash: SigV4.unsignedPayload,
    );
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw StorageException(
        'S3 upload of $key failed with ${response.statusCode}: '
        '${_messageIn(body)}',
        key: key,
      );
    }
    return checksum();
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request,
    String key, {
    required String payloadHash,
  }) async {
    final signed = await SigV4.signRequest(
      credentials: await credentials.credentials(),
      method: request.method,
      url: request.url,
      region: region,
      service: 's3',
      now: DateTime.now().toUtc(),
      headers: {
        // Only headers that are already on the request may be signed; anything
        // http adds later (content-length on a plain Request) is unsigned, and
        // S3 does not require it to be.
        for (final entry in request.headers.entries)
          if (_isSignable(entry.key)) entry.key.toLowerCase(): entry.value,
      },
      payloadHash: payloadHash,
    );
    request.headers.addAll(signed);
    try {
      return await _http.send(request);
    } on http.ClientException catch (e) {
      throw StorageException(
        'S3 request for ${key.isEmpty ? bucket : key} failed: ${e.message}',
        key: key.isEmpty ? null : key,
      );
    }
  }

  /// Whether a header should be included in the signature.
  ///
  /// `content-length` is excluded because `package:http` sets it after signing
  /// for a plain request; signing a value that then changes would guarantee a
  /// mismatch.
  static bool _isSignable(String name) {
    final lower = name.toLowerCase();
    return lower != 'content-length' && lower != 'authorization';
  }

  Future<StorageException> _errorFor(
    http.StreamedResponse response,
    String key,
    String operation,
  ) async {
    final body = await response.stream.bytesToString();
    return StorageException(
      'S3 $operation of $key failed with ${response.statusCode}: '
      '${_messageIn(body)}',
      key: key,
    );
  }

  Uri _bucketUrl() {
    final base = endpoint;
    if (base == null) {
      return Uri.https(
        usePathStyle
            ? 's3.$region.amazonaws.com'
            : '$bucket.s3.$region.amazonaws.com',
        usePathStyle ? '/$bucket' : '/',
      );
    }
    return usePathStyle
        ? base.replace(path: '${_trimSlashes(base.path)}/$bucket')
        : base.replace(host: '$bucket.${base.host}');
  }

  Uri _urlFor(String key) {
    final full = '$prefix$key';
    final base = _bucketUrl();
    final basePath = _trimSlashes(base.path);
    return base.replace(
      path: basePath.isEmpty ? '/$full' : '/$basePath/$full',
      // Drop any query the base endpoint carried; it is not part of an object
      // URL and would corrupt the canonical request.
      queryParameters: null,
    );
  }

  /// The object's full size, taken from `content-range` for a partial response
  /// and from `content-length` otherwise.
  static int _totalSizeOf(http.StreamedResponse response) {
    final contentRange = response.headers['content-range'];
    if (contentRange != null) {
      final total = contentRange.split('/').lastOrNull;
      final parsed = total == null ? null : int.tryParse(total.trim());
      if (parsed != null) return parsed;
    }
    return response.contentLength ?? 0;
  }

  /// The SHA-256 recorded at upload, if the object carries one.
  ///
  /// S3's `etag` is an MD5 for single-part uploads and something else entirely
  /// for multipart ones, so it is never a SHA-256. The digest this package
  /// stores travels in `x-amz-meta-sha256`, and `x-amz-checksum-sha256` is
  /// S3's own base64 form, used when the object was uploaded by another tool
  /// with checksums enabled.
  static String? _checksumHeaderOf(Map<String, String> headers) {
    final metadataDigest = headers['x-amz-meta-sha256'];
    if (metadataDigest != null && metadataDigest.isNotEmpty) {
      return metadataDigest.toLowerCase();
    }
    final native = headers['x-amz-checksum-sha256'];
    if (native == null || native.isEmpty) return null;
    try {
      return base64Decode(
        native,
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    } on FormatException {
      return null;
    }
  }

  static String _normalizePrefix(String prefix) {
    final trimmed = _trimSlashes(prefix);
    return trimmed.isEmpty ? '' : '$trimmed/';
  }

  static String _trimSlashes(String value) {
    var result = value;
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static String? _unquote(String? value) => value?.replaceAll('"', '');

  /// Strips quotes and control characters from a filename bound for a
  /// `content-disposition` header, where an unescaped quote would let the rest
  /// of the header be rewritten.
  static String _sanitizeFilename(String filename) =>
      filename.replaceAll(RegExp(r'[\x00-\x1f"\\]'), '').replaceAll('\n', '');

  /// The `<Message>` of an S3 XML error, or the raw body if it has none.
  static String _messageIn(String body) =>
      _xmlValues(body, 'Message').firstOrNull ??
      (body.length > 200 ? '${body.substring(0, 200)}…' : body);

  /// The text content of every `<tag>` in [xml].
  ///
  /// A deliberately minimal extractor rather than an XML parser dependency:
  /// the only S3 responses this backend reads are `ListObjectsV2` results and
  /// error documents, both of which are flat enough that scanning for a tag is
  /// sufficient and cannot be confused by nesting.
  static List<String> _xmlValues(String xml, String tag) {
    final matches = RegExp('<$tag>(.*?)</$tag>', dotAll: true).allMatches(xml);
    return [for (final match in matches) _unescapeXml(match.group(1)!.trim())];
  }

  static String _unescapeXml(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  static DateTime? _parseHttpDate(String? value) => HttpDates.tryParse(value);
}
