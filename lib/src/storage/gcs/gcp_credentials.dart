import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart';

import '../../exceptions/omnystore_exception.dart';
import '../../utils/json.dart';

/// An OAuth 2.0 access token for the Google Cloud Storage API.
@immutable
class GcpAccessToken {
  /// The bearer token value.
  final String token;

  /// When it expires (UTC).
  final DateTime expiresAt;

  /// Creates a token.
  const GcpAccessToken({required this.token, required this.expiresAt});

  /// Whether the token has expired as of [now], with a safety margin so a
  /// request authorised just before expiry does not arrive just after.
  bool isExpired(
    DateTime now, {
    Duration margin = const Duration(minutes: 5),
  }) => !now.add(margin).isBefore(expiresAt);

  @override
  String toString() => 'GcpAccessToken(expires ${expiresAt.toIso8601String()})';
}

/// Supplies access tokens for Google Cloud APIs, and — when it can — the RSA
/// key material needed to sign download URLs.
///
/// Two capabilities, deliberately on one port, because whether a deployment has
/// the second decides how downloads are served. A provider holding a service
/// account key can sign a V4 URL locally, so the hub redirects clients straight
/// at the bucket. A provider that only has a token (a Cloud Run instance using
/// its ambient identity) cannot, and the hub streams the bytes through itself
/// instead. `GcsObjectStorage` picks between those automatically from
/// [canSignUrls].
abstract interface class GcpCredentialsProvider {
  /// A valid access token, refreshed if necessary.
  Future<GcpAccessToken> accessToken();

  /// The service account e-mail these credentials belong to, or `null` if it
  /// is not known.
  String? get clientEmail;

  /// Whether this provider can sign V4 URLs locally — that is, whether it
  /// holds an RSA private key rather than just a bearer token.
  bool get canSignUrls;

  /// Signs [data] with RSASSA-PKCS1-v1_5 over SHA-256.
  ///
  /// Throws [UnsupportedOperationException] when [canSignUrls] is `false`.
  Future<Uint8List> signRsaSha256(Uint8List data);

  /// Releases any resources held (an HTTP client used for token exchange).
  Future<void> close();
}

/// A [GcpCredentialsProvider] backed by a service account key — the standard
/// JSON file `gcloud iam service-accounts keys create` produces.
///
/// This is the provider to use when the registry runs anywhere other than on
/// Google Cloud, and the only one that can sign download URLs.
///
/// ```dart
/// final credentials = GcpServiceAccountCredentials.fromJson(
///   jsonDecode(File('service-account.json').readAsStringSync()),
/// );
/// ```
///
/// Access tokens are obtained by the standard JWT bearer grant: a short-lived
/// assertion is signed with the account's private key and exchanged at Google's
/// token endpoint. Tokens are cached until shortly before they expire, and
/// concurrent refreshes collapse onto one exchange.
class GcpServiceAccountCredentials implements GcpCredentialsProvider {
  /// The service account's e-mail address.
  @override
  final String clientEmail;

  /// The account's RSA private key.
  final RSAPrivateKey privateKey;

  /// The OAuth scopes requested for access tokens.
  final List<String> scopes;

  /// The token exchange endpoint.
  final Uri tokenUri;

  final http.Client _http;
  final bool _ownsClient;

  GcpAccessToken? _cached;
  Future<GcpAccessToken>? _inFlight;

  /// The scope granting read/write access to Cloud Storage.
  static const String storageScope =
      'https://www.googleapis.com/auth/devstorage.read_write';

  /// Creates credentials from an already-parsed key.
  GcpServiceAccountCredentials({
    required this.clientEmail,
    required this.privateKey,
    this.scopes = const [storageScope],
    Uri? tokenUri,
    http.Client? httpClient,
  }) : tokenUri = tokenUri ?? Uri.https('oauth2.googleapis.com', '/token'),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Parses a service account key JSON document.
  ///
  /// Expects the `client_email` and `private_key` fields Google emits; throws
  /// [ValidationException] if either is missing or the key cannot be parsed.
  factory GcpServiceAccountCredentials.fromJson(
    Map<String, dynamic> json, {
    List<String> scopes = const [storageScope],
    http.Client? httpClient,
  }) {
    final type = Json.optString(json, 'type');
    if (type != null && type != 'service_account') {
      throw ValidationException(
        "Expected a service account key (type 'service_account'), got '$type'",
        field: 'credentials',
      );
    }
    return GcpServiceAccountCredentials(
      clientEmail: Json.requireString(json, 'client_email'),
      privateKey: parsePrivateKeyPem(Json.requireString(json, 'private_key')),
      scopes: scopes,
      tokenUri: Uri.tryParse(Json.optString(json, 'token_uri') ?? ''),
      httpClient: httpClient,
    );
  }

  /// Parses a service account key from its raw JSON [source].
  factory GcpServiceAccountCredentials.fromJsonString(
    String source, {
    List<String> scopes = const [storageScope],
    http.Client? httpClient,
  }) => GcpServiceAccountCredentials.fromJson(
    Json.asObject(jsonDecode(source), 'service account key'),
    scopes: scopes,
    httpClient: httpClient,
  );

  @override
  bool get canSignUrls => true;

  @override
  Future<GcpAccessToken> accessToken() {
    final cached = _cached;
    if (cached != null && !cached.isExpired(DateTime.now().toUtc())) {
      return Future.value(cached);
    }
    return _inFlight ??= _exchangeJwt()
        .then((token) {
          _cached = token;
          return token;
        })
        .whenComplete(() => _inFlight = null);
  }

  @override
  Future<Uint8List> signRsaSha256(Uint8List data) async {
    final signer = RSASigner(SHA256Digest(), _sha256DigestIdentifier)
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    return signer.generateSignature(data).bytes;
  }

  @override
  Future<void> close() async {
    if (_ownsClient) _http.close();
  }

  /// The DER object identifier for SHA-256, as PointyCastle's [RSASigner]
  /// wants it: hex of the encoded `AlgorithmIdentifier`.
  static const String _sha256DigestIdentifier = '0609608648016503040201';

  /// Performs the JWT bearer grant: sign a short assertion, trade it for an
  /// access token.
  Future<GcpAccessToken> _exchangeJwt() async {
    final now = DateTime.now().toUtc();
    final issuedAt = now.millisecondsSinceEpoch ~/ 1000;
    // One hour is the maximum Google accepts for an assertion.
    final expiry = issuedAt + 3600;

    final header = _base64Url(
      utf8.encode(jsonEncode({'alg': 'RS256', 'typ': 'JWT'})),
    );
    final claims = _base64Url(
      utf8.encode(
        jsonEncode({
          'iss': clientEmail,
          'scope': scopes.join(' '),
          'aud': tokenUri.toString(),
          'iat': issuedAt,
          'exp': expiry,
        }),
      ),
    );
    final signature = _base64Url(
      await signRsaSha256(Uint8List.fromList(utf8.encode('$header.$claims'))),
    );
    final assertion = '$header.$claims.$signature';

    final http.Response response;
    try {
      response = await _http.post(
        tokenUri,
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          'assertion': assertion,
        },
      );
    } on http.ClientException catch (e) {
      throw StorageException('Google token exchange failed: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw StorageException(
        'Google token exchange failed with ${response.statusCode}: '
        '${response.body}',
      );
    }
    final body = Json.asObject(jsonDecode(response.body), 'token response');
    return GcpAccessToken(
      token: Json.requireString(body, 'access_token'),
      expiresAt: now.add(
        Duration(seconds: Json.optInt(body, 'expires_in', 3600)!),
      ),
    );
  }

  /// Parses a PEM-encoded PKCS#8 (`BEGIN PRIVATE KEY`) or PKCS#1
  /// (`BEGIN RSA PRIVATE KEY`) RSA private key.
  ///
  /// Google's service account JSON carries PKCS#8; the PKCS#1 form is accepted
  /// too so a key converted by `openssl rsa` still works.
  static RSAPrivateKey parsePrivateKeyPem(String pem) {
    final body = pem
        .replaceAll(RegExp(r'-----(BEGIN|END)[^-]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    if (body.isEmpty) {
      throw const ValidationException(
        'Private key is empty or not PEM-encoded',
        field: 'private_key',
      );
    }

    final Uint8List der;
    try {
      der = base64Decode(body);
    } on FormatException catch (e) {
      throw ValidationException(
        'Private key is not valid base64: ${e.message}',
        field: 'private_key',
      );
    }

    try {
      final top = ASN1Parser(der).nextObject() as ASN1Sequence;
      // PKCS#8 wraps the PKCS#1 key in an OCTET STRING at index 2; a bare
      // PKCS#1 key has its modulus as an INTEGER at index 1.
      final isPkcs8 =
          top.elements.length >= 3 && top.elements[2] is ASN1OctetString;
      final key = isPkcs8
          ? ASN1Parser((top.elements[2] as ASN1OctetString).octets).nextObject()
                as ASN1Sequence
          : top;

      if (key.elements.length < 9) {
        throw const ValidationException(
          'Private key is not a complete RSA key (expected 9 components)',
          field: 'private_key',
        );
      }
      BigInt at(int index) =>
          (key.elements[index] as ASN1Integer).valueAsBigInteger;

      // RSAPrivateKey ::= { version, modulus, publicExponent, privateExponent,
      //                     prime1, prime2, exponent1, exponent2, coefficient }
      return RSAPrivateKey(at(1), at(3), at(4), at(5));
    } on ValidationException {
      rethrow;
    } on Object catch (e) {
      throw ValidationException(
        'Cannot parse RSA private key: $e',
        field: 'private_key',
      );
    }
  }

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

/// A [GcpCredentialsProvider] reading the ambient identity from the GCP
/// metadata server.
///
/// Works on GCE, GKE, Cloud Run, Cloud Functions and App Engine, where the
/// runtime hands out tokens for the attached service account with no key file
/// to distribute — the safest option when the registry runs on Google Cloud.
///
/// It cannot sign URLs ([canSignUrls] is `false`), because there is no private
/// key to sign with; `GcsObjectStorage` then streams downloads through the hub.
/// To get redirected downloads on Cloud Run, supply a
/// [GcpServiceAccountCredentials] instead.
class GcpMetadataServerCredentials implements GcpCredentialsProvider {
  /// The metadata server base URI.
  final Uri metadataUri;

  final http.Client _http;
  final bool _ownsClient;

  GcpAccessToken? _cached;
  Future<GcpAccessToken>? _inFlight;
  String? _clientEmail;

  /// Creates a metadata-server provider.
  GcpMetadataServerCredentials({Uri? metadataUri, http.Client? httpClient})
    : metadataUri = metadataUri ?? Uri.http('metadata.google.internal', '/'),
      _http = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  @override
  String? get clientEmail => _clientEmail;

  @override
  bool get canSignUrls => false;

  @override
  Future<GcpAccessToken> accessToken() {
    final cached = _cached;
    if (cached != null && !cached.isExpired(DateTime.now().toUtc())) {
      return Future.value(cached);
    }
    return _inFlight ??= _fetch()
        .then((token) {
          _cached = token;
          return token;
        })
        .whenComplete(() => _inFlight = null);
  }

  @override
  Future<Uint8List> signRsaSha256(Uint8List data) async =>
      throw const UnsupportedOperationException(
        'The GCP metadata server holds no private key, so V4 URLs cannot be '
        'signed locally. Use GcpServiceAccountCredentials for signed '
        'downloads, or let the hub stream the bytes.',
      );

  @override
  Future<void> close() async {
    if (_ownsClient) _http.close();
  }

  Future<GcpAccessToken> _fetch() async {
    final now = DateTime.now().toUtc();
    final url = metadataUri.replace(
      path: '/computeMetadata/v1/instance/service-accounts/default/token',
    );
    final http.Response response;
    try {
      response = await _http.get(url, headers: {'metadata-flavor': 'Google'});
    } on http.ClientException catch (e) {
      throw StorageException(
        'GCP metadata server is unreachable at $url: ${e.message}. This '
        'provider only works on Google Cloud; use '
        'GcpServiceAccountCredentials elsewhere.',
      );
    }
    if (response.statusCode != 200) {
      throw StorageException(
        'GCP metadata server returned ${response.statusCode}: ${response.body}',
      );
    }
    final body = Json.asObject(jsonDecode(response.body), 'token response');
    return GcpAccessToken(
      token: Json.requireString(body, 'access_token'),
      expiresAt: now.add(
        Duration(seconds: Json.optInt(body, 'expires_in', 3600)!),
      ),
    );
  }
}

/// A [GcpCredentialsProvider] wrapping a token obtained elsewhere — by
/// `gcloud auth print-access-token`, by `package:googleapis_auth`, or by an
/// application's own OAuth flow.
///
/// The escape hatch: anything that can produce a bearer token can drive the GCS
/// backend without this package taking a dependency on a full auth library.
class GcpStaticCredentials implements GcpCredentialsProvider {
  final GcpAccessToken _token;

  @override
  final String? clientEmail;

  /// Wraps [token].
  const GcpStaticCredentials(GcpAccessToken token, {this.clientEmail})
    : _token = token;

  /// Wraps a raw token string valid for [validFor] (default one hour).
  GcpStaticCredentials.of(
    String token, {
    Duration validFor = const Duration(hours: 1),
    this.clientEmail,
  }) : _token = GcpAccessToken(
         token: token,
         expiresAt: DateTime.now().toUtc().add(validFor),
       );

  @override
  bool get canSignUrls => false;

  @override
  Future<GcpAccessToken> accessToken() async => _token;

  @override
  Future<Uint8List> signRsaSha256(Uint8List data) async =>
      throw const UnsupportedOperationException(
        'A static access token holds no private key, so V4 URLs cannot be '
        'signed. Use GcpServiceAccountCredentials for signed downloads.',
      );

  @override
  Future<void> close() async {}
}
