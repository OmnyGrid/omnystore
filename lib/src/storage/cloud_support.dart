import 'package:http/http.dart' as http;

/// Behaviour the S3 and Google Cloud Storage backends share.
///
/// The two speak different protocols — XML against a bucket host, JSON against
/// an API host — but a handful of mechanics are identical: reading an object's
/// full size back out of a partial response, normalising a key prefix, and
/// trimming an error body down to something loggable. Kept in one place so the
/// two cannot drift into answering the same question differently, which is a
/// class of bug that only shows up against one provider.
class CloudStorageSupport {
  const CloudStorageSupport._();

  /// The object's *full* size, not the number of bytes this response carries.
  ///
  /// A `206` answers a range, so its `content-length` is the slice. The total
  /// lives in `content-range` as `bytes 0-9/1024`, and that is the number a
  /// caller needs to know how much of the object it has.
  static int totalSizeOf(http.StreamedResponse response) {
    final contentRange = response.headers['content-range'];
    if (contentRange != null) {
      final total = contentRange.split('/').lastOrNull;
      final parsed = total == null ? null : int.tryParse(total.trim());
      if (parsed != null) return parsed;
    }
    return response.contentLength ?? 0;
  }

  /// Normalises a key prefix to `some/prefix/`, or empty.
  ///
  /// Lets one bucket host several registries, and makes `registry`,
  /// `/registry` and `registry/` mean the same thing — a prefix given with a
  /// stray slash would otherwise silently write to a different place.
  static String normalizePrefix(String prefix) {
    final trimmed = trimSlashes(prefix);
    return trimmed.isEmpty ? '' : '$trimmed/';
  }

  /// Strips leading and trailing `/` from [value].
  static String trimSlashes(String value) {
    var result = value;
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  /// Truncates an error body to something safe to put in a log line.
  ///
  /// A failing bucket can answer with a large HTML page; embedding it whole in
  /// an exception message makes the real cause harder to find, not easier.
  static String truncateBody(String body, {int max = 200}) =>
      body.length > max ? '${body.substring(0, max)}…' : body;
}
