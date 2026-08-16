import 'package:omnyhub/omnyhub.dart' show IdGenerator;

/// An [IdGenerator] that stamps a scope into every identifier it produces.
///
/// **Entity ids have to be unique across a whole federation, not just within
/// one store.** A hub caches "which provider owns which id" and deduplicates
/// aggregated listings by id; two nodes independently minting the same id would
/// make one entity shadow the other, and route writes to the wrong machine.
/// Independent processes cannot coordinate a counter, so the scope — normally
/// the provider id — is what keeps them apart.
///
/// ```dart
/// ScopedIdGenerator(RandomIdGenerator(), 'node-eu').next('rel');
/// // => 'rel-node-eu-1k3f9x'
/// ```
///
/// The scope is also a diagnostic: an id in a log or a URL says which node
/// created the record, which is the first thing you want to know when a
/// federated deployment misbehaves.
class ScopedIdGenerator implements IdGenerator {
  /// The generator supplying the unique part of each id.
  final IdGenerator inner;

  /// The scope stamped into every id, normalised to lower-case alphanumerics
  /// and `-`.
  final String scope;

  /// Wraps [inner], stamping [scope] into every id.
  ScopedIdGenerator(this.inner, String scope) : scope = _normalize(scope);

  @override
  String next([String prefix = '']) {
    // The inner generator is asked for an unprefixed body so the scope always
    // lands in the same position, whatever the inner implementation does with
    // its own prefix argument.
    final body = inner.next();
    if (scope.isEmpty) return prefix.isEmpty ? body : '$prefix-$body';
    return prefix.isEmpty ? '$scope-$body' : '$prefix-$scope-$body';
  }

  /// Reduces [scope] to characters that are safe in an id, a URL path segment
  /// and a storage key.
  static String _normalize(String scope) => scope
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
