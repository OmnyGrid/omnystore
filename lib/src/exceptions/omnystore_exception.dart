import 'error_codes.dart';

/// Base type for every expected failure raised by OmnyStore.
///
/// The hierarchy is `sealed` so callers can pattern-match exhaustively:
///
/// ```dart
/// final message = switch (error) {
///   ReleaseNotFoundException e => 'no such release: ${e.reference}',
///   ChecksumMismatchException e => 'corrupt download (${e.expected})',
///   OmnyStoreException e => e.message,
/// };
/// ```
///
/// Every failure carries a stable [code] (see [ErrorCodes]) and the
/// [statusCode] the REST API should answer with, so the API layer renders any
/// of them uniformly and a client can reconstruct the original type from the
/// wire (see `omnyStoreExceptionForCode`).
///
/// This deliberately does *not* extend OmnyHub's own `sealed HubException`:
/// two sealed hierarchies cannot be merged. The API layer translates these into
/// OmnyHub's `AppException` seam instead, which is exactly what it is for.
sealed class OmnyStoreException implements Exception {
  /// Stable, machine-readable error code (see [ErrorCodes]).
  final String code;

  /// Human-readable description of the failure.
  final String message;

  /// The HTTP status code the REST API answers with for this failure.
  final int statusCode;

  /// Creates a failure with an explicit [message], [code] and [statusCode].
  const OmnyStoreException(
    this.message, {
    required this.code,
    required this.statusCode,
  });

  /// Structured fields that must survive a trip across the wire.
  ///
  /// [code] and [message] alone are not always enough to rebuild the original
  /// exception: a caller catching [ChecksumMismatchException] wants
  /// `expected`/`actual` as values, not as substrings of a sentence it would
  /// have to parse. Subclasses with such fields override this, and
  /// [omnyStoreExceptionForCode] reads them back.
  Map<String, Object?> get details => const {};

  @override
  String toString() => '$runtimeType($code): $message';
}

/// Invalid input: a malformed name, an unparsable version, a negative size, a
/// channel that does not match the version's pre-release tag, and so on.
class ValidationException extends OmnyStoreException {
  /// The offending field, if the failure is attributable to one.
  final String? field;

  /// Creates a validation failure with [message], optionally naming the [field]
  /// it applies to.
  const ValidationException(super.message, {this.field})
    : super(code: ErrorCodes.validationError, statusCode: 400);
}

/// A payload could not be parsed as the expected JSON shape.
class InvalidJsonException extends OmnyStoreException {
  /// Creates an invalid-JSON failure with [message].
  const InvalidJsonException(super.message)
    : super(code: ErrorCodes.invalidJson, statusCode: 400);
}

/// A referenced resource does not exist.
///
/// The concrete subtypes ([OrganizationNotFoundException],
/// [ProjectNotFoundException], [PackageNotFoundException],
/// [ReleaseNotFoundException], [AssetNotFoundException]) each carry their own
/// [ErrorCodes] value, so a caller can tell *which* link in the chain was
/// missing — `GET /packages/{id}/releases/latest` can fail because the package
/// is unknown or because it has no release on the requested channel, and those
/// deserve different handling.
sealed class NotFoundException extends OmnyStoreException {
  /// What was looked up (an id, a name, or a `package@version` reference).
  final String reference;

  /// Creates a not-found failure for [reference] with an explicit [code].
  const NotFoundException(
    super.message, {
    required super.code,
    required this.reference,
  }) : super(statusCode: 404);
}

/// The referenced organization does not exist.
class OrganizationNotFoundException extends NotFoundException {
  /// Creates the failure for the organization identified by [reference].
  OrganizationNotFoundException(String reference)
    : super(
        'Organization not found: $reference',
        code: ErrorCodes.organizationNotFound,
        reference: reference,
      );
}

/// The referenced project does not exist.
class ProjectNotFoundException extends NotFoundException {
  /// Creates the failure for the project identified by [reference].
  ProjectNotFoundException(String reference)
    : super(
        'Project not found: $reference',
        code: ErrorCodes.projectNotFound,
        reference: reference,
      );
}

/// The referenced package does not exist.
class PackageNotFoundException extends NotFoundException {
  /// Creates the failure for the package identified by [reference].
  PackageNotFoundException(String reference)
    : super(
        'Package not found: $reference',
        code: ErrorCodes.packageNotFound,
        reference: reference,
      );
}

/// The referenced release does not exist.
///
/// Also raised when a channel query (`latestBeta()`, `latest?channel=dev`)
/// finds no matching release — the reference then reads like `omnyagent@beta`.
class ReleaseNotFoundException extends NotFoundException {
  /// Creates the failure for the release identified by [reference].
  ReleaseNotFoundException(String reference)
    : super(
        'Release not found: $reference',
        code: ErrorCodes.releaseNotFound,
        reference: reference,
      );
}

/// The referenced asset does not exist.
class AssetNotFoundException extends NotFoundException {
  /// Creates the failure for the asset identified by [reference].
  AssetNotFoundException(String reference)
    : super(
        'Asset not found: $reference',
        code: ErrorCodes.assetNotFound,
        reference: reference,
      );
}

/// A resource with the same unique key already exists — a second organization
/// with one name, a re-published version, an asset filename used twice within
/// one release.
///
/// Releases are immutable once published, so re-publishing a version is a
/// conflict rather than an update; promote it across channels instead.
class ConflictException extends OmnyStoreException {
  /// The unique key that was already taken.
  final String reference;

  /// Creates a conflict failure for [reference] with [message].
  const ConflictException(super.message, {required this.reference})
    : super(code: ErrorCodes.conflict, statusCode: 409);
}

/// The caller is not authenticated (missing or invalid credentials).
class UnauthorizedException extends OmnyStoreException {
  /// Creates an unauthorized failure; defaults to a generic [message].
  const UnauthorizedException([super.message = 'Authentication required'])
    : super(code: ErrorCodes.unauthorized, statusCode: 401);
}

/// The caller is authenticated but not permitted to perform the operation.
class ForbiddenException extends OmnyStoreException {
  /// Creates a forbidden failure; defaults to a generic [message].
  const ForbiddenException([super.message = 'Access denied'])
    : super(code: ErrorCodes.forbidden, statusCode: 403);
}

/// A download could not be completed: the transport failed, the server answered
/// with an error status, or the stream ended short of the expected length.
class DownloadFailedException extends OmnyStoreException {
  /// The URL that was being downloaded.
  final Uri url;

  /// The HTTP status code received, if the failure was a bad response.
  final int? responseStatus;

  /// Creates a download failure for [url] with [message].
  const DownloadFailedException(
    super.message, {
    required this.url,
    this.responseStatus,
  }) : super(code: ErrorCodes.downloadFailed, statusCode: 502);

  @override
  Map<String, Object?> get details => {
    'url': url.toString(),
    'responseStatus': ?responseStatus,
  };
}

/// Downloaded bytes did not match the checksum recorded for the asset.
///
/// Treat the downloaded file as hostile: it was truncated, corrupted in
/// transit, or substituted. [DownloadManager] deletes the partial file before
/// throwing.
class ChecksumMismatchException extends OmnyStoreException {
  /// The checksum the asset record declares (lower-case hex).
  final String expected;

  /// The checksum actually computed over the received bytes (lower-case hex).
  final String actual;

  /// The hash algorithm used (always `sha256` today).
  final String algorithm;

  /// Creates a checksum mismatch between [expected] and [actual].
  ChecksumMismatchException({
    required this.expected,
    required this.actual,
    this.algorithm = 'sha256',
  }) : super(
         '$algorithm mismatch: expected $expected, got $actual — the '
         'downloaded data is corrupt and was discarded',
         code: ErrorCodes.checksumMismatch,
         statusCode: 422,
       );

  @override
  Map<String, Object?> get details => {
    'expected': expected,
    'actual': actual,
    'algorithm': algorithm,
  };
}

/// The object storage backend failed (unreachable bucket, denied credentials,
/// an I/O error writing the local directory, ...).
class StorageException extends OmnyStoreException {
  /// The storage key involved, if the failure is attributable to one object.
  final String? key;

  /// Creates a storage failure with [message], optionally naming the [key].
  const StorageException(super.message, {this.key})
    : super(code: ErrorCodes.storageError, statusCode: 500);
}

/// The REST API answered with a status or body the client could not accept.
///
/// Raised by [OmnyStoreClient]. When the server sent a well-formed error
/// envelope, [code] carries the server's own error code (so
/// `e.code == ErrorCodes.releaseNotFound` works across the wire) and
/// [statusCode] its status; otherwise [code] is [ErrorCodes.apiError].
class ApiException extends OmnyStoreException {
  /// The request URL that produced this failure.
  final Uri? url;

  /// The raw response body, when it was not a recognised error envelope.
  final String? body;

  /// Creates an API failure.
  const ApiException(
    super.message, {
    this.url,
    this.body,
    super.code = ErrorCodes.apiError,
    super.statusCode = 500,
  });
}

/// The CLI was invoked incorrectly, or a command could not complete.
///
/// Carries the process [exitCode] the CLI should terminate with — `64`
/// (`EX_USAGE`) for a usage error, `1` for a runtime failure.
class CliException extends OmnyStoreException {
  /// The process exit code to terminate with.
  final int exitCode;

  /// Creates a CLI failure with [message] and an [exitCode] (default `1`).
  const CliException(super.message, {this.exitCode = 1})
    : super(code: ErrorCodes.cliError, statusCode: 500);
}

/// An operation exceeded its deadline.
///
/// Named to avoid colliding with `dart:async`'s `TimeoutException`.
class OmnyStoreTimeoutException extends OmnyStoreException {
  /// Creates a timeout failure; defaults to a generic [message].
  const OmnyStoreTimeoutException([super.message = 'Operation timed out'])
    : super(code: ErrorCodes.timeout, statusCode: 504);
}

/// The configured backend does not support the requested operation — asking a
/// local-directory store for a presigned URL, for instance.
class UnsupportedOperationException extends OmnyStoreException {
  /// Creates an unsupported-operation failure with [message].
  const UnsupportedOperationException(super.message)
    : super(code: ErrorCodes.unsupported, statusCode: 501);
}

/// Reconstructs an [OmnyStoreException] from the `code`/`message` carried on a
/// JSON error envelope — the inverse of the mapping the API server uses to
/// render a thrown exception.
///
/// Used by [OmnyStoreClient] so a caller can classify a remote failure by type
/// (`on ReleaseNotFoundException`) instead of matching on a string. An
/// unrecognised [code] round-trips as an [ApiException] carrying it verbatim,
/// so a newer server's code never degrades into something meaningless.
OmnyStoreException omnyStoreExceptionForCode(
  String code,
  String message, {
  int statusCode = 500,
  Uri? url,
  Map<String, Object?> details = const {},
}) {
  String? detail(String key) => details[key]?.toString();
  // The not-found family reconstructs from the message's trailing reference,
  // which the constructors above always format as "...: <reference>".
  String reference() {
    final index = message.lastIndexOf(': ');
    return index < 0 ? message : message.substring(index + 2);
  }

  switch (code) {
    case ErrorCodes.validationError:
      return ValidationException(message);
    case ErrorCodes.invalidJson:
      return InvalidJsonException(message);
    case ErrorCodes.organizationNotFound:
      return OrganizationNotFoundException(reference());
    case ErrorCodes.projectNotFound:
      return ProjectNotFoundException(reference());
    case ErrorCodes.packageNotFound:
      return PackageNotFoundException(reference());
    case ErrorCodes.releaseNotFound:
      return ReleaseNotFoundException(reference());
    case ErrorCodes.assetNotFound:
      return AssetNotFoundException(reference());
    case ErrorCodes.conflict:
      return ConflictException(message, reference: reference());
    case ErrorCodes.unauthorized:
      return UnauthorizedException(message);
    case ErrorCodes.forbidden:
      return ForbiddenException(message);
    case ErrorCodes.storageError:
      return StorageException(message, key: detail('key'));
    case ErrorCodes.checksumMismatch:
      // Rebuilt from the structured details rather than by parsing the
      // message, so a caller can compare the digests as values.
      return ChecksumMismatchException(
        expected: detail('expected') ?? '',
        actual: detail('actual') ?? '',
        algorithm: detail('algorithm') ?? 'sha256',
      );
    case ErrorCodes.downloadFailed:
      return DownloadFailedException(
        message,
        url: url ?? Uri.tryParse(detail('url') ?? '') ?? Uri(),
        responseStatus: int.tryParse(detail('responseStatus') ?? ''),
      );
    case ErrorCodes.cliError:
      return CliException(message);
    case ErrorCodes.timeout:
      return OmnyStoreTimeoutException(message);
    case ErrorCodes.unsupported:
      return UnsupportedOperationException(message);
    default:
      return ApiException(
        message,
        url: url,
        code: code,
        statusCode: statusCode,
      );
  }
}
