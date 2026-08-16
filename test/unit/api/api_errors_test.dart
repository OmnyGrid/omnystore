import 'dart:convert';

import 'package:omnystore/omnystore_hub.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

void main() {
  late RecordingLogger logger;

  setUp(() => logger = RecordingLogger());

  Future<Map<String, dynamic>> bodyOf(HubResponse response) async =>
      jsonDecode(await response.readAsString()) as Map<String, dynamic>;

  group('render', () {
    test('carries the code, message and status of a typed failure', () async {
      final response = ApiErrors.render(ReleaseNotFoundException('a@1.0.0'));

      expect(response.statusCode, 404);
      final body = await bodyOf(response);
      expect(body['error']['code'], ErrorCodes.releaseNotFound);
      expect(body['error']['message'], contains('a@1.0.0'));
    });

    test('includes structured details when the failure has them', () async {
      final response = ApiErrors.render(
        ChecksumMismatchException(expected: 'aaaa', actual: 'bbbb'),
      );

      expect(response.statusCode, 422);
      final details = (await bodyOf(response))['error']['details'] as Map;
      // A client comparing digests needs them as values, not as substrings of
      // a sentence.
      expect(details['expected'], 'aaaa');
      expect(details['actual'], 'bbbb');
      expect(details['algorithm'], 'sha256');
    });

    test('omits details when there are none', () async {
      final response = ApiErrors.render(const ValidationException('bad'));

      expect((await bodyOf(response))['error'].containsKey('details'), isFalse);
    });
  });

  group('renderUnexpected', () {
    test('answers an opaque 500 and logs the detail', () async {
      final response = ApiErrors.renderUnexpected(
        StateError('database password is hunter2'),
        StackTrace.current,
        logger: logger,
        path: '/api/v1/organizations',
      );

      expect(response.statusCode, 500);
      final body = await bodyOf(response);
      expect(body['error']['code'], ErrorCodes.apiError);
      expect(body['error']['message'], 'Internal server error');
      // An unhandled exception's message can carry a path, a query or a
      // credential; none of it belongs in a response to an anonymous caller.
      expect(
        await bodyOf(ApiErrors.render(const ValidationException('x'))),
        isNotNull,
      );
      expect(body.toString(), isNot(contains('hunter2')));

      // The detail goes to the log instead, where an operator can see it.
      final logged = logger.records.single;
      expect(logged.level, LogLevel.error);
      expect(logged.context['error'], contains('hunter2'));
      expect(logged.context['path'], '/api/v1/organizations');
      expect(logged.context['stack'], isNotNull);
    });
  });

  group('guard', () {
    test('passes a successful response through', () async {
      final response = await ApiErrors.guard(
        () async => HubResponse.json({'ok': true}),
        logger: logger,
      );

      expect(response.statusCode, 200);
      expect(logger.records, isEmpty);
    });

    test('renders a typed failure', () async {
      final response = await ApiErrors.guard(
        () async => throw PackageNotFoundException('ghost'),
        logger: logger,
      );

      expect(response.statusCode, 404);
      expect(
        (await bodyOf(response))['error']['code'],
        ErrorCodes.packageNotFound,
      );
    });

    test('renders a framework failure with its own code', () async {
      final response = await ApiErrors.guard(
        () async => throw const UnauthorizedException('nope'),
        logger: logger,
      );

      expect(response.statusCode, 401);
    });

    test('turns malformed JSON into a 400, not a 500', () async {
      final response = await ApiErrors.guard(
        () async => throw const FormatException('Unexpected character'),
        logger: logger,
      );

      expect(response.statusCode, 400);
      expect((await bodyOf(response))['error']['code'], ErrorCodes.invalidJson);
      // A malformed body is the caller's mistake, so it is not logged as a
      // server error.
      expect(logger.records, isEmpty);
    });

    test('contains an unexpected failure as an opaque 500', () async {
      final response = await ApiErrors.guard(
        () async => throw StateError('boom'),
        logger: logger,
      );

      expect(response.statusCode, 500);
      expect(logger.messagesAt(LogLevel.error), ['Unhandled API error']);
    });
  });

  group('the server renders an unexpected failure the same way', () {
    test('a store that throws yields an opaque 500', () async {
      final backing = TestStore();
      final server = OmnyStoreServer(
        store: _ExplodingStore(backing.store),
        logger: logger,
      );
      await server.start(port: 0, address: '127.0.0.1');
      final client = OmnyStoreClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(() async {
        await client.close();
        await server.stop();
        await backing.close();
      });

      await expectLater(
        client.listOrganizations(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 500)
              .having((e) => e.message, 'message', 'Internal server error'),
        ),
      );
      expect(
        logger.messagesAt(LogLevel.error),
        contains('Unhandled API error'),
      );
    });
  });
}

/// A store whose listing blows up with something the API never anticipated.
///
/// Only the two members this test exercises are implemented; `noSuchMethod`
/// covers the rest of [OmnyStoreApi] and throws, so a future test that reaches
/// for another method fails loudly rather than silently returning null.
class _ExplodingStore implements OmnyStoreApi {
  final OmnyStoreApi inner;

  _ExplodingStore(this.inner);

  @override
  Future<List<Organization>> listOrganizations() async =>
      throw StateError('the disk caught fire');

  @override
  Future<void> close() => inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not implemented by this test double',
  );
}
