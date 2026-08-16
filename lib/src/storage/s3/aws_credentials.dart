import 'package:meta/meta.dart';

import '../../exceptions/omnystore_exception.dart';

/// A set of AWS credentials.
///
/// [sessionToken] is present for temporary credentials — an assumed role, an
/// EC2/ECS instance profile, a web-identity federation. When it is set it must
/// be sent as `x-amz-security-token` and included in the signature, which
/// [SigV4] handles.
@immutable
class AwsCredentials {
  /// The access key id (`AKIA…`, `ASIA…` for temporary credentials).
  final String accessKeyId;

  /// The secret access key.
  final String secretAccessKey;

  /// The session token for temporary credentials, or `null` for long-lived
  /// ones.
  final String? sessionToken;

  /// When these credentials expire, or `null` if they do not.
  final DateTime? expiresAt;

  /// Creates a credential set.
  const AwsCredentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
    this.expiresAt,
  });

  /// Whether these credentials have expired as of [now], with a small safety
  /// margin so a request signed just before expiry does not arrive just after.
  bool isExpired(DateTime now, {Duration margin = const Duration(minutes: 5)}) {
    final expiry = expiresAt;
    return expiry != null && !now.add(margin).isBefore(expiry);
  }

  @override
  String toString() =>
      'AwsCredentials($accessKeyId, '
      '${sessionToken == null ? 'long-lived' : 'temporary'})';
}

/// Supplies AWS credentials, refreshing them when they expire.
///
/// A port rather than a fixed value because the credentials a long-running
/// registry signs with are usually temporary: an instance profile or an
/// assumed role hands out an hour-long token that has to be re-fetched. A
/// provider is called before every signature, so it is the seam where that
/// refresh happens.
abstract interface class AwsCredentialsProvider {
  /// The credentials to sign the next request with.
  Future<AwsCredentials> credentials();
}

/// An [AwsCredentialsProvider] returning a fixed credential set.
class StaticAwsCredentialsProvider implements AwsCredentialsProvider {
  final AwsCredentials _credentials;

  /// Wraps [credentials].
  const StaticAwsCredentialsProvider(this._credentials);

  /// Creates a provider from raw key material.
  StaticAwsCredentialsProvider.of({
    required String accessKeyId,
    required String secretAccessKey,
    String? sessionToken,
  }) : _credentials = AwsCredentials(
         accessKeyId: accessKeyId,
         secretAccessKey: secretAccessKey,
         sessionToken: sessionToken,
       );

  @override
  Future<AwsCredentials> credentials() async => _credentials;
}

/// An [AwsCredentialsProvider] that caches what [fetch] returns until it is
/// close to expiring, then fetches again.
///
/// The building block for any dynamic source — an instance-profile endpoint, an
/// STS `AssumeRole` call, a secrets manager. [fetch] is called at most once at
/// a time even under concurrent signing, so a burst of uploads does not turn
/// into a burst of credential requests.
class RefreshingAwsCredentialsProvider implements AwsCredentialsProvider {
  /// Fetches a fresh credential set.
  final Future<AwsCredentials> Function() fetch;

  /// How long before expiry to refresh.
  final Duration refreshMargin;

  AwsCredentials? _cached;
  Future<AwsCredentials>? _inFlight;

  /// Creates a refreshing provider over [fetch].
  RefreshingAwsCredentialsProvider(
    this.fetch, {
    this.refreshMargin = const Duration(minutes: 5),
  });

  @override
  Future<AwsCredentials> credentials() {
    final cached = _cached;
    if (cached != null &&
        !cached.isExpired(DateTime.now(), margin: refreshMargin)) {
      return Future.value(cached);
    }
    // Collapse concurrent refreshes onto one in-flight fetch.
    return _inFlight ??= fetch()
        .then((credentials) {
          _cached = credentials;
          return credentials;
        })
        .whenComplete(() => _inFlight = null);
  }
}

/// An [AwsCredentialsProvider] reading the standard AWS environment variables.
///
/// Reads `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and the optional
/// `AWS_SESSION_TOKEN` from [environment]. Taking the environment as a
/// parameter rather than reading `Platform.environment` directly keeps this
/// class testable and keeps `dart:io` out of it, so the S3 backend stays
/// usable anywhere `package:http` is.
///
/// ```dart
/// EnvironmentAwsCredentialsProvider(Platform.environment);
/// ```
class EnvironmentAwsCredentialsProvider implements AwsCredentialsProvider {
  /// The environment to read from.
  final Map<String, String> environment;

  /// Creates a provider over [environment].
  const EnvironmentAwsCredentialsProvider(this.environment);

  @override
  Future<AwsCredentials> credentials() async {
    final accessKeyId = environment['AWS_ACCESS_KEY_ID'];
    final secretAccessKey = environment['AWS_SECRET_ACCESS_KEY'];
    if (accessKeyId == null || secretAccessKey == null) {
      throw const StorageException(
        'AWS credentials not found: set AWS_ACCESS_KEY_ID and '
        'AWS_SECRET_ACCESS_KEY, or pass an explicit AwsCredentialsProvider',
      );
    }
    return AwsCredentials(
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      sessionToken: environment['AWS_SESSION_TOKEN'],
    );
  }
}
