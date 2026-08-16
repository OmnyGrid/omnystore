/// Parsing for the `Last-Modified` and `Date` headers the object-storage
/// backends read.
///
/// Written here rather than pulled from `package:http_parser` so the storage
/// backends do not take a direct dependency on a transitive package for one
/// function — and so an unparsable header degrades to `null` instead of
/// throwing, which is what every caller wants: a missing modification time is
/// cosmetic, and must never fail a download.
class HttpDates {
  const HttpDates._();

  static const List<String> _months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  /// Parses an RFC 1123 HTTP date (`Wed, 21 Oct 2015 07:28:00 GMT`) into a UTC
  /// [DateTime], or returns `null` if [value] is absent or malformed.
  ///
  /// Also accepts RFC 850 (`Wednesday, 21-Oct-15 07:28:00 GMT`) and the ISO-8601
  /// form some S3-compatible services emit, because a backend that answers with
  /// a legal-but-unusual date should not look like a broken one.
  static DateTime? tryParse(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty) return null;

    // ISO-8601 first: it is unambiguous and cheap to detect.
    final iso = DateTime.tryParse(text);
    if (iso != null) return iso.toUtc();

    // "Wed, 21 Oct 2015 07:28:00 GMT" / "Wednesday, 21-Oct-15 07:28:00 GMT"
    final match = RegExp(
      r'^[A-Za-z]+,\s+(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4})\s+'
      r'(\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(text);
    if (match == null) return null;

    final day = int.tryParse(match.group(1)!);
    final month = _months.indexOf(match.group(2)!.toLowerCase()) + 1;
    var year = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    final second = int.tryParse(match.group(6)!);

    if (day == null ||
        month == 0 ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    // RFC 850's two-digit year, windowed as RFC 9110 prescribes.
    if (year < 100) year += year < 70 ? 2000 : 1900;

    return DateTime.utc(year, month, day, hour, minute, second);
  }

  /// Formats [value] as an RFC 1123 HTTP date.
  static String format(DateTime value) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final utc = value.toUtc();
    final day = days[utc.weekday - 1];
    final month = _months[utc.month - 1];
    final monthName = '${month[0].toUpperCase()}${month.substring(1)}';
    String two(int v) => v.toString().padLeft(2, '0');
    return '$day, ${two(utc.day)} $monthName ${utc.year} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
  }
}
