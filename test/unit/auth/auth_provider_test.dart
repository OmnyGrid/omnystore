import 'package:omnystore/omnystore_client.dart';
import 'package:test/test.dart';

void main() {
  group('AnonymousAuthProvider', () {
    test('sends nothing, and never asks for a retry', () async {
      // Typed as the interface: that is how a client holds it, and the
      // interface is where the FutureOr contract lives.
      const AuthProvider provider = AnonymousAuthProvider();

      expect(await provider.headers(), isEmpty);
      // A public registry serves reads to anonymous callers; there is no
      // credential to refresh, so a 401 is final.
      expect(await provider.refresh(), isFalse);
      await provider.close();
    });
  });

  group('TokenAuthProvider', () {
    test('sends a bearer token', () async {
      const AuthProvider provider = TokenAuthProvider('omny_pat_abc');

      expect(await provider.headers(), {
        'authorization': 'Bearer omny_pat_abc',
      });
    });

    test('honours a custom scheme', () async {
      const AuthProvider provider = TokenAuthProvider('abc', scheme: 'Token');

      expect(await provider.headers(), {'authorization': 'Token abc'});
    });

    test('does not ask for a retry, since the token cannot change', () async {
      // Retrying against an unchanged credential turns one clear 401 into two.
      const AuthProvider provider = TokenAuthProvider('abc');
      expect(await provider.refresh(), isFalse);
    });

    test('keeps the token out of toString', () async {
      // It ends up in logs and crash reports otherwise.
      expect(
        const TokenAuthProvider('super-secret').toString(),
        isNot(contains('super-secret')),
      );
      expect(
        const TokenAuthProvider('super-secret').toString(),
        contains('***'),
      );
    });
  });

  group('RefreshingAuthProvider', () {
    test('fetches once and caches', () async {
      var fetches = 0;
      final provider = RefreshingAuthProvider(() async {
        fetches++;
        return 'token-$fetches';
      });

      expect(await provider.headers(), {'authorization': 'Bearer token-1'});
      expect(await provider.headers(), {'authorization': 'Bearer token-1'});
      expect(fetches, 1);
    });

    test('refresh replaces the token and asks for a retry', () async {
      var fetches = 0;
      final provider = RefreshingAuthProvider(() async => 'token-${++fetches}');

      await provider.headers();
      expect(await provider.refresh(), isTrue);
      expect(await provider.headers(), {'authorization': 'Bearer token-2'});
    });

    test('collapses concurrent fetches onto one call', () async {
      var fetches = 0;
      final provider = RefreshingAuthProvider(() async {
        fetches++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'token';
      });

      // A burst of parallel requests must not become a burst of token
      // exchanges against the identity provider.
      await Future.wait([
        provider.headers(),
        provider.headers(),
        provider.headers(),
      ]);

      expect(fetches, 1);
    });

    test('honours a custom scheme', () async {
      final provider = RefreshingAuthProvider(
        () async => 'abc',
        scheme: 'Token',
      );

      expect(await provider.headers(), {'authorization': 'Token abc'});
      provider.close();
    });
  });

  group('CompositeAuthProvider', () {
    test('merges headers, later providers winning a collision', () async {
      const provider = CompositeAuthProvider([
        TokenAuthProvider('first'),
        _TenantHeaderProvider('acme'),
      ]);

      expect(await provider.headers(), {
        'authorization': 'Bearer first',
        'x-tenant': 'acme',
      });
    });

    test('asks for a retry if any member could refresh', () async {
      final refreshing = RefreshingAuthProvider(() async => 'abc');
      final provider = CompositeAuthProvider([
        const TokenAuthProvider('fixed'),
        refreshing,
      ]);

      expect(await provider.refresh(), isTrue);
    });

    test('reports no retry when no member can refresh', () async {
      const provider = CompositeAuthProvider([
        TokenAuthProvider('a'),
        TokenAuthProvider('b'),
      ]);

      expect(await provider.refresh(), isFalse);
    });

    test('closes every member', () async {
      final closed = <String>[];
      final provider = CompositeAuthProvider([
        _RecordingProvider('a', closed),
        _RecordingProvider('b', closed),
      ]);

      await provider.close();
      expect(closed, ['a', 'b']);
    });
  });
}

/// A provider contributing a non-authorization header, for the composite test.
class _TenantHeaderProvider implements AuthProvider {
  final String tenant;

  const _TenantHeaderProvider(this.tenant);

  @override
  Map<String, String> headers() => {'x-tenant': tenant};

  @override
  bool refresh() => false;

  @override
  void close() {}
}

/// A provider that records that it was closed.
class _RecordingProvider implements AuthProvider {
  final String name;
  final List<String> closed;

  _RecordingProvider(this.name, this.closed);

  @override
  Map<String, String> headers() => const {};

  @override
  bool refresh() => false;

  @override
  void close() => closed.add(name);
}
