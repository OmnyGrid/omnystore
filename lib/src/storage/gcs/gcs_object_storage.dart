import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../exceptions/omnystore_exception.dart';
import '../../utils/checksum.dart';
import '../../utils/http_dates.dart';
import '../../utils/json.dart';
import '../object_storage.dart';
import 'gcp_credentials.dart';

/// An [ObjectStorage] backed by a Google Cloud Storage bucket.
///
/// ```dart
/// final storage = GcsObjectStorage(
///   bucket: 'acme-releases',
///   credentials: GcpServiceAccountCredentials.fromJsonString(
///     File('service-account.json').readAsStringSync(),
///   ),
/// );
/// ```
///
/// Uploads and metadata go through the JSON API; downloads use the media
/// endpoint, which supports `Range` and so makes resumable client downloads
/// work.
///
/// **Signed downloads depend on the credentials.** With a service account key
/// ([GcpServiceAccountCredentials]) this backend signs V4 URLs locally and
/// [supportsPresignedUrls] is `true`, so the hub redirects clients straight at
/// the bucket and never carries artifact bytes. With ambient credentials
/// ([GcpMetadataServerCredentials]) there is no private key to sign with, so
/// [presignedUrl] returns `null` and the hub streams the bytes through itself
/// — correct, just not free. Nothing else in the system changes.
///
/// **Uploads are single-request.** Artifacts stream through the `uploadType=media`
/// endpoint. GCS accepts objects up to 5 TB this way, so unlike the S3 backend
/// there is no practical single-part ceiling; a failed upload does have to be
/// restarted from the beginning, since resumable uploads are not implemented.
class GcsObjectStorage implements ObjectStorage {
  /// The bucket objects live in.
  final String bucket;

  /// Supplies access tokens and, when available, URL-signing key material.
  final GcpCredentialsProvider credentials;

  /// A key prefix applied to every object, so one bucket can host several
  /// registries. Normalised to end with `/`, or empty.
  final String prefix;

  /// The API base, overridable for a test double or a private endpoint.
  final Uri apiBase;

  /// The storage class applied to uploads (`STANDARD`, `NEARLINE`,
  /// `COLDLINE`, `ARCHIVE`), or `null` for the bucket default.
  final String? storageClass;

  final http.Client _http;
  final bool _ownsClient;

  /// Creates a GCS-backed store.
  GcsObjectStorage({
    required this.bucket,
    required this.credentials,
    String prefix = '',
    Uri? apiBase,
    this.storageClass,
    http.Client? httpClient,
  }) : prefix = _normalizePrefix(prefix),
       apiBase = apiBase ?? Uri.https('storage.googleapis.com', '/'),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  @override
  String get id => 'gcs:$bucket';

  @override
  bool get supportsPresignedUrls => credentials.canSignUrls;

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
    final fullKey = '$prefix$key';

    final url = apiBase.replace(
      path: '/upload/storage/v1/b/$bucket/o',
      queryParameters: {
        'uploadType': 'media',
        'name': fullKey,
        'storageClass': ?storageClass,
      },
    );

    late ChecksumResult checksum;
    final counted = ChecksumStream.transform(data, (r) => checksum = r);

    final request = http.StreamedRequest('POST', url)
      ..headers.addAll({
        'authorization': 'Bearer ${(await credentials.accessToken()).token}',
        'content-type': contentType,
        // GCS records custom metadata on a media upload through these headers.
        for (final entry in metadata.entries)
          'x-goog-meta-${entry.key.toLowerCase()}': entry.value,
      });
    if (length != null) request.contentLength = length;

    // Not awaited: the sink is drained by `send`, so awaiting here deadlocks.
    counted.listen(
      request.sink.add,
      onError: request.sink.addError,
      onDone: request.sink.close,
      cancelOnError: true,
    );

    final response = await _send(request, key);
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw StorageException(
        'GCS upload of $key failed with ${response.statusCode}: '
        '${_messageIn(body)}',
        key: key,
      );
    }

    if (length != null && checksum.sizeBytes != length) {
      await delete(key);
      throw ValidationException(
        'Declared length $length does not match the ${checksum.sizeBytes} '
        'bytes uploaded for $key',
        field: 'length',
      );
    }
    if (expectedSha256 != null &&
        !Checksums.matches(expectedSha256, checksum.sha256)) {
      // Remove the object before reporting: a corrupted artifact left in the
      // bucket would be downloadable by anyone who knew its key.
      await delete(key);
      throw ChecksumMismatchException(
        expected: expectedSha256.toLowerCase(),
        actual: checksum.sha256,
      );
    }

    // Record the digest as custom metadata so a later `head` can report it.
    // GCS's own `crc32c`/`md5Hash` fields are neither SHA-256.
    await _patchMetadata(fullKey, {'sha256': checksum.sha256});

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
    final request = http.Request('GET', _mediaUrlFor(key))
      ..headers['authorization'] =
          'Bearer ${(await credentials.accessToken()).token}';
    if (range != null) request.headers['range'] = range.toHeaderValue();

    final response = await _send(request, key);
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
      final body = await response.stream.bytesToString();
      throw StorageException(
        'GCS read of $key failed with ${response.statusCode}: '
        '${_messageIn(body)}',
        key: key,
      );
    }

    final total = _totalSizeOf(response);
    return ObjectReader(
      object: StoredObject(
        key: key,
        sizeBytes: total,
        sha256: response.headers['x-goog-meta-sha256']?.toLowerCase(),
        contentType: response.headers['content-type'],
        modifiedAt: HttpDates.tryParse(response.headers['last-modified']),
        etag: response.headers['etag']?.replaceAll('"', ''),
      ),
      stream: response.stream,
      length: response.contentLength ?? total,
      range: response.statusCode == 206 ? range : null,
    );
  }

  @override
  Future<StoredObject?> head(String key) async {
    StorageKeys.requireSafe(key);
    final response = await _sendJson('GET', _objectUrlFor(key), key);
    if (response == null) return null;
    return _describe(key, response);
  }

  @override
  Future<bool> exists(String key) async => await head(key) != null;

  @override
  Future<void> delete(String key) async {
    StorageKeys.requireSafe(key);
    final request = http.Request('DELETE', _objectUrlFor(key))
      ..headers['authorization'] =
          'Bearer ${(await credentials.accessToken()).token}';
    final response = await _send(request, key);
    final body = await response.stream.bytesToString();
    // 404 is a success: deleting what is not there is the idempotent contract.
    if (response.statusCode != 204 &&
        response.statusCode != 200 &&
        response.statusCode != 404) {
      throw StorageException(
        'GCS delete of $key failed with ${response.statusCode}: '
        '${_messageIn(body)}',
        key: key,
      );
    }
  }

  @override
  Future<List<String>> list({String? prefix, int? limit}) async {
    final keys = <String>[];
    String? pageToken;

    do {
      final url = apiBase.replace(
        path: '/storage/v1/b/$bucket/o',
        queryParameters: {
          'prefix': '${this.prefix}${prefix ?? ''}',
          'fields': 'items(name),nextPageToken',
          if (limit != null) 'maxResults': '${limit - keys.length}',
          'pageToken': ?pageToken,
        },
      );
      final request = http.Request('GET', url)
        ..headers['authorization'] =
            'Bearer ${(await credentials.accessToken()).token}';
      final response = await _send(request, '');
      final body = await response.stream.bytesToString();
      if (response.statusCode != 200) {
        throw StorageException(
          'GCS list failed with ${response.statusCode}: ${_messageIn(body)}',
        );
      }
      final decoded = Json.asObject(jsonDecode(body), 'list response');
      for (final raw in (decoded['items'] as List<dynamic>? ?? const [])) {
        final name = Json.requireString(Json.asObject(raw, 'item'), 'name');
        keys.add(
          name.startsWith(this.prefix)
              ? name.substring(this.prefix.length)
              : name,
        );
      }
      pageToken = Json.optString(decoded, 'nextPageToken');
      if (limit != null && keys.length >= limit) break;
    } while (pageToken != null);

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
    // No key material means no local signature. Returning `null` — rather than
    // throwing — is the contract: the caller falls back to streaming.
    if (!credentials.canSignUrls) return null;
    final email = credentials.clientEmail;
    if (email == null) return null;

    return _signV4(
      key: key,
      clientEmail: email,
      expiresIn: expiresIn,
      filename: filename,
      contentType: contentType,
    );
  }

  @override
  Future<int?> usedBytes() async {
    // Walking every object to total their sizes would be an unbounded cost on
    // each provider heartbeat. GCS exposes bucket size only through Monitoring,
    // which is out of scope here; `null` means "unknown", and placement reads
    // that as "has room".
    return null;
  }

  @override
  Future<void> close() async {
    await credentials.close();
    if (_ownsClient) _http.close();
  }

  /// Builds a V4 signed URL for [key].
  ///
  /// Follows Google's documented canonical-request construction, which is
  /// SigV4-shaped but differs from AWS's in the credential scope (`auto/storage`
  /// rather than a region and service) and in requiring `host` to be the signed
  /// header.
  Future<Uri> _signV4({
    required String key,
    required String clientEmail,
    required Duration expiresIn,
    String? filename,
    String? contentType,
  }) async {
    final now = DateTime.now().toUtc();
    final timestamp = _basicIso8601(now);
    final datestamp = timestamp.substring(0, 8);
    final scope = '$datestamp/auto/storage/goog4_request';
    // Google caps V4 URLs at seven days.
    final seconds = expiresIn.inSeconds.clamp(1, 604800);

    final host = apiBase.host;
    final canonicalPath = '/$bucket/${_encodePath('$prefix$key')}';

    final query = <String, String>{
      'X-Goog-Algorithm': 'GOOG4-RSA-SHA256',
      'X-Goog-Credential': '$clientEmail/$scope',
      'X-Goog-Date': timestamp,
      'X-Goog-Expires': '$seconds',
      'X-Goog-SignedHeaders': 'host',
      if (filename != null)
        'response-content-disposition':
            'attachment; filename="${_sanitizeFilename(filename)}"',
      'response-content-type': ?contentType,
    };

    final canonicalRequest = [
      'GET',
      canonicalPath,
      _canonicalQuery(query),
      'host:$host\n',
      'host',
      'UNSIGNED-PAYLOAD',
    ].join('\n');

    final stringToSign = [
      'GOOG4-RSA-SHA256',
      timestamp,
      scope,
      _hex(sha256.convert(utf8.encode(canonicalRequest)).bytes),
    ].join('\n');

    final signature = _hex(
      await credentials.signRsaSha256(
        Uint8List.fromList(utf8.encode(stringToSign)),
      ),
    );

    return apiBase.replace(
      path: '/$bucket/$prefix$key',
      queryParameters: {...query, 'X-Goog-Signature': signature},
    );
  }

  /// Attaches custom metadata to an already-uploaded object.
  ///
  /// Best-effort: a failure here leaves the artifact perfectly downloadable and
  /// only costs a `null` checksum from [head], so it must not fail the upload
  /// that has otherwise succeeded.
  Future<void> _patchMetadata(
    String fullKey,
    Map<String, String> metadata,
  ) async {
    try {
      final url = apiBase.replace(
        path: '/storage/v1/b/$bucket/o/${Uri.encodeComponent(fullKey)}',
      );
      final request = http.Request('PATCH', url)
        ..headers.addAll({
          'authorization': 'Bearer ${(await credentials.accessToken()).token}',
          'content-type': 'application/json',
        })
        ..body = jsonEncode({'metadata': metadata});
      final response = await _http.send(request);
      await response.stream.drain<void>();
    } on Object {
      // Intentionally swallowed; see the doc comment.
    }
  }

  StoredObject _describe(String key, Map<String, dynamic> json) {
    final custom = json['metadata'];
    final sha256Value = custom is Map
        ? custom['sha256']?.toString().toLowerCase()
        : null;
    return StoredObject(
      key: key,
      sizeBytes: int.tryParse(Json.optString(json, 'size') ?? '') ?? 0,
      sha256: sha256Value,
      contentType: Json.optString(json, 'contentType'),
      modifiedAt: DateTime.tryParse(
        Json.optString(json, 'updated') ?? '',
      )?.toUtc(),
      etag: Json.optString(json, 'etag'),
    );
  }

  /// Sends a JSON API request, returning the decoded body, or `null` on 404.
  Future<Map<String, dynamic>?> _sendJson(
    String method,
    Uri url,
    String key,
  ) async {
    final request = http.Request(method, url)
      ..headers['authorization'] =
          'Bearer ${(await credentials.accessToken()).token}';
    final response = await _send(request, key);
    final body = await response.stream.bytesToString();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StorageException(
        'GCS $method of $key failed with ${response.statusCode}: '
        '${_messageIn(body)}',
        key: key,
      );
    }
    return Json.asObject(jsonDecode(body), 'object metadata');
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request,
    String key,
  ) async {
    try {
      return await _http.send(request);
    } on http.ClientException catch (e) {
      throw StorageException(
        'GCS request for ${key.isEmpty ? bucket : key} failed: ${e.message}',
        key: key.isEmpty ? null : key,
      );
    }
  }

  Uri _objectUrlFor(String key) => apiBase.replace(
    path: '/storage/v1/b/$bucket/o/${Uri.encodeComponent('$prefix$key')}',
  );

  Uri _mediaUrlFor(String key) => apiBase.replace(
    path: '/storage/v1/b/$bucket/o/${Uri.encodeComponent('$prefix$key')}',
    queryParameters: {'alt': 'media'},
  );

  static int _totalSizeOf(http.StreamedResponse response) {
    final contentRange = response.headers['content-range'];
    if (contentRange != null) {
      final total = contentRange.split('/').lastOrNull;
      final parsed = total == null ? null : int.tryParse(total.trim());
      if (parsed != null) return parsed;
    }
    return response.contentLength ?? 0;
  }

  /// `yyyyMMddTHHmmssZ`, the timestamp form V4 signing uses.
  static String _basicIso8601(DateTime now) {
    final utc = now.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
        '${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}'
        '${two(utc.second)}Z';
  }

  static String _canonicalQuery(Map<String, String> parameters) {
    final encoded =
        parameters.entries
            .map(
              (e) =>
                  MapEntry(_encodeComponent(e.key), _encodeComponent(e.value)),
            )
            .toList()
          ..sort((a, b) {
            final byKey = a.key.compareTo(b.key);
            return byKey != 0 ? byKey : a.value.compareTo(b.value);
          });
    return encoded.map((e) => '${e.key}=${e.value}').join('&');
  }

  /// Percent-encodes a path, leaving `/` as a separator.
  static String _encodePath(String path) =>
      path.split('/').map(_encodeComponent).join('/');

  /// RFC 3986 percent-encoding, escaping everything outside the unreserved set.
  static String _encodeComponent(String value) {
    const unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final char = String.fromCharCode(byte);
      if (unreserved.contains(char)) {
        buffer.write(char);
      } else {
        buffer.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
    return buffer.toString();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _normalizePrefix(String prefix) {
    var trimmed = prefix;
    while (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1);
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed.isEmpty ? '' : '$trimmed/';
  }

  static String _sanitizeFilename(String filename) =>
      filename.replaceAll(RegExp(r'[\x00-\x1f"\\]'), '').replaceAll('\n', '');

  /// The `error.message` of a GCS JSON error, or the raw body.
  static String _messageIn(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message is String) return message;
      }
    } on FormatException {
      // Not JSON; fall through to the raw body.
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}
