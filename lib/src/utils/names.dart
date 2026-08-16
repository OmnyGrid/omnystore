import '../exceptions/omnystore_exception.dart';

/// Validation for the human-typed, URL-addressable names OmnyStore uses as
/// secondary keys: organization, project and package names.
///
/// A name appears in a URL path (`/api/v1/packages/omnyagent/releases`), in a
/// CLI argument, and — for assets — in an object-storage key. Constraining it
/// once, here, is what lets those three contexts share one string without
/// escaping rules that differ between them.
class Names {
  const Names._();

  /// The maximum length of a name.
  static const int maxLength = 100;

  /// Lower-case alphanumerics separated by single `-`, `_` or `.`, starting and
  /// ending with an alphanumeric.
  static final RegExp _pattern = RegExp(r'^[a-z0-9]+([._-][a-z0-9]+)*$');

  /// Whether [name] is a valid organization/project/package name.
  static bool isValid(String name) =>
      name.isNotEmpty && name.length <= maxLength && _pattern.hasMatch(name);

  /// Returns [name] if it is valid, otherwise throws [ValidationException]
  /// naming [field].
  ///
  /// ```dart
  /// Names.require('omny-agent', 'name'); // => 'omny-agent'
  /// Names.require('Omny Agent', 'name'); // throws ValidationException
  /// ```
  static String require(String name, String field) {
    if (isValid(name)) return name;
    throw ValidationException(
      "Invalid $field '$name': expected 1-$maxLength characters of lower-case "
      "letters, digits and single '.', '_' or '-' separators, starting and "
      'ending with a letter or digit',
      field: field,
    );
  }

  /// Lower-cases [input] and replaces runs of unsupported characters with `-`,
  /// producing a valid name, or throws [ValidationException] if nothing usable
  /// remains.
  ///
  /// Convenience for turning a display name into a name (`'Omny Agent'` →
  /// `'omny-agent'`); the canonical form is still validated by [require].
  static String slugify(String input, {String field = 'name'}) {
    final slug = input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '')
        .replaceAll(RegExp(r'[._-]{2,}'), '-');
    if (slug.isEmpty || slug.length > maxLength) {
      throw ValidationException(
        "Cannot derive a valid $field from '$input'",
        field: field,
      );
    }
    return require(slug, field);
  }

  /// Strips characters that would let [filename] break out of a quoted HTTP
  /// header value.
  ///
  /// An asset name reaches `content-disposition: attachment; filename="…"` in
  /// three places — the API's own download response and both cloud backends'
  /// presigned URLs. An unescaped `"` there lets the rest of the header be
  /// rewritten, and a control character can split it into two.
  ///
  /// The `\x00-\x1f` range already covers CR and LF, so newlines need no
  /// separate pass. [requireFilename] rejects these on the way *in*; this is
  /// the belt-and-braces pass on the way out, for names that predate the check
  /// or arrive from another registry.
  static String sanitizeForHeader(String filename) =>
      filename.replaceAll(RegExp(r'[\x00-\x1f\x7f"\\]'), '');

  /// Validates an asset filename: a single path segment, never `.` or `..`,
  /// with no path separators and no control characters.
  ///
  /// An asset name becomes the tail of a storage key and, for the
  /// local-directory backend, a real filesystem path — so a name containing
  /// `/`, `\` or `..` would let a publisher write outside the release's own
  /// prefix. This is the check that prevents it; `StorageKeys.requireSafe`
  /// re-checks the assembled key for the same reason.
  ///
  /// Spaces and other printable characters are allowed. `Acme Installer.dmg`
  /// is a legitimate artifact name, and every context the name reaches encodes
  /// or quotes it: the `?name=` query parameter, the quoted
  /// `content-disposition` filename, and S3's canonical URI.
  static String requireFilename(String name, [String field = 'asset name']) {
    final invalid =
        name.isEmpty ||
        name.length > 255 ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        // C0 controls and DEL: a newline here could split a response header,
        // and a NUL could truncate a path in a native call downstream.
        name.codeUnits.any((c) => c < 0x20 || c == 0x7f);
    if (invalid) {
      throw ValidationException(
        "Invalid $field '$name': expected a single filename of at most 255 "
        r"characters with no '/', '\' or control characters",
        field: field,
      );
    }
    return name;
  }
}
