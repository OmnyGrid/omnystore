import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

/// A freshly generated RSA key, encoded exactly as a Google service-account
/// JSON document carries one.
///
/// **Nothing key-shaped is committed to this repository.** A real private key
/// in a public repo trips every secret scanner, has to be re-verified as
/// harmless by anyone auditing the tree, and sets a poor example — so the key
/// is generated per test run instead. It costs about 100 ms, and the material
/// never outlives the process.
///
/// The PKCS#8 wrapper is built here rather than taken from a fixture, so
/// `GcpServiceAccountCredentials.parsePrivateKeyPem` still parses a genuine
/// `PrivateKeyInfo` structure — the same one `openssl genpkey` produces.
/// [matches] then checks that every component came back exactly, which is what
/// stops a structurally wrong parse from passing merely because this file and
/// the parser happen to agree with each other.
class TestServiceAccountKey {
  /// The generated private key.
  final RSAPrivateKey privateKey;

  /// The matching public key, for verifying signatures the parser's key makes.
  final RSAPublicKey publicKey;

  /// [privateKey] as a PKCS#8 PEM, the form Google emits.
  final String privateKeyPem;

  /// The service account e-mail these credentials claim.
  final String clientEmail;

  TestServiceAccountKey._({
    required this.privateKey,
    required this.publicKey,
    required this.privateKeyPem,
    required this.clientEmail,
  });

  /// Generates a key and wraps it as a service-account credential.
  ///
  /// [bits] is 2048 by default — the size Google issues, and the size worth
  /// exercising the ASN.1 path at.
  factory TestServiceAccountKey.generate({
    int bits = 2048,
    String clientEmail = 'releases@omnystore-test.iam.gserviceaccount.com',
  }) {
    final seed = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final random = SecureRandom('Fortuna')..seed(KeyParameter(seed));

    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    final private = pair.privateKey;

    return TestServiceAccountKey._(
      privateKey: private,
      publicKey: pair.publicKey,
      privateKeyPem: encodePkcs8Pem(private),
      clientEmail: clientEmail,
    );
  }

  /// A service-account key document shaped exactly as Google emits one.
  Map<String, dynamic> get serviceAccountJson => {
    'type': 'service_account',
    'project_id': 'omnystore-test',
    'private_key_id': 'test-key-id',
    'private_key': privateKeyPem,
    'client_email': clientEmail,
    'client_id': '000000000000000000000',
    'token_uri': 'https://oauth2.googleapis.com/token',
  };

  /// Whether [parsed] carries exactly the components of [privateKey].
  ///
  /// Every field is compared, not just the modulus: a parser that read the
  /// PKCS#1 sequence at the wrong offsets could still produce a plausible
  /// modulus while getting the private exponent wrong, and that failure would
  /// only show up as a signature nobody can verify.
  bool matches(RSAPrivateKey parsed) =>
      parsed.modulus == privateKey.modulus &&
      parsed.privateExponent == privateKey.privateExponent &&
      parsed.p == privateKey.p &&
      parsed.q == privateKey.q;

  /// Encodes [key] as a PKCS#8 `PrivateKeyInfo` PEM.
  ///
  /// ```text
  /// SEQUENCE {
  ///   INTEGER 0                                   -- version
  ///   SEQUENCE { OID 1.2.840.113549.1.1.1, NULL } -- rsaEncryption
  ///   OCTET STRING { PKCS#1 RSAPrivateKey }
  /// }
  /// ```
  static String encodePkcs8Pem(RSAPrivateKey key) {
    final n = key.modulus!;
    final d = key.privateExponent!;
    final p = key.p!;
    final q = key.q!;
    final one = BigInt.one;

    final pkcs1 = ASN1Sequence()
      ..add(ASN1Integer(BigInt.zero)) // version
      ..add(ASN1Integer(n)) // modulus
      ..add(ASN1Integer(key.publicExponent!)) // publicExponent
      ..add(ASN1Integer(d)) // privateExponent
      ..add(ASN1Integer(p)) // prime1
      ..add(ASN1Integer(q)) // prime2
      ..add(ASN1Integer(d % (p - one))) // exponent1
      ..add(ASN1Integer(d % (q - one))) // exponent2
      ..add(ASN1Integer(q.modInverse(p))); // coefficient

    final algorithm = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
      ..add(ASN1Null());

    final pkcs8 = ASN1Sequence()
      ..add(ASN1Integer(BigInt.zero))
      ..add(algorithm)
      ..add(ASN1OctetString(pkcs1.encodedBytes));

    return _pem('PRIVATE KEY', pkcs8.encodedBytes);
  }

  /// Encodes [key] as a bare PKCS#1 `RSA PRIVATE KEY` PEM — the form
  /// `openssl rsa` produces, which the parser also accepts.
  static String encodePkcs1Pem(RSAPrivateKey key) {
    final d = key.privateExponent!;
    final p = key.p!;
    final q = key.q!;
    final one = BigInt.one;

    final pkcs1 = ASN1Sequence()
      ..add(ASN1Integer(BigInt.zero))
      ..add(ASN1Integer(key.modulus!))
      ..add(ASN1Integer(key.publicExponent!))
      ..add(ASN1Integer(d))
      ..add(ASN1Integer(p))
      ..add(ASN1Integer(q))
      ..add(ASN1Integer(d % (p - one)))
      ..add(ASN1Integer(d % (q - one)))
      ..add(ASN1Integer(q.modInverse(p)));

    return _pem('RSA PRIVATE KEY', pkcs1.encodedBytes);
  }

  /// Wraps [der] in PEM armour with 64-character lines.
  static String _pem(String label, Uint8List der) {
    final body = base64.encode(der);
    final lines = <String>[];
    for (var i = 0; i < body.length; i += 64) {
      lines.add(body.substring(i, min(i + 64, body.length)));
    }
    return [
      '-----BEGIN $label-----',
      ...lines,
      '-----END $label-----',
      '',
    ].join('\n');
  }
}
