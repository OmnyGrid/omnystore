import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One stored object in a fake cloud bucket.
class FakeObject {
  /// The bytes.
  final Uint8List bytes;

  /// The MIME type the upload declared.
  final String contentType;

  /// Custom metadata (`x-amz-meta-*` / GCS `metadata`), keys lower-cased.
  final Map<String, String> metadata;

  /// When it was written.
  final DateTime modifiedAt;

  /// Creates a stored object.
  FakeObject({
    required this.bytes,
    required this.contentType,
    required this.metadata,
    required this.modifiedAt,
  });
}

/// Shared behaviour for the two fake buckets: range handling, and the
/// bookkeeping the tests assert on.
abstract class FakeBucket {
  /// The objects held, keyed by their full storage key.
  final Map<String, FakeObject> objects = {};

  /// Every request the backend made, for asserting on what was actually sent.
  final List<http.BaseRequest> requests = [];

  /// Set to fail the next request with this status, once.
  int? failNextWith;

  /// The HTTP client to hand the backend under test.
  http.Client get client;

  /// Slices [bytes] for a `Range` header, returning the served slice and the
  /// `content-range` value, or `null` when the header is absent or unusable.
  static ({Uint8List slice, String contentRange})? applyRange(
    String? rangeHeader,
    Uint8List bytes,
  ) {
    if (rangeHeader == null) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(rangeHeader.trim());
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    if (start >= bytes.length) return null;
    final endText = match.group(2)!;
    final end = endText.isEmpty
        ? bytes.length - 1
        : int.parse(endText).clamp(start, bytes.length - 1);
    return (
      slice: Uint8List.sublistView(bytes, start, end + 1),
      contentRange: 'bytes $start-$end/${bytes.length}',
    );
  }
}

/// A fake S3 endpoint, faithful enough to run the `ObjectStorage` contract
/// suite against the real [S3ObjectStorage].
///
/// It is not a general S3 emulator — it implements exactly the surface the
/// backend uses: single-part `PUT`, `GET` with `Range`, `HEAD`, `DELETE` and
/// paginated `ListObjectsV2`. That is enough to catch the failures a
/// MockClient returning canned bytes never would: a wrong URL shape, a header
/// that is written but never read back, a list response the parser mis-reads,
/// an error status mapped to the wrong exception.
class FakeS3 extends FakeBucket {
  /// The bucket name the backend addresses.
  final String bucket;

  /// Whether the backend addresses this bucket path-style.
  final bool usePathStyle;

  /// Keys returned per `ListObjectsV2` page, so pagination is exercised.
  final int pageSize;

  @override
  late final http.Client client = MockClient.streaming(_handle);

  /// Creates a fake S3 endpoint.
  FakeS3({
    this.bucket = 'test-bucket',
    this.usePathStyle = false,
    this.pageSize = 1000,
  });

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    requests.add(request);

    final failure = failNextWith;
    if (failure != null) {
      failNextWith = null;
      return _xmlError(failure, 'InternalError', 'injected failure');
    }

    final key = _keyOf(request.url);
    switch (request.method) {
      case 'PUT':
        return _put(request, body, key);
      case 'GET':
        // ListObjectsV2 is a GET on the bucket root with `list-type=2`.
        if (request.url.queryParameters['list-type'] == '2') {
          return _list(request.url.queryParameters);
        }
        return _get(request, key, includeBody: true);
      case 'HEAD':
        return _get(request, key, includeBody: false);
      case 'DELETE':
        objects.remove(key);
        // S3 answers 204 whether or not the key existed.
        return http.StreamedResponse(const Stream.empty(), 204);
      default:
        return _xmlError(405, 'MethodNotAllowed', request.method);
    }
  }

  /// The object key a request URL addresses, with the bucket segment stripped
  /// for path-style requests.
  String _keyOf(Uri url) {
    var path = url.path.startsWith('/') ? url.path.substring(1) : url.path;
    if (usePathStyle && (path == bucket || path.startsWith('$bucket/'))) {
      path = path.length == bucket.length
          ? ''
          : path.substring(bucket.length + 1);
    }
    return Uri.decodeComponent(path);
  }

  Future<http.StreamedResponse> _put(
    http.BaseRequest request,
    http.ByteStream body,
    String key,
  ) async {
    final bytes = await _collect(body);
    objects[key] = FakeObject(
      bytes: bytes,
      contentType: request.headers['content-type'] ?? 'binary/octet-stream',
      metadata: {
        for (final e in request.headers.entries)
          if (e.key.toLowerCase().startsWith('x-amz-meta-'))
            e.key.toLowerCase().substring('x-amz-meta-'.length): e.value,
      },
      modifiedAt: DateTime.utc(2026, 3, 1, 12),
    );
    return http.StreamedResponse(
      const Stream.empty(),
      200,
      headers: {'etag': '"${bytes.length}"'},
    );
  }

  Future<http.StreamedResponse> _get(
    http.BaseRequest request,
    String key, {
    required bool includeBody,
  }) async {
    final object = objects[key];
    if (object == null) {
      return _xmlError(404, 'NoSuchKey', 'The specified key does not exist.');
    }

    final headers = <String, String>{
      'content-type': object.contentType,
      'etag': '"${object.bytes.length}"',
      'last-modified': 'Sun, 01 Mar 2026 12:00:00 GMT',
      for (final e in object.metadata.entries) 'x-amz-meta-${e.key}': e.value,
    };

    final ranged = FakeBucket.applyRange(
      request.headers['range'],
      object.bytes,
    );
    if (request.headers['range'] != null && ranged == null) {
      return _xmlError(416, 'InvalidRange', 'The requested range is invalid.');
    }

    final payload = ranged?.slice ?? object.bytes;
    if (ranged != null) headers['content-range'] = ranged.contentRange;

    return http.StreamedResponse(
      includeBody ? Stream.value(payload) : const Stream.empty(),
      ranged != null ? 206 : 200,
      contentLength: payload.length,
      headers: headers,
    );
  }

  Future<http.StreamedResponse> _list(Map<String, String> query) async {
    final prefix = query['prefix'] ?? '';
    final after = query['continuation-token'];

    var keys = objects.keys.where((k) => k.startsWith(prefix)).toList()..sort();
    if (after != null) {
      keys = keys.where((k) => k.compareTo(after) > 0).toList();
    }

    final maxKeys = int.tryParse(query['max-keys'] ?? '') ?? pageSize;
    final limit = maxKeys < pageSize ? maxKeys : pageSize;
    final page = keys.take(limit).toList();
    final truncated = page.length < keys.length;

    final xml = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>')
      ..write('<ListBucketResult>')
      ..write('<Name>$bucket</Name>')
      ..write('<IsTruncated>$truncated</IsTruncated>');
    for (final key in page) {
      xml.write('<Contents><Key>${_escape(key)}</Key></Contents>');
    }
    if (truncated) {
      xml.write(
        '<NextContinuationToken>${_escape(page.last)}'
        '</NextContinuationToken>',
      );
    }
    xml.write('</ListBucketResult>');

    return http.StreamedResponse(
      Stream.value(utf8.encode(xml.toString())),
      200,
      headers: {'content-type': 'application/xml'},
    );
  }

  static http.StreamedResponse _xmlError(
    int status,
    String code,
    String message,
  ) => http.StreamedResponse(
    Stream.value(
      utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?><Error><Code>$code</Code>'
        '<Message>${_escape(message)}</Message></Error>',
      ),
    ),
    status,
    headers: {'content-type': 'application/xml'},
  );

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

/// A fake Google Cloud Storage endpoint, covering the JSON API surface
/// [GcsObjectStorage] uses: media upload, media download with `Range`, object
/// metadata, metadata patch, delete and paginated listing.
class FakeGcs extends FakeBucket {
  /// The bucket the backend addresses.
  final String bucket;

  /// Objects returned per listing page.
  final int pageSize;

  /// Access tokens the backend presented, so a test can assert it authorised.
  final List<String> bearerTokens = [];

  @override
  late final http.Client client = MockClient.streaming(_handle);

  /// Creates a fake GCS endpoint.
  FakeGcs({this.bucket = 'test-bucket', this.pageSize = 1000});

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    requests.add(request);
    final authorization = request.headers['authorization'];
    if (authorization != null && authorization.startsWith('Bearer ')) {
      bearerTokens.add(authorization.substring('Bearer '.length));
    }

    final failure = failNextWith;
    if (failure != null) {
      failNextWith = null;
      return _jsonError(failure, 'injected failure');
    }

    final path = request.url.path;

    // The OAuth token exchange, when the backend is driven by a service
    // account rather than a pre-supplied token.
    if (path == '/token') {
      return _json(200, {'access_token': 'ya29.fake', 'expires_in': 3600});
    }

    // The GCE/Cloud Run metadata server, when the backend uses the ambient
    // workload identity instead of a key.
    if (path.startsWith('/computeMetadata/v1/')) {
      return _json(200, {'access_token': 'ya29.metadata', 'expires_in': 3600});
    }

    // Upload: POST /upload/storage/v1/b/{bucket}/o?uploadType=media&name=…
    if (path.startsWith('/upload/storage/v1/b/') && request.method == 'POST') {
      return _upload(request, body);
    }

    // Listing: GET /storage/v1/b/{bucket}/o
    if (path == '/storage/v1/b/$bucket/o' && request.method == 'GET') {
      return _list(request.url.queryParameters);
    }

    // Single object: /storage/v1/b/{bucket}/o/{urlencoded key}
    final objectPrefix = '/storage/v1/b/$bucket/o/';
    if (path.startsWith(objectPrefix)) {
      final key = Uri.decodeComponent(path.substring(objectPrefix.length));
      switch (request.method) {
        case 'GET':
          return request.url.queryParameters['alt'] == 'media'
              ? _download(request, key)
              : _metadata(key);
        case 'PATCH':
          return _patch(await _collect(body), key);
        case 'DELETE':
          final existed = objects.remove(key) != null;
          return existed
              ? http.StreamedResponse(const Stream.empty(), 204)
              : _jsonError(404, 'Not Found');
      }
    }

    return _jsonError(404, 'no fake route for ${request.method} $path');
  }

  Future<http.StreamedResponse> _upload(
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    final key = request.url.queryParameters['name']!;
    final bytes = await _collect(body);
    objects[key] = FakeObject(
      bytes: bytes,
      contentType:
          request.headers['content-type'] ?? 'application/octet-stream',
      metadata: {
        for (final e in request.headers.entries)
          if (e.key.toLowerCase().startsWith('x-goog-meta-'))
            e.key.toLowerCase().substring('x-goog-meta-'.length): e.value,
      },
      modifiedAt: DateTime.utc(2026, 3, 1, 12),
    );
    return _json(200, _describe(key, objects[key]!));
  }

  Future<http.StreamedResponse> _download(
    http.BaseRequest request,
    String key,
  ) async {
    final object = objects[key];
    if (object == null) return _jsonError(404, 'No such object: $key');

    final headers = <String, String>{
      'content-type': object.contentType,
      'last-modified': 'Sun, 01 Mar 2026 12:00:00 GMT',
      for (final e in object.metadata.entries) 'x-goog-meta-${e.key}': e.value,
    };

    final ranged = FakeBucket.applyRange(
      request.headers['range'],
      object.bytes,
    );
    if (request.headers['range'] != null && ranged == null) {
      return _jsonError(416, 'Requested range not satisfiable');
    }
    final payload = ranged?.slice ?? object.bytes;
    if (ranged != null) headers['content-range'] = ranged.contentRange;

    return http.StreamedResponse(
      Stream.value(payload),
      ranged != null ? 206 : 200,
      contentLength: payload.length,
      headers: headers,
    );
  }

  Future<http.StreamedResponse> _metadata(String key) async {
    final object = objects[key];
    if (object == null) return _jsonError(404, 'No such object: $key');
    return _json(200, _describe(key, object));
  }

  Future<http.StreamedResponse> _patch(Uint8List body, String key) async {
    final object = objects[key];
    if (object == null) return _jsonError(404, 'No such object: $key');

    final decoded = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    final patch = (decoded['metadata'] as Map?)?.cast<String, dynamic>() ?? {};
    objects[key] = FakeObject(
      bytes: object.bytes,
      contentType: object.contentType,
      metadata: {
        ...object.metadata,
        for (final e in patch.entries) e.key.toLowerCase(): '${e.value}',
      },
      modifiedAt: object.modifiedAt,
    );
    return _json(200, _describe(key, objects[key]!));
  }

  Future<http.StreamedResponse> _list(Map<String, String> query) async {
    final prefix = query['prefix'] ?? '';
    final after = query['pageToken'];

    var keys = objects.keys.where((k) => k.startsWith(prefix)).toList()..sort();
    if (after != null) {
      keys = keys.where((k) => k.compareTo(after) > 0).toList();
    }

    final maxResults = int.tryParse(query['maxResults'] ?? '') ?? pageSize;
    final limit = maxResults < pageSize ? maxResults : pageSize;
    final page = keys.take(limit).toList();
    final truncated = page.length < keys.length;

    return _json(200, {
      'items': [
        for (final key in page) {'name': key},
      ],
      if (truncated) 'nextPageToken': page.last,
    });
  }

  Map<String, dynamic> _describe(String key, FakeObject object) => {
    'name': key,
    // GCS reports size as a string.
    'size': '${object.bytes.length}',
    'contentType': object.contentType,
    'updated': object.modifiedAt.toIso8601String(),
    'etag': 'etag-${object.bytes.length}',
    if (object.metadata.isNotEmpty) 'metadata': object.metadata,
  };

  static http.StreamedResponse _json(int status, Object body) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
        headers: {'content-type': 'application/json'},
      );

  static http.StreamedResponse _jsonError(int status, String message) =>
      _json(status, {
        'error': {'code': status, 'message': message},
      });
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
