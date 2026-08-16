/// Lower-case hexadecimal encoding.
///
/// Every digest and signature OmnyStore puts on a wire is hex: SHA-256 asset
/// checksums, AWS SigV4 signatures, Google V4 signatures. One implementation so
/// they cannot disagree on padding — a signature missing a leading zero is
/// rejected by the service with nothing more useful than
/// `SignatureDoesNotMatch`.
class Hex {
  const Hex._();

  /// Encodes [bytes] as lower-case hex, two characters per byte.
  static String encode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Decodes a hex string into bytes.
  ///
  /// Returns `null` for anything that is not an even-length run of hex digits,
  /// so a caller reading a digest out of untrusted metadata can treat a
  /// malformed value as absent rather than crashing.
  static List<int>? tryDecode(String value) {
    final text = value.trim();
    if (text.isEmpty || text.length.isOdd) return null;

    final bytes = <int>[];
    for (var i = 0; i < text.length; i += 2) {
      final byte = int.tryParse(text.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      bytes.add(byte);
    }
    return bytes;
  }
}
