import 'dart:async';

import 'package:omnyhub/omnyhub.dart'
    show HubException, HubRequest, HubResponse, Logger;

import '../exceptions/error_codes.dart';
import '../exceptions/omnystore_exception.dart';

/// Renders OmnyStore's typed failures into the REST API's JSON error envelope.
///
/// ```json
/// {
///   "error": {
///     "code": "release_not_found",
///     "message": "Release not found: omnyagent@beta",
///     "details": { }
///   }
/// }
/// ```
///
/// The envelope matches OmnyHub's own (`{"error": {"code", "message"}}`) so a
/// client cannot tell whether a failure came from the framework or from the
/// registry, and adds `details` for the exceptions that carry structured
/// fields. `OmnyStoreClient` reads this back and rethrows the original
/// exception type, which is what makes `on ReleaseNotFoundException` work
/// across the network.
class ApiErrors {
  const ApiErrors._();

  /// The response for [error].
  static HubResponse render(OmnyStoreException error) => HubResponse.json({
    'error': {
      'code': error.code,
      'message': error.message,
      if (error.details.isNotEmpty) 'details': error.details,
    },
  }, statusCode: error.statusCode);

  /// The response for an unexpected [error].
  ///
  /// Deliberately opaque: an unhandled exception's message can carry a file
  /// path, a query, or a credential, and none of that belongs in a response to
  /// an anonymous caller. The detail goes to the log instead.
  static HubResponse renderUnexpected(
    Object error,
    StackTrace stackTrace, {
    required Logger logger,
    String? path,
  }) {
    logger.error(
      'Unhandled API error',
      context: {
        'error': '$error',
        'path': ?path,
        'stack': stackTrace.toString(),
      },
    );
    return HubResponse.json({
      'error': {
        'code': ErrorCodes.apiError,
        'message': 'Internal server error',
      },
    }, statusCode: 500);
  }

  /// Runs [handler], mapping every failure onto the error envelope.
  ///
  /// Wrapping each handler rather than relying on a middleware keeps the
  /// mapping inside the service, so the API renders identically whether it is
  /// mounted on its own OmnyHub or into an application's existing one with a
  /// different error mapper.
  static Future<HubResponse> guard(
    Future<HubResponse> Function() handler, {
    required Logger logger,
    HubRequest? request,
  }) async {
    try {
      return await handler();
    } on OmnyStoreException catch (e) {
      return render(e);
    } on HubException catch (e) {
      // A framework-level failure (bad JSON, unauthorized) already carries the
      // right code and status.
      return HubResponse.error(e);
    } on FormatException catch (e) {
      return render(
        InvalidJsonException('Malformed request body: ${e.message}'),
      );
    } on Object catch (e, stackTrace) {
      return renderUnexpected(
        e,
        stackTrace,
        logger: logger,
        path: request?.path,
      );
    }
  }
}
