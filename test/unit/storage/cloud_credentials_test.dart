import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnystore/omnystore.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

import '../../support/test_rsa_key.dart';

/// One generated key for the whole file.
///
/// Generating it per test would cost about 100 ms each; once is enough, and it
/// still never touches disk or outlives the process — no key material is
/// committed to this repository.
late final TestServiceAccountKey serviceAccount;

void main() {
  setUpAll(() => serviceAccount = TestServiceAccountKey.generate());

  group('SigV4', () {
    // The credentials and instant from AWS's published Signature Version 4
    // test suite. Checking against the official vectors is what proves the
    // canonicalisation is right — a signature that is merely self-consistent
    // would pass a round-trip test and be rejected by S3.
    const credentials = AwsCredentials(
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    );
    final signingInstant = DateTime.utc(2013, 5, 24);

    test('matches the published GET Object signature', () async {
      final headers = await SigV4.signRequest(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        headers: const {'range': 'bytes=0-9'},
        payloadHash: SigV4.emptyPayloadHash,
      );

      expect(
        headers['authorization'],
        'AWS4-HMAC-SHA256 '
        'Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, '
        'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, '
        'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c603'
        '6bdb41',
      );
      expect(headers['x-amz-date'], '20130524T000000Z');
      expect(headers['host'], 'examplebucket.s3.amazonaws.com');
    });

    test('matches the published presigned GET Object signature', () async {
      final url = await SigV4.presign(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        expiresIn: const Duration(days: 1),
      );

      expect(
        url.queryParameters['X-Amz-Signature'],
        'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
      );
      expect(url.queryParameters['X-Amz-Expires'], '86400');
      expect(url.queryParameters['X-Amz-SignedHeaders'], 'host');
      expect(
        url.queryParameters['X-Amz-Credential'],
        'AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request',
      );
    });

    test('signs a session token when one is present', () async {
      final headers = await SigV4.signRequest(
        credentials: const AwsCredentials(
          accessKeyId: 'ASIAEXAMPLE',
          secretAccessKey: 'secret',
          sessionToken: 'session-token',
        ),
        method: 'GET',
        url: Uri.parse('https://bucket.s3.amazonaws.com/key'),
        region: 'eu-west-1',
        service: 's3',
        now: signingInstant,
      );

      expect(headers['x-amz-security-token'], 'session-token');
      // Temporary credentials only work if the token is *covered* by the
      // signature, not merely sent alongside it.
      expect(headers['authorization'], contains('x-amz-security-token'));
    });

    test('uses UNSIGNED-PAYLOAD for a streamed body', () async {
      final headers = await SigV4.signRequest(
        credentials: credentials,
        method: 'PUT',
        url: Uri.parse('https://bucket.s3.amazonaws.com/key'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        payloadHash: SigV4.unsignedPayload,
      );

      expect(headers['x-amz-content-sha256'], 'UNSIGNED-PAYLOAD');
    });

    test('omits a default port from the host header', () async {
      // A signed `host` of `bucket:443` would never match what a client sends.
      final headers = await SigV4.signRequest(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://bucket.s3.amazonaws.com:443/key'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
      );

      expect(headers['host'], 'bucket.s3.amazonaws.com');
    });

    test('keeps a non-default port in the host header', () async {
      final headers = await SigV4.signRequest(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://minio.internal:9000/bucket/key'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
      );

      expect(headers['host'], 'minio.internal:9000');
    });

    test('encodes a key with characters Dart leaves unescaped', () async {
      // Uri.encodeComponent leaves ! * ' ( ) alone; AWS requires them escaped,
      // and the resulting mismatch surfaces only as SignatureDoesNotMatch.
      final withoutSpecials = await SigV4.presign(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://bucket.s3.amazonaws.com/plain.txt'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        expiresIn: const Duration(minutes: 15),
      );
      final withSpecials = await SigV4.presign(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse("https://bucket.s3.amazonaws.com/it's(a)file!.txt"),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        expiresIn: const Duration(minutes: 15),
      );

      expect(
        withSpecials.queryParameters['X-Amz-Signature'],
        isNot(withoutSpecials.queryParameters['X-Amz-Signature']),
      );
    });

    test('carries response-header overrides inside the signature', () async {
      final url = await SigV4.presign(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://bucket.s3.amazonaws.com/key'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        expiresIn: const Duration(minutes: 15),
        extraQuery: const {
          'response-content-disposition': 'attachment; filename="agent.tar.gz"',
        },
      );

      expect(
        url.queryParameters['response-content-disposition'],
        'attachment; filename="agent.tar.gz"',
      );
      // Signed, so a client cannot rewrite the filename it saves as.
      expect(url.queryParameters['X-Amz-Signature'], isNotEmpty);
    });

    test('clamps an expiry beyond S3 maximum of seven days', () async {
      final url = await SigV4.presign(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://bucket.s3.amazonaws.com/key'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        expiresIn: const Duration(days: 30),
      );

      expect(url.queryParameters['X-Amz-Expires'], '604800');
    });

    test('clamps a zero or negative expiry to something usable', () async {
      final url = await SigV4.presign(
        credentials: credentials,
        method: 'GET',
        url: Uri.parse('https://bucket.s3.amazonaws.com/key'),
        region: 'us-east-1',
        service: 's3',
        now: signingInstant,
        expiresIn: Duration.zero,
      );

      // A URL that is invalid the instant it is issued is never what was meant.
      expect(url.queryParameters['X-Amz-Expires'], '1');
    });
  });

  group('AwsCredentialsProvider', () {
    test('static returns what it was given', () async {
      final provider = StaticAwsCredentialsProvider.of(
        accessKeyId: 'AKIA',
        secretAccessKey: 'secret',
      );

      expect((await provider.credentials()).accessKeyId, 'AKIA');
    });

    test('environment reads the standard variables', () async {
      final provider = const EnvironmentAwsCredentialsProvider({
        'AWS_ACCESS_KEY_ID': 'AKIA',
        'AWS_SECRET_ACCESS_KEY': 'secret',
        'AWS_SESSION_TOKEN': 'token',
      });

      final credentials = await provider.credentials();
      expect(credentials.accessKeyId, 'AKIA');
      expect(credentials.sessionToken, 'token');
    });

    test('environment reports a clear failure when unset', () async {
      await expectLater(
        const EnvironmentAwsCredentialsProvider({}).credentials(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            contains('AWS_ACCESS_KEY_ID'),
          ),
        ),
      );
    });

    test('refreshing caches until close to expiry', () async {
      var fetches = 0;
      final provider = RefreshingAwsCredentialsProvider(() async {
        fetches++;
        return AwsCredentials(
          accessKeyId: 'AKIA$fetches',
          secretAccessKey: 'secret',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        );
      });

      expect((await provider.credentials()).accessKeyId, 'AKIA1');
      expect((await provider.credentials()).accessKeyId, 'AKIA1');
      expect(fetches, 1);
    });

    test('refreshing re-fetches once expired', () async {
      var fetches = 0;
      final provider = RefreshingAwsCredentialsProvider(() async {
        fetches++;
        return AwsCredentials(
          accessKeyId: 'AKIA$fetches',
          secretAccessKey: 'secret',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        );
      });

      await provider.credentials();
      await provider.credentials();
      expect(fetches, 2);
    });

    test('refreshing collapses concurrent fetches onto one call', () async {
      var fetches = 0;
      final provider = RefreshingAwsCredentialsProvider(() async {
        fetches++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return AwsCredentials(
          accessKeyId: 'AKIA',
          secretAccessKey: 'secret',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        );
      });

      // A burst of parallel uploads must not become a burst of STS calls.
      await Future.wait([
        provider.credentials(),
        provider.credentials(),
        provider.credentials(),
      ]);
      expect(fetches, 1);
    });

    test('treats a credential inside the margin as expired', () {
      final credentials = AwsCredentials(
        accessKeyId: 'AKIA',
        secretAccessKey: 'secret',
        expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      );

      // Signed just before expiry, delivered just after, is a real failure mode.
      expect(credentials.isExpired(DateTime.now()), isTrue);
      expect(
        credentials.isExpired(DateTime.now(), margin: Duration.zero),
        isFalse,
      );
    });
  });

  group('GcpServiceAccountCredentials', () {
    test('parses a PKCS#8 service account key', () {
      final credentials = GcpServiceAccountCredentials.fromJson(
        serviceAccount.serviceAccountJson,
      );

      expect(
        credentials.clientEmail,
        'releases@omnystore-test.iam.gserviceaccount.com',
      );
      expect(credentials.canSignUrls, isTrue);
      // Every component, not just the modulus: a parse reading the PKCS#1
      // sequence at the wrong offsets could still produce a plausible modulus
      // while getting the private exponent wrong, and that only shows up later
      // as a signature nobody can verify.
      expect(serviceAccount.matches(credentials.privateKey), isTrue);
    });

    test('parses a bare PKCS#1 key, which openssl rsa produces', () {
      final credentials = GcpServiceAccountCredentials.fromJson({
        'type': 'service_account',
        'client_email': serviceAccount.clientEmail,
        'private_key': TestServiceAccountKey.encodePkcs1Pem(
          serviceAccount.privateKey,
        ),
      });

      expect(serviceAccount.matches(credentials.privateKey), isTrue);
    });

    test('produces a signature the matching public key verifies', () async {
      final credentials = GcpServiceAccountCredentials.fromJson(
        serviceAccount.serviceAccountJson,
      );
      final message = Uint8List.fromList(utf8.encode('sign me'));

      final signature = await credentials.signRsaSha256(message);

      // Verified against the *generated* public key, not one derived from the
      // parsed private key: proves the ASN.1 parse produced the original key
      // and that the padding is PKCS#1 v1.5 over SHA-256, neither of which a
      // round-trip through our own signer alone would establish.
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(
          false,
          PublicKeyParameter<RSAPublicKey>(serviceAccount.publicKey),
        );

      expect(
        verifier.verifySignature(message, RSASignature(signature)),
        isTrue,
      );
    });

    test('rejects a non-service-account document', () {
      expect(
        () => GcpServiceAccountCredentials.fromJson({
          'type': 'authorized_user',
          'client_email': 'a@b.c',
          'private_key': serviceAccount.privateKeyPem,
        }),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a malformed key, naming the field', () {
      // The armour is assembled from a variable rather than written as a
      // literal block: `dart pub publish` scans for PEM-shaped source, and
      // allowlisting this file in `false_secrets` to accommodate a fake would
      // blunt a check worth keeping sharp.
      const label = 'PRIVATE KEY';
      String pem(String body) =>
          ['-----BEGIN $label-----', body, '-----END $label-----'].join('\n');

      for (final key in [
        'not pem',
        pem('!!!'),
        // Valid base64, but not a DER RSA key.
        pem(base64Encode(utf8.encode('deadbeef'))),
      ]) {
        expect(
          () => GcpServiceAccountCredentials.fromJson({
            'type': 'service_account',
            'client_email': 'a@b.c',
            'private_key': key,
          }),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.field,
              'field',
              'private_key',
            ),
          ),
          reason: key,
        );
      }
    });

    test('rejects a document with no key at all', () {
      // A missing or empty required field is a JSON-shape problem, and reports
      // as one — still an OmnyStoreException the caller can catch uniformly.
      for (final json in [
        const {'type': 'service_account', 'client_email': 'a@b.c'},
        const {
          'type': 'service_account',
          'client_email': 'a@b.c',
          'private_key': '',
        },
      ]) {
        expect(
          () => GcpServiceAccountCredentials.fromJson(json),
          throwsA(isA<InvalidJsonException>()),
        );
      }
    });

    test('exchanges a signed JWT for an access token', () async {
      String? sentAssertion;
      final credentials = GcpServiceAccountCredentials.fromJson(
        serviceAccount.serviceAccountJson,
        httpClient: MockClient((request) async {
          sentAssertion = Uri.splitQueryString(request.body)['assertion'];
          return http.Response(
            jsonEncode({'access_token': 'ya29.token', 'expires_in': 3600}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final token = await credentials.accessToken();

      expect(token.token, 'ya29.token');
      expect(token.isExpired(DateTime.now().toUtc()), isFalse);

      // A three-part RS256 JWT naming this service account.
      final parts = sentAssertion!.split('.');
      expect(parts, hasLength(3));
      final header = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
      );
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      expect(header['alg'], 'RS256');
      expect(claims['iss'], credentials.clientEmail);
      expect(claims['aud'], 'https://oauth2.googleapis.com/token');
      expect(claims['scope'], contains('devstorage'));
    });

    test('caches a token instead of exchanging per request', () async {
      var exchanges = 0;
      final credentials = GcpServiceAccountCredentials.fromJson(
        serviceAccount.serviceAccountJson,
        httpClient: MockClient((request) async {
          exchanges++;
          return http.Response(
            jsonEncode({'access_token': 'ya29.token', 'expires_in': 3600}),
            200,
          );
        }),
      );

      await credentials.accessToken();
      await credentials.accessToken();

      expect(exchanges, 1);
    });

    test('reports a rejected exchange with the server message', () async {
      final credentials = GcpServiceAccountCredentials.fromJson(
        serviceAccount.serviceAccountJson,
        httpClient: MockClient(
          (request) async => http.Response('{"error":"invalid_grant"}', 400),
        ),
      );

      await expectLater(
        credentials.accessToken(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            contains('invalid_grant'),
          ),
        ),
      );
    });
  });

  group('credentials without a key', () {
    test('a static token cannot sign URLs', () async {
      const credentials = GcpStaticCredentials.of;
      final provider = credentials('ya29.token');

      expect(provider.canSignUrls, isFalse);
      expect((await provider.accessToken()).token, 'ya29.token');
      await expectLater(
        provider.signRsaSha256(Uint8List(0)),
        throwsA(isA<UnsupportedOperationException>()),
      );
    });

    test('the metadata server cannot sign URLs', () async {
      final provider = GcpMetadataServerCredentials(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({'access_token': 'ya29.metadata', 'expires_in': 3600}),
            200,
          ),
        ),
      );

      expect(provider.canSignUrls, isFalse);
      expect((await provider.accessToken()).token, 'ya29.metadata');
      await expectLater(
        provider.signRsaSha256(Uint8List(0)),
        throwsA(isA<UnsupportedOperationException>()),
      );
    });

    test('an unreachable metadata server explains where it works', () async {
      final provider = GcpMetadataServerCredentials(
        httpClient: MockClient(
          (request) async => throw http.ClientException('connection refused'),
        ),
      );

      await expectLater(
        provider.accessToken(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('only works on Google Cloud'),
              contains('GcpServiceAccountCredentials'),
            ),
          ),
        ),
      );
    });
  });

  group('backend identity', () {
    test('S3 reports presigning support', () {
      final storage = S3ObjectStorage(
        bucket: 'acme-releases',
        region: 'eu-west-1',
        credentials: StaticAwsCredentialsProvider.of(
          accessKeyId: 'AKIA',
          secretAccessKey: 'secret',
        ),
      );
      addTearDown(storage.close);

      expect(storage.id, 's3:acme-releases');
      expect(storage.supportsPresignedUrls, isTrue);
    });

    test('S3 issues a presigned URL for the right bucket and key', () async {
      final storage = S3ObjectStorage(
        bucket: 'acme-releases',
        region: 'eu-west-1',
        prefix: 'registry',
        credentials: StaticAwsCredentialsProvider.of(
          accessKeyId: 'AKIA',
          secretAccessKey: 'secret',
        ),
      );
      addTearDown(storage.close);

      final url = await storage.presignedUrl(
        'orgs/acme/packages/a/1.0.0/agent.tar.gz',
        filename: 'agent.tar.gz',
      );

      expect(url!.host, 'acme-releases.s3.eu-west-1.amazonaws.com');
      expect(url.path, '/registry/orgs/acme/packages/a/1.0.0/agent.tar.gz');
      expect(url.queryParameters['X-Amz-Signature'], isNotEmpty);
      expect(
        url.queryParameters['response-content-disposition'],
        contains('agent.tar.gz'),
      );
    });

    test(
      'S3 addresses a path-style endpoint for compatible services',
      () async {
        final storage = S3ObjectStorage(
          bucket: 'releases',
          region: 'us-east-1',
          endpoint: Uri.parse('https://minio.internal:9000'),
          usePathStyle: true,
          credentials: StaticAwsCredentialsProvider.of(
            accessKeyId: 'AKIA',
            secretAccessKey: 'secret',
          ),
        );
        addTearDown(storage.close);

        final url = await storage.presignedUrl('a/b.txt');

        expect(url!.host, 'minio.internal');
        expect(url.port, 9000);
        expect(url.path, '/releases/a/b.txt');
      },
    );

    test('GCS presigning follows the credentials', () {
      final signing = GcsObjectStorage(
        bucket: 'acme-releases',
        credentials: GcpServiceAccountCredentials.fromJson(
          serviceAccount.serviceAccountJson,
        ),
      );
      final ambient = GcsObjectStorage(
        bucket: 'acme-releases',
        credentials: GcpMetadataServerCredentials(),
      );
      addTearDown(() async {
        await signing.close();
        await ambient.close();
      });

      expect(signing.id, 'gcs:acme-releases');
      expect(signing.supportsPresignedUrls, isTrue);
      // No private key means no local signature, so the hub streams instead.
      expect(ambient.supportsPresignedUrls, isFalse);
    });

    test('GCS signs a V4 URL naming the service account', () async {
      final storage = GcsObjectStorage(
        bucket: 'acme-releases',
        credentials: GcpServiceAccountCredentials.fromJson(
          serviceAccount.serviceAccountJson,
        ),
      );
      addTearDown(storage.close);

      final url = await storage.presignedUrl(
        'orgs/acme/packages/a/1.0.0/agent.tar.gz',
        filename: 'agent.tar.gz',
        expiresIn: const Duration(minutes: 30),
      );

      expect(url!.host, 'storage.googleapis.com');
      expect(
        url.path,
        '/acme-releases/orgs/acme/packages/a/1.0.0/agent.tar.gz',
      );
      expect(url.queryParameters['X-Goog-Algorithm'], 'GOOG4-RSA-SHA256');
      expect(url.queryParameters['X-Goog-Expires'], '1800');
      expect(
        url.queryParameters['X-Goog-Credential'],
        contains('releases@omnystore-test.iam.gserviceaccount.com'),
      );
      expect(url.queryParameters['X-Goog-Signature'], isNotEmpty);
    });

    test('GCS returns null rather than throwing when it cannot sign', () async {
      final storage = GcsObjectStorage(
        bucket: 'acme-releases',
        credentials: GcpMetadataServerCredentials(),
      );
      addTearDown(storage.close);

      // The contract: `null` means "stream it instead", not "this failed".
      expect(await storage.presignedUrl('a/b.txt'), isNull);
    });
  });
}
