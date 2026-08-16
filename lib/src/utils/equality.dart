/// Structural equality helpers for the immutable models.
///
/// Every model carries collection fields (`metadata`, `labels`, `organizations`)
/// whose identity-based `==` would make two otherwise identical models compare
/// unequal — a round-trip through JSON would not equal its source, and tests
/// would have to compare field by field. These helpers give the models
/// value semantics instead.
class Eq {
  const Eq._();

  /// Whether [a] and [b] hold the same entries (order-insensitive).
  static bool maps<K, V>(Map<K, V> a, Map<K, V> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  /// Whether [a] and [b] hold the same elements in the same order.
  static bool lists<T>(List<T> a, List<T> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Whether [a] and [b] hold the same elements (order-insensitive).
  static bool sets<T>(Set<T> a, Set<T> b) =>
      identical(a, b) || (a.length == b.length && a.containsAll(b));

  /// An order-insensitive hash for a map, consistent with [maps].
  static int mapHash<K, V>(Map<K, V> map) => Object.hashAllUnordered(
    map.entries.map((e) => Object.hash(e.key, e.value)),
  );

  /// An order-sensitive hash for a list, consistent with [lists].
  static int listHash<T>(List<T> list) => Object.hashAll(list);

  /// An order-insensitive hash for a set, consistent with [sets].
  static int setHash<T>(Set<T> set) => Object.hashAllUnordered(set);
}
