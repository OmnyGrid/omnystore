/// Stable, machine-readable error codes carried by every [OmnyStoreException]
/// and rendered into the API's JSON error envelope.
///
/// Codes are part of the wire contract: a client keys retry/report decisions off
/// them rather than off human-readable messages, which are free to change. New
/// codes may be added; existing ones never change meaning.
library;

/// The error codes used by OmnyStore.
///
/// ```dart
/// try {
///   await client.latestRelease(packageName: 'omnyagent');
/// } on ApiException catch (e) {
///   if (e.code == ErrorCodes.releaseNotFound) return null;
///   rethrow;
/// }
/// ```
class ErrorCodes {
  const ErrorCodes._();

  /// A value failed validation (bad name, malformed version, negative size...).
  static const String validationError = 'validation_error';

  /// A payload could not be parsed as the expected JSON shape.
  static const String invalidJson = 'invalid_json';

  /// A resource does not exist and no more specific code applies.
  static const String notFound = 'not_found';

  /// The referenced organization does not exist.
  static const String organizationNotFound = 'organization_not_found';

  /// The referenced project does not exist.
  static const String projectNotFound = 'project_not_found';

  /// The referenced package does not exist.
  static const String packageNotFound = 'package_not_found';

  /// The referenced release does not exist.
  static const String releaseNotFound = 'release_not_found';

  /// The referenced asset does not exist.
  static const String assetNotFound = 'asset_not_found';

  /// A resource with the same unique key already exists.
  static const String conflict = 'conflict';

  /// The caller is not authenticated (missing or invalid credentials).
  static const String unauthorized = 'unauthorized';

  /// The caller is authenticated but not permitted to perform the operation.
  static const String forbidden = 'forbidden';

  /// A download could not be completed (transport failure, bad status...).
  static const String downloadFailed = 'download_failed';

  /// Downloaded bytes did not match the expected checksum.
  static const String checksumMismatch = 'checksum_mismatch';

  /// The object storage backend failed.
  static const String storageError = 'storage_error';

  /// The API returned a response the client could not interpret, or a status
  /// the client did not expect.
  static const String apiError = 'api_error';

  /// The CLI was invoked incorrectly or a command failed.
  static const String cliError = 'cli_error';

  /// An operation exceeded its deadline.
  static const String timeout = 'timeout';

  /// An operation is not supported by the configured backend.
  static const String unsupported = 'unsupported';
}
