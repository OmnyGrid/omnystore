import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../utils/hex.dart';
import '../../utils/rfc3986.dart';
import 'aws_credentials.dart';

/// AWS Signature Version 4 signing, in both the forms S3 needs: `Authorization`
/// headers for requests this process makes, and query-string presigning for
/// URLs handed to a client so it can fetch an artifact straight from the
/// bucket.
///
/// Presigning is what makes the S3 backend worth having. Without it every
/// download would stream through the registry, and the registry's bandwidth
/// would cap the distribution platform's throughput. With it the hub answers a
/// download with a `302` and never sees a byte of the artifact.
///
/// Implemented directly rather than pulled from an SDK: the signature is a
/// well-specified ~80 lines of hashing, and an AWS SDK dependency would drag a
/// large transitive tree into a package whose point is to stay embeddable.
class SigV4 {
  const SigV4._();

  /// The signing algorithm identifier.
  static const String algorithm = 'AWS4-HMAC-SHA256';

  /// The literal payload hash used when the body is not hashed in advance.
  ///
  /// Streaming a multi-gigabyte artifact would otherwise have to be buffered
  /// or read twice just to compute a signature over it. `UNSIGNED-PAYLOAD` is
  /// explicitly permitted over HTTPS, where TLS already protects the body's
  /// integrity in transit.
  static const String unsignedPayload = 'UNSIGNED-PAYLOAD';

  /// The SHA-256 of an empty body, required for GET/HEAD/DELETE signatures.
  static const String emptyPayloadHash =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// Signs the request described by [method], [url] and [headers], returning
  /// the headers to send — including `Authorization`.
  ///
  /// [payloadHash] is the hex SHA-256 of the body, or [unsignedPayload] for a
  /// streamed one. [headers] must already contain every header that is part of
  /// the request; anything added afterwards is not covered by the signature and
  /// S3 will reject it if it is one of the signed names.
  static Future<Map<String, String>> signRequest({
    required AwsCredentials credentials,
    required String method,
    required Uri url,
    required String region,
    required String service,
    required DateTime now,
    Map<String, String> headers = const {},
    String payloadHash = emptyPayloadHash,
  }) async {
    final amzDate = _amzDate(now);
    final dateStamp = _dateStamp(now);

    final signed = <String, String>{
      // `host` is mandatory in the signature; every other header is optional but
      // must match exactly what is sent.
      'host': _hostHeader(url),
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
      if (credentials.sessionToken != null)
        'x-amz-security-token': credentials.sessionToken!,
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };

    final canonicalHeaders = _canonicalHeaders(signed);
    final signedHeaders = _signedHeaderNames(signed);

    final canonicalRequest = [
      method.toUpperCase(),
      _canonicalPath(url),
      Rfc3986.canonicalQuery(url.queryParameters),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      algorithm,
      amzDate,
      scope,
      Hex.encode(sha256.convert(utf8.encode(canonicalRequest)).bytes),
    ].join('\n');

    final signature = Hex.encode(
      _hmac(
        _signingKey(credentials.secretAccessKey, dateStamp, region, service),
        utf8.encode(stringToSign),
      ),
    );

    return {
      ...signed,
      'authorization':
          '$algorithm '
          'Credential=${credentials.accessKeyId}/$scope, '
          'SignedHeaders=$signedHeaders, '
          'Signature=$signature',
    };
  }

  /// Returns [url] with SigV4 query-string authentication appended, valid for
  /// [expiresIn].
  ///
  /// The result can be handed to any HTTP client — a browser, `curl`, a
  /// download manager — with no credentials of its own. [expiresIn] is clamped
  /// to S3's maximum of seven days.
  ///
  /// [extraQuery] carries response-header overrides such as
  /// `response-content-disposition`, which is how a download is made to save
  /// under its release filename rather than its storage key. Those parameters
  /// are part of the signature, so a client cannot tamper with them.
  static Future<Uri> presign({
    required AwsCredentials credentials,
    required String method,
    required Uri url,
    required String region,
    required String service,
    required DateTime now,
    required Duration expiresIn,
    Map<String, String> extraQuery = const {},
  }) async {
    final amzDate = _amzDate(now);
    final dateStamp = _dateStamp(now);
    final scope = '$dateStamp/$region/$service/aws4_request';

    // S3 rejects anything longer than seven days, and a negative or zero
    // lifetime would produce a URL that is invalid the moment it is issued.
    final seconds = expiresIn.inSeconds.clamp(1, 604800);

    // Only `host` is signed: a presigned URL is fetched by a client we do not
    // control, and any other signed header would have to be reproduced exactly
    // by that client or the request fails.
    const signedHeaders = 'host';
    final canonicalHeaders = 'host:${_hostHeader(url)}\n';

    final query = <String, String>{
      ...url.queryParameters,
      ...extraQuery,
      'X-Amz-Algorithm': algorithm,
      'X-Amz-Credential': '${credentials.accessKeyId}/$scope',
      'X-Amz-Date': amzDate,
      'X-Amz-Expires': '$seconds',
      'X-Amz-SignedHeaders': signedHeaders,
      if (credentials.sessionToken != null)
        'X-Amz-Security-Token': credentials.sessionToken!,
    };

    final canonicalRequest = [
      method.toUpperCase(),
      _canonicalPath(url),
      Rfc3986.canonicalQuery(query),
      canonicalHeaders,
      signedHeaders,
      unsignedPayload,
    ].join('\n');

    final stringToSign = [
      algorithm,
      amzDate,
      scope,
      Hex.encode(sha256.convert(utf8.encode(canonicalRequest)).bytes),
    ].join('\n');

    final signature = Hex.encode(
      _hmac(
        _signingKey(credentials.secretAccessKey, dateStamp, region, service),
        utf8.encode(stringToSign),
      ),
    );

    return url.replace(
      queryParameters: {...query, 'X-Amz-Signature': signature},
    );
  }

  /// The `yyyyMMddTHHmmssZ` timestamp AWS signatures use.
  static String _amzDate(DateTime now) {
    final utc = now.toUtc();
    return '${_dateStamp(now)}T'
        '${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}Z';
  }

  /// The `yyyyMMdd` date stamp used in the credential scope.
  static String _dateStamp(DateTime now) {
    final utc = now.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}'
        '${_two(utc.month)}${_two(utc.day)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// The `Host` header value: the host, plus the port when it is not the
  /// scheme's default. Including a default port would break the signature,
  /// because the client will not send one.
  static String _hostHeader(Uri url) {
    final isDefaultPort =
        (url.scheme == 'https' && url.port == 443) ||
        (url.scheme == 'http' && url.port == 80) ||
        url.port == 0;
    return isDefaultPort ? url.host : '${url.host}:${url.port}';
  }

  /// The canonical URI: each path segment URI-encoded, `/` left alone.
  ///
  /// [Uri] already percent-encodes on construction, so this re-encodes from the
  /// decoded segments — encoding the already-encoded `path` would turn `%20`
  /// into `%2520` and every signature would fail.
  static String _canonicalPath(Uri url) {
    if (url.pathSegments.isEmpty) return '/';
    return '/${url.pathSegments.map(Rfc3986.encodeComponent).join('/')}';
  }

  /// Headers sorted by lower-cased name, values trimmed, one per line.
  static String _canonicalHeaders(Map<String, String> headers) {
    final names = headers.keys.toList()..sort();
    return names.map((name) => '$name:${_trimValue(headers[name]!)}\n').join();
  }

  static String _signedHeaderNames(Map<String, String> headers) =>
      (headers.keys.toList()..sort()).join(';');

  /// Collapses internal whitespace runs and trims, as the specification
  /// requires for canonical header values.
  static String _trimValue(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// The four-step HMAC chain deriving the request signing key.
  static List<int> _signingKey(
    String secretAccessKey,
    String dateStamp,
    String region,
    String service,
  ) {
    final kDate = _hmac(
      utf8.encode('AWS4$secretAccessKey'),
      utf8.encode(dateStamp),
    );
    final kRegion = _hmac(kDate, utf8.encode(region));
    final kService = _hmac(kRegion, utf8.encode(service));
    return _hmac(kService, utf8.encode('aws4_request'));
  }

  static List<int> _hmac(List<int> key, List<int> data) =>
      Hmac(sha256, key).convert(data).bytes;
}
