import 'dart:convert';

/// Strict RFC 3986 percent-encoding, and the canonical query string both
/// supported cloud signing schemes build from it.
///
/// AWS Signature V4 and Google's V4 URL signing specify the same construction
/// here, and both are unforgiving: a single character encoded differently from
/// what the service expects produces a signature mismatch and a `403` whose
/// message says nothing about which character was wrong. Keeping one
/// implementation means a fix found while debugging one backend cannot leave
/// the other subtly wrong.
///
/// Dart's [Uri.encodeComponent] is not a substitute: it leaves `!`, `*`, `'`,
/// `(` and `)` unescaped, and both schemes require them escaped.
class Rfc3986 {
  const Rfc3986._();

  /// The characters neither scheme escapes.
  static const String _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      'abcdefghijklmnopqrstuvwxyz'
      '0123456789-._~';

  /// Percent-encodes [value], escaping everything outside the unreserved set —
  /// including `/`.
  ///
  /// ```dart
  /// Rfc3986.encodeComponent('a b/c'); // => 'a%20b%2Fc'
  /// ```
  static String encodeComponent(String value) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final char = String.fromCharCode(byte);
      if (_unreserved.contains(char)) {
        buffer.write(char);
      } else {
        buffer.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
    return buffer.toString();
  }

  /// Percent-encodes each segment of [path], leaving `/` as a separator.
  static String encodePath(String path) =>
      path.split('/').map(encodeComponent).join('/');

  /// The canonical query string: every name and value encoded, sorted by
  /// encoded name and then encoded value, joined as `name=value` pairs.
  ///
  /// The sort is over the *encoded* forms, not the raw ones — the two orders
  /// differ whenever a name contains a character that encodes above `z`.
  static String canonicalQuery(Map<String, String> parameters) {
    if (parameters.isEmpty) return '';
    final encoded =
        parameters.entries
            .map(
              (e) => MapEntry(encodeComponent(e.key), encodeComponent(e.value)),
            )
            .toList()
          ..sort((a, b) {
            final byKey = a.key.compareTo(b.key);
            return byKey != 0 ? byKey : a.value.compareTo(b.value);
          });
    return encoded.map((e) => '${e.key}=${e.value}').join('&');
  }
}
