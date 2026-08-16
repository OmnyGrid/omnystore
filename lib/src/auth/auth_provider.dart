import 'dart:async';

import 'package:meta/meta.dart';

/// Supplies the credentials a client attaches to each request.
///
/// Authentication is **optional in v1**: the default is
/// [AnonymousAuthProvider], and a registry with public reads works with no
/// credentials at all. The port exists now so that adding auth later — a
/// token, an OIDC flow, a signed request — is a constructor argument rather
/// than a change to every call site.
///
/// [headers] is called before every request rather than once, which is what
/// makes a refreshing token possible: an implementation can renew in the
/// background and hand back the current value.
///
/// ```dart
/// final client = OmnyStoreClient(
///   baseUrl: 'https://store.example.com',
///   auth: TokenAuthProvider('omny_pat_…'),
/// );
/// ```
abstract interface class AuthProvider {
  /// Headers to merge into the next request. Return `const {}` for none.
  FutureOr<Map<String, String>> headers();

  /// Called when the server answers `401`, so a provider backed by a
  /// short-lived token can refresh and let the client retry once.
  ///
  /// Return `true` if the credentials changed and a retry is worth attempting;
  /// `false` (the default for every bundled provider) means the failure is
  /// final and should surface to the caller. Retrying against an unchanged
  /// credential would just turn one clear `401` into two.
  FutureOr<bool> refresh() => false;

  /// Releases any resources held.
  FutureOr<void> close() {}
}

/// An [AuthProvider] that sends no credentials.
///
/// The default. A public registry serves reads, update checks and downloads to
/// anonymous callers, which is exactly what a software update endpoint needs.
@immutable
class AnonymousAuthProvider implements AuthProvider {
  /// Creates an anonymous provider.
  const AnonymousAuthProvider();

  @override
  Map<String, String> headers() => const {};

  @override
  bool refresh() => false;

  @override
  void close() {}
}

/// An [AuthProvider] sending a fixed bearer token.
///
/// Pairs with OmnyHub's `TokenAuthenticator` on the server, which is what the
/// bundled [OmnyStoreServer] accepts. Suitable for CI publishing credentials
/// and for machine-to-machine access.
@immutable
class TokenAuthProvider implements AuthProvider {
  /// The token value, sent as `Authorization: <scheme> <token>`.
  final String token;

  /// The authorization scheme. `Bearer` unless a deployment needs otherwise.
  final String scheme;

  /// Creates a token provider.
  const TokenAuthProvider(this.token, {this.scheme = 'Bearer'});

  @override
  Map<String, String> headers() => {'authorization': '$scheme $token'};

  @override
  bool refresh() => false;

  @override
  void close() {}

  @override
  String toString() => 'TokenAuthProvider($scheme ***)';
}

/// An [AuthProvider] that fetches a token on demand and refreshes it when the
/// server rejects it.
///
/// The building block for any short-lived credential — an OIDC access token, a
/// cloud workload identity, a session that expires. [fetchToken] is called on
/// the first request and again after a `401`, and its result is cached in
/// between, so a long-running updater does not re-authenticate per call.
class RefreshingAuthProvider implements AuthProvider {
  /// Obtains a fresh token.
  final Future<String> Function() fetchToken;

  /// The authorization scheme.
  final String scheme;

  String? _token;
  Future<String>? _inFlight;

  /// Creates a refreshing provider over [fetchToken].
  RefreshingAuthProvider(this.fetchToken, {this.scheme = 'Bearer'});

  @override
  Future<Map<String, String>> headers() async {
    final token = _token ??= await _fetchOnce();
    return {'authorization': '$scheme $token'};
  }

  @override
  Future<bool> refresh() async {
    _token = null;
    _token = await _fetchOnce();
    return true;
  }

  @override
  void close() {}

  /// Collapses concurrent fetches onto one in-flight call, so a burst of
  /// parallel requests does not become a burst of token exchanges.
  Future<String> _fetchOnce() =>
      _inFlight ??= fetchToken().whenComplete(() => _inFlight = null);
}

/// An [AuthProvider] that merges several providers' headers.
///
/// For a deployment that needs both a bearer token and, say, a tenant header
/// or an API-gateway key.
class CompositeAuthProvider implements AuthProvider {
  /// The providers to merge, later entries winning on a key collision.
  final List<AuthProvider> providers;

  /// Creates a composite over [providers].
  const CompositeAuthProvider(this.providers);

  @override
  Future<Map<String, String>> headers() async {
    final merged = <String, String>{};
    for (final provider in providers) {
      merged.addAll(await provider.headers());
    }
    return merged;
  }

  @override
  Future<bool> refresh() async {
    var refreshed = false;
    for (final provider in providers) {
      refreshed = await provider.refresh() || refreshed;
    }
    return refreshed;
  }

  @override
  Future<void> close() async {
    for (final provider in providers) {
      await provider.close();
    }
  }
}
