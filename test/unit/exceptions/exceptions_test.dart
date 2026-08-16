import 'package:omnystore/omnystore.dart';
import 'package:test/test.dart';

void main() {
  group('the hierarchy', () {
    test('carries a stable code and an HTTP status', () {
      final cases = <OmnyStoreException, (String, int)>{
        const ValidationException('bad'): (ErrorCodes.validationError, 400),
        const InvalidJsonException('bad'): (ErrorCodes.invalidJson, 400),
        OrganizationNotFoundException('x'): (
          ErrorCodes.organizationNotFound,
          404,
        ),
        ProjectNotFoundException('x'): (ErrorCodes.projectNotFound, 404),
        PackageNotFoundException('x'): (ErrorCodes.packageNotFound, 404),
        ReleaseNotFoundException('x'): (ErrorCodes.releaseNotFound, 404),
        AssetNotFoundException('x'): (ErrorCodes.assetNotFound, 404),
        const ConflictException('taken', reference: 'x'): (
          ErrorCodes.conflict,
          409,
        ),
        const UnauthorizedException(): (ErrorCodes.unauthorized, 401),
        const ForbiddenException(): (ErrorCodes.forbidden, 403),
        const StorageException('boom'): (ErrorCodes.storageError, 500),
        const OmnyStoreTimeoutException(): (ErrorCodes.timeout, 504),
        const UnsupportedOperationException('nope'): (
          ErrorCodes.unsupported,
          501,
        ),
        const CliException('bad usage'): (ErrorCodes.cliError, 500),
      };

      cases.forEach((exception, expected) {
        expect(exception.code, expected.$1, reason: '$exception');
        expect(exception.statusCode, expected.$2, reason: '$exception');
        expect(exception.message, isNotEmpty);
      });
    });

    test('supports exhaustive pattern matching', () {
      // The hierarchy is sealed so a caller can switch over it without a
      // catch-all that silently swallows a new failure type.
      String describe(OmnyStoreException error) => switch (error) {
        ReleaseNotFoundException e => 'no release ${e.reference}',
        ChecksumMismatchException e => 'corrupt: ${e.expected}',
        NotFoundException e => 'missing ${e.reference}',
        OmnyStoreException e => e.message,
      };

      expect(
        describe(ReleaseNotFoundException('a@1.0.0')),
        'no release a@1.0.0',
      );
      expect(describe(AssetNotFoundException('asset-1')), 'missing asset-1');
      expect(describe(const ValidationException('bad')), 'bad');
    });

    test('names the reference in a not-found message', () {
      expect(
        PackageNotFoundException('omnyagent').message,
        'Package not found: omnyagent',
      );
      expect(
        ReleaseNotFoundException('omnyagent@beta').reference,
        'omnyagent@beta',
      );
    });

    test('a checksum mismatch says what was expected and what arrived', () {
      final mismatch = ChecksumMismatchException(
        expected: 'aaaa',
        actual: 'bbbb',
      );

      expect(mismatch.message, contains('expected aaaa'));
      expect(mismatch.message, contains('got bbbb'));
      expect(mismatch.message, contains('discarded'));
      expect(mismatch.details, {
        'expected': 'aaaa',
        'actual': 'bbbb',
        'algorithm': 'sha256',
      });
    });

    test('a download failure carries its URL and status', () {
      final failure = DownloadFailedException(
        'server said no',
        url: Uri.parse('https://example.com/a.tar.gz'),
        responseStatus: 503,
      );

      expect(failure.details['url'], 'https://example.com/a.tar.gz');
      expect(failure.details['responseStatus'], 503);
    });

    test('a CLI failure carries its exit code', () {
      expect(const CliException('bad usage', exitCode: 64).exitCode, 64);
      expect(const CliException('failed').exitCode, 1);
    });

    test('toString names the type and the code', () {
      expect(
        PackageNotFoundException('x').toString(),
        'PackageNotFoundException(package_not_found): Package not found: x',
      );
    });
  });

  group('omnyStoreExceptionForCode', () {
    test('reconstructs each type from its code', () {
      final reconstructed = <String, Matcher>{
        ErrorCodes.validationError: isA<ValidationException>(),
        ErrorCodes.invalidJson: isA<InvalidJsonException>(),
        ErrorCodes.organizationNotFound: isA<OrganizationNotFoundException>(),
        ErrorCodes.projectNotFound: isA<ProjectNotFoundException>(),
        ErrorCodes.packageNotFound: isA<PackageNotFoundException>(),
        ErrorCodes.releaseNotFound: isA<ReleaseNotFoundException>(),
        ErrorCodes.assetNotFound: isA<AssetNotFoundException>(),
        ErrorCodes.conflict: isA<ConflictException>(),
        ErrorCodes.unauthorized: isA<UnauthorizedException>(),
        ErrorCodes.forbidden: isA<ForbiddenException>(),
        ErrorCodes.storageError: isA<StorageException>(),
        ErrorCodes.checksumMismatch: isA<ChecksumMismatchException>(),
        ErrorCodes.downloadFailed: isA<DownloadFailedException>(),
        ErrorCodes.cliError: isA<CliException>(),
        ErrorCodes.timeout: isA<OmnyStoreTimeoutException>(),
        ErrorCodes.unsupported: isA<UnsupportedOperationException>(),
      };

      reconstructed.forEach((code, matcher) {
        expect(
          omnyStoreExceptionForCode(code, 'message: reference'),
          matcher,
          reason: code,
        );
      });
    });

    test('recovers the reference from a not-found message', () {
      final error = omnyStoreExceptionForCode(
        ErrorCodes.releaseNotFound,
        'Release not found: omnyagent@beta',
      );

      expect((error as ReleaseNotFoundException).reference, 'omnyagent@beta');
    });

    test('rebuilds a checksum mismatch from its structured details', () {
      // Reconstructing from the message alone would give the caller strings to
      // parse rather than the digests as values.
      final error =
          omnyStoreExceptionForCode(
                ErrorCodes.checksumMismatch,
                'whatever the message says',
                details: const {
                  'expected': 'aaaa',
                  'actual': 'bbbb',
                  'algorithm': 'sha256',
                },
              )
              as ChecksumMismatchException;

      expect(error.expected, 'aaaa');
      expect(error.actual, 'bbbb');
    });

    test('round-trips an unknown code without losing it', () {
      // A newer server's code must never degrade into something meaningless.
      final error =
          omnyStoreExceptionForCode(
                'quota_exceeded',
                'Monthly quota exceeded',
                statusCode: 429,
              )
              as ApiException;

      expect(error.code, 'quota_exceeded');
      expect(error.statusCode, 429);
      expect(error.message, 'Monthly quota exceeded');
    });

    test('every code in ErrorCodes maps to an OmnyStoreException', () {
      // Guards against a code being added without a mapping, which would make
      // that failure arrive at a client as an opaque ApiException.
      for (final code in [
        ErrorCodes.validationError,
        ErrorCodes.invalidJson,
        ErrorCodes.notFound,
        ErrorCodes.organizationNotFound,
        ErrorCodes.projectNotFound,
        ErrorCodes.packageNotFound,
        ErrorCodes.releaseNotFound,
        ErrorCodes.assetNotFound,
        ErrorCodes.conflict,
        ErrorCodes.unauthorized,
        ErrorCodes.forbidden,
        ErrorCodes.downloadFailed,
        ErrorCodes.checksumMismatch,
        ErrorCodes.storageError,
        ErrorCodes.apiError,
        ErrorCodes.cliError,
        ErrorCodes.timeout,
        ErrorCodes.unsupported,
      ]) {
        expect(
          omnyStoreExceptionForCode(code, 'x: y'),
          isA<OmnyStoreException>(),
          reason: code,
        );
      }
    });
  });
}
