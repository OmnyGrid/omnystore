import '../exceptions/omnystore_exception.dart';

/// Manual JSON read helpers for the hand-written decode paths that
/// `json_serializable` does not cover — API request bodies, error envelopes and
/// the free-form `metadata` maps.
///
/// Models themselves are generated (`*.g.dart`); these helpers exist so the
/// *boundaries* — where untrusted JSON arrives from a client or a storage
/// backend — fail with a typed [InvalidJsonException] carrying a useful
/// message, rather than a raw `TypeError` from a bad cast.
///
/// Web-safe: no `dart:io`, so the client SDK can use it too.
class Json {
  const Json._();

  /// Casts an arbitrary [value] to a `Map<String, dynamic>`.
  ///
  /// Throws [InvalidJsonException] if [value] is not a JSON object.
  static Map<String, dynamic> asObject(Object? value, [String what = 'value']) {
    if (value is Map) return value.cast<String, dynamic>();
    throw InvalidJsonException('Expected $what to be a JSON object');
  }

  /// Casts an arbitrary [value] to a `List<dynamic>`.
  ///
  /// Throws [InvalidJsonException] if [value] is not a JSON array.
  static List<dynamic> asList(Object? value, [String what = 'value']) {
    if (value is List) return value;
    throw InvalidJsonException('Expected $what to be a JSON array');
  }

  /// Reads a required string field [key] from [json].
  static String requireString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) return value;
    throw InvalidJsonException("Missing or invalid string field '$key'");
  }

  /// Reads an optional string field [key], returning [fallback] if absent.
  static String? optString(
    Map<String, dynamic> json,
    String key, [
    String? fallback,
  ]) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is String) return value;
    throw InvalidJsonException("Invalid string field '$key'");
  }

  /// Reads a required int field [key] from [json].
  ///
  /// Accepts a JSON number that happens to have decoded as a `double` with no
  /// fractional part — a size or count round-tripped through a JavaScript
  /// runtime arrives that way.
  static int requireInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is int) return value;
    if (value is double && value == value.roundToDouble()) return value.toInt();
    throw InvalidJsonException("Missing or invalid int field '$key'");
  }

  /// Reads an optional int field [key], returning [fallback] if absent.
  static int? optInt(Map<String, dynamic> json, String key, [int? fallback]) {
    if (json[key] == null) return fallback;
    return requireInt(json, key);
  }

  /// Reads an optional bool field [key], returning [fallback] if absent.
  static bool optBool(
    Map<String, dynamic> json,
    String key, {
    bool fallback = false,
  }) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is bool) return value;
    throw InvalidJsonException("Invalid bool field '$key'");
  }

  /// Reads a required ISO-8601 timestamp field [key] as a UTC [DateTime].
  static DateTime requireTimestamp(Map<String, dynamic> json, String key) {
    final parsed = DateTime.tryParse(requireString(json, key));
    if (parsed == null) {
      throw InvalidJsonException("Invalid timestamp field '$key'");
    }
    return parsed.toUtc();
  }

  /// Reads an optional ISO-8601 timestamp field [key].
  static DateTime? optTimestamp(Map<String, dynamic> json, String key) {
    final raw = optString(json, key);
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw InvalidJsonException("Invalid timestamp field '$key'");
    }
    return parsed.toUtc();
  }

  /// Reads an optional string→string map field [key], returning an empty map
  /// if absent. Used for the `metadata` fields carried by every model.
  static Map<String, String> optStringMap(
    Map<String, dynamic> json,
    String key,
  ) {
    final value = json[key];
    if (value == null) return const {};
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), '$v'));
    }
    throw InvalidJsonException("Invalid map field '$key'");
  }

  /// Reads an optional list of strings field [key], returning an empty list if
  /// absent.
  static List<String> optStringList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return const [];
    if (value is List) return value.map((e) => '$e').toList(growable: false);
    throw InvalidJsonException("Invalid list field '$key'");
  }
}
