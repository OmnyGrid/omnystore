import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../exceptions/omnystore_exception.dart';

/// SHA-256 helpers used wherever OmnyStore hands bytes across a trust boundary:
/// uploads into object storage, downloads onto a client's disk, and replication
/// between providers.
///
/// Everything here is streaming. An asset can be a multi-gigabyte installer, so
/// nothing in the pipeline may require the whole artifact in memory at once —
/// including the hash.
///
/// Web-safe: `dart:typed_data` and `package:crypto` only, no `dart:io`.
class Checksums {
  const Checksums._();

  /// The algorithm name recorded alongside every digest.
  static const String algorithm = 'sha256';

  /// The lower-case hex SHA-256 of [bytes].
  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// The lower-case hex SHA-256 of [text], UTF-8 encoded.
  static String sha256OfString(String text) => sha256Hex(utf8.encode(text));

  /// Whether [a] and [b] are the same digest, compared case-insensitively.
  ///
  /// Digests are public values, so this does not need to be constant-time; it
  /// exists to stop `'ABC…' != 'abc…'` from being reported as corruption when
  /// a backend returns upper-case hex.
  static bool matches(String a, String b) => a.toLowerCase() == b.toLowerCase();

  /// Throws [ChecksumMismatchException] unless [actual] matches [expected].
  static void require(String expected, String actual) {
    if (matches(expected, actual)) return;
    throw ChecksumMismatchException(
      expected: expected.toLowerCase(),
      actual: actual.toLowerCase(),
    );
  }
}

/// The size and digest of a byte stream, computed while it was being consumed.
class ChecksumResult {
  /// Total bytes seen.
  final int sizeBytes;

  /// Lower-case hex SHA-256 of those bytes.
  final String sha256;

  /// Creates a result.
  const ChecksumResult({required this.sizeBytes, required this.sha256});

  @override
  String toString() => 'ChecksumResult($sizeBytes bytes, sha256: $sha256)';
}

/// An incremental SHA-256 accumulator.
///
/// Feed it chunks as they pass by and read the digest once the stream ends —
/// the pattern every upload path uses, so the bytes are hashed on their way to
/// storage rather than in a second pass that would double the I/O.
///
/// ```dart
/// final digest = Sha256Accumulator();
/// await for (final chunk in source) {
///   digest.add(chunk);
///   await sink.add(chunk);
/// }
/// final result = digest.finish(); // size + hex digest
/// ```
class Sha256Accumulator {
  final _DigestCollector _collector = _DigestCollector();
  late final ByteConversionSink _sink = sha256.startChunkedConversion(
    _collector,
  );

  int _size = 0;
  ChecksumResult? _result;

  /// Creates an empty accumulator.
  Sha256Accumulator();

  /// Bytes accumulated so far.
  int get sizeBytes => _size;

  /// Whether [finish] has been called.
  bool get isFinished => _result != null;

  /// Adds [chunk] to the digest.
  ///
  /// Throws [StateError] after [finish] — a digest that kept accepting bytes
  /// after being read would silently produce a value describing neither the
  /// data it reported on nor the data it actually saw.
  void add(List<int> chunk) {
    if (_result != null) {
      throw StateError('Sha256Accumulator has already been finished');
    }
    if (chunk.isEmpty) return;
    _sink.add(chunk);
    _size += chunk.length;
  }

  /// Closes the digest and returns the size and hex hash. Idempotent.
  ChecksumResult finish() {
    final existing = _result;
    if (existing != null) return existing;
    _sink.close();
    return _result = ChecksumResult(
      sizeBytes: _size,
      sha256: _collector.digest.toString(),
    );
  }
}

/// A stream transformer that hashes and counts bytes as they flow through,
/// leaving the data itself untouched.
///
/// This is how an upload gets its checksum for free: wrap the source once and
/// the bytes are hashed on their way into storage. [onDone] fires with the
/// result when the stream completes normally; it does not fire if the stream
/// errors, because a digest over a truncated upload describes nothing useful.
///
/// ```dart
/// late ChecksumResult result;
/// final hashed = ChecksumStream.transform(source, (r) => result = r);
/// await storage.put(key, hashed);
/// // result is now populated
/// ```
class ChecksumStream {
  const ChecksumStream._();

  /// Returns [source] with every chunk hashed and counted on the way through,
  /// calling [onDone] with the digest when it completes.
  static Stream<List<int>> transform(
    Stream<List<int>> source,
    void Function(ChecksumResult result) onDone,
  ) {
    final accumulator = Sha256Accumulator();
    return source
        .map((chunk) {
          accumulator.add(chunk);
          return chunk;
        })
        .transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleDone: (sink) {
              onDone(accumulator.finish());
              sink.close();
            },
          ),
        );
  }

  /// Consumes [source] entirely and returns its size and digest, without
  /// retaining the bytes.
  ///
  /// Used to verify an already-stored object without downloading it into
  /// memory.
  static Future<ChecksumResult> of(Stream<List<int>> source) async {
    final accumulator = Sha256Accumulator();
    await for (final chunk in source) {
      accumulator.add(chunk);
    }
    return accumulator.finish();
  }

  /// Collects [source] into a single byte buffer while hashing it, returning
  /// both.
  ///
  /// For the download-to-memory path, where the caller wants the bytes *and*
  /// needs them verified before use.
  static Future<(Uint8List bytes, ChecksumResult checksum)> collect(
    Stream<List<int>> source,
  ) async {
    final accumulator = Sha256Accumulator();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source) {
      accumulator.add(chunk);
      builder.add(chunk);
    }
    return (builder.takeBytes(), accumulator.finish());
  }
}

/// Captures the single [Digest] a chunked SHA-256 conversion emits on close.
class _DigestCollector implements Sink<Digest> {
  Digest? _digest;

  /// The computed digest. Throws [StateError] if read before the conversion is
  /// closed.
  Digest get digest {
    final digest = _digest;
    if (digest == null) {
      throw StateError('Digest is not available until the sink is closed');
    }
    return digest;
  }

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
