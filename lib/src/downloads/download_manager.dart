import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../exceptions/omnystore_exception.dart';
import '../models/asset.dart';
import '../storage/object_storage.dart';
import '../utils/checksum.dart';
import '../version.dart';

/// Progress of an in-flight download.
class DownloadProgress {
  /// Bytes received so far, including any resumed from a previous attempt.
  final int received;

  /// Total bytes expected, or `null` when the server did not say.
  final int? total;

  /// Bytes that were already on disk when the download resumed.
  final int resumedFrom;

  /// Creates a progress snapshot.
  const DownloadProgress({
    required this.received,
    this.total,
    this.resumedFrom = 0,
  });

  /// Completion in `0.0`–`1.0`, or `null` when [total] is unknown.
  double? get fraction {
    final expected = total;
    if (expected == null || expected <= 0) return null;
    return (received / expected).clamp(0.0, 1.0);
  }

  /// Completion as a whole percentage, or `null` when [total] is unknown.
  int? get percent {
    final value = fraction;
    return value == null ? null : (value * 100).round();
  }

  @override
  String toString() =>
      'DownloadProgress($received/${total ?? '?'} bytes'
      '${percent == null ? '' : ', $percent%'})';
}

/// The outcome of a completed download.
class DownloadResult {
  /// Where the bytes were written, or `null` for an in-memory download.
  final File? file;

  /// The bytes, for an in-memory download.
  final Uint8List? bytes;

  /// Total bytes now present.
  final int sizeBytes;

  /// The SHA-256 of the complete artifact, lower-case hex.
  final String sha256;

  /// Whether the download resumed a partial file rather than starting fresh.
  final bool resumed;

  /// Whether the file was already complete and verified, so nothing was
  /// transferred.
  final bool wasCached;

  /// Creates a result.
  const DownloadResult({
    this.file,
    this.bytes,
    required this.sizeBytes,
    required this.sha256,
    this.resumed = false,
    this.wasCached = false,
  });

  @override
  String toString() =>
      'DownloadResult($sizeBytes bytes'
      '${wasCached
          ? ', cached'
          : resumed
          ? ', resumed'
          : ''})';
}

/// Downloads artifacts to disk or into memory, with resume and mandatory
/// checksum verification.
///
/// ```dart
/// final manager = DownloadManager();
/// final result = await manager.downloadToFile(
///   url: Uri.parse(downloadUrl),
///   destination: '/tmp/omnyagent-linux-x64.tar.gz',
///   expectedSha256: asset.sha256,
///   onProgress: (p) => stdout.write('\r${p.percent}%'),
/// );
/// ```
///
/// **Verification is not optional.** When a checksum is supplied and does not
/// match, the partial file is **deleted** and [ChecksumMismatchException] is
/// thrown. An update mechanism that hands an installer unverified bytes is a
/// malware delivery channel for anyone who can interpose on the network or
/// write to the artifact store, so there is no flag to skip it — a caller that
/// genuinely has no checksum simply passes none, and knows it got no guarantee.
///
/// **Resume is real.** [downloadToFile] sends a `Range` header for whatever is
/// already on disk and appends; a 4 GB installer interrupted at 90% costs 400 MB
/// to finish, not 4 GB. A server that ignores the range (answering `200`
/// instead of `206`) is handled by restarting from zero rather than corrupting
/// the file by appending a full body to a partial one.
///
/// Uses `dart:io`, so it is available on the Dart VM and Flutter but not on the
/// web. Browser callers use `OmnyStoreClient.downloadAsset`, which returns
/// verified bytes.
class DownloadManager {
  /// How long to wait for the response to begin.
  final Duration timeout;

  /// The `user-agent` sent with each request.
  final String userAgent;

  /// How many times to retry a failed transfer before giving up.
  ///
  /// Retries resume from what is already on disk, so a flaky connection costs
  /// the remaining bytes rather than the whole artifact.
  final int maxRetries;

  /// How long to wait before the first retry; doubled for each subsequent one.
  final Duration retryDelay;

  final http.Client _http;
  final bool _ownsClient;

  /// Creates a download manager.
  DownloadManager({
    this.timeout = const Duration(seconds: 60),
    String? userAgent,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
    http.Client? httpClient,
  }) : userAgent = userAgent ?? 'omnystore/$omnyStoreVersion',
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Downloads [url] into memory, verifying [expectedSha256] when given.
  ///
  /// For artifacts small enough to hold — a manifest, a signature, a patch.
  /// Use [downloadToFile] for installers.
  Future<DownloadResult> downloadToMemory({
    required Uri url,
    String? expectedSha256,
    Map<String, String> headers = const {},
    void Function(DownloadProgress progress)? onProgress,
    int? maxBytes,
  }) async {
    final response = await _open(url, headers: headers);
    final total = response.contentLength;

    if (maxBytes != null && total != null && total > maxBytes) {
      await response.stream.drain<void>();
      throw DownloadFailedException(
        'Response is $total bytes, above the $maxBytes-byte limit for an '
        'in-memory download',
        url: url,
      );
    }

    final builder = BytesBuilder(copy: false);
    final digest = Sha256Accumulator();
    var received = 0;

    await for (final chunk in response.stream) {
      received += chunk.length;
      if (maxBytes != null && received > maxBytes) {
        throw DownloadFailedException(
          'Response exceeded the $maxBytes-byte limit for an in-memory '
          'download',
          url: url,
        );
      }
      digest.add(chunk);
      builder.add(chunk);
      onProgress?.call(DownloadProgress(received: received, total: total));
    }

    final checksum = digest.finish();
    if (expectedSha256 != null) {
      Checksums.require(expectedSha256, checksum.sha256);
    }

    return DownloadResult(
      bytes: builder.takeBytes(),
      sizeBytes: checksum.sizeBytes,
      sha256: checksum.sha256,
    );
  }

  /// Downloads [url] to [destination], resuming a partial file when one is
  /// there.
  ///
  /// If [destination] already holds a complete, checksum-matching artifact,
  /// nothing is transferred and the result reports [DownloadResult.wasCached] —
  /// which is what makes it safe to call this on every application start.
  ///
  /// Set [resume] `false` to always start over.
  Future<DownloadResult> downloadToFile({
    required Uri url,
    required String destination,
    String? expectedSha256,
    int? expectedSize,
    Map<String, String> headers = const {},
    void Function(DownloadProgress progress)? onProgress,
    bool resume = true,
  }) async {
    final file = File(p.normalize(p.absolute(destination)));
    await file.parent.create(recursive: true);

    if (await _isAlreadyComplete(file, expectedSha256, expectedSize)) {
      final checksum = await ChecksumStream.of(file.openRead());
      return DownloadResult(
        file: file,
        sizeBytes: checksum.sizeBytes,
        sha256: checksum.sha256,
        wasCached: true,
      );
    }

    var attempt = 0;
    var delay = retryDelay;
    while (true) {
      attempt++;
      try {
        return await _transfer(
          url: url,
          file: file,
          expectedSha256: expectedSha256,
          headers: headers,
          onProgress: onProgress,
          resume: resume,
        );
      } on ChecksumMismatchException {
        // The bytes are wrong, not missing. Retrying would very likely fetch
        // the same wrong bytes; `_transfer` has already deleted them.
        rethrow;
      } on OmnyStoreException {
        if (attempt > maxRetries) rethrow;
        await Future<void>.delayed(delay);
        delay *= 2;
      }
    }
  }

  /// Resumes a partial download of [url] at [destination].
  ///
  /// Identical to [downloadToFile] with `resume: true`; named separately
  /// because "resume this" is what the caller means, and spelling it as a flag
  /// on a method called "download" reads like it might start over.
  Future<DownloadResult> resumeDownload({
    required Uri url,
    required String destination,
    String? expectedSha256,
    int? expectedSize,
    Map<String, String> headers = const {},
    void Function(DownloadProgress progress)? onProgress,
  }) => downloadToFile(
    url: url,
    destination: destination,
    expectedSha256: expectedSha256,
    expectedSize: expectedSize,
    headers: headers,
    onProgress: onProgress,
  );

  /// Downloads [asset] from [url] to [destination], verifying it against the
  /// asset's own recorded checksum and size.
  ///
  /// The call an updater should make: the expectations come from the registry
  /// record rather than from the caller, so there is no way to forget them.
  ///
  /// [destination] may be a directory — the artifact is then saved under
  /// [Asset.name] inside it — or the exact file path to write.
  Future<DownloadResult> downloadAsset({
    required Asset asset,
    required Uri url,
    required String destination,
    Map<String, String> headers = const {},
    void Function(DownloadProgress progress)? onProgress,
    bool resume = true,
  }) async => downloadToFile(
    url: url,
    destination: await Directory(destination).exists()
        ? p.join(destination, asset.name)
        : destination,
    expectedSha256: asset.sha256.isEmpty ? null : asset.sha256,
    expectedSize: asset.sizeBytes,
    headers: headers,
    onProgress: onProgress,
    resume: resume,
  );

  /// The SHA-256 of the file at [path], computed by streaming it.
  Future<String> checksumOf(String path) async =>
      (await ChecksumStream.of(File(path).openRead())).sha256;

  /// Whether the file at [path] matches [expectedSha256].
  ///
  /// Returns `false` for a missing file rather than throwing: "is this the
  /// artifact I want?" has the same answer whether it is wrong or absent.
  Future<bool> verifyChecksum(String path, String expectedSha256) async {
    final file = File(path);
    if (!await file.exists()) return false;
    return Checksums.matches(expectedSha256, await checksumOf(path));
  }

  /// Verifies [path] against [expectedSha256], throwing
  /// [ChecksumMismatchException] if it does not match and deleting the file.
  Future<void> requireChecksum(String path, String expectedSha256) async {
    final file = File(path);
    if (!await file.exists()) {
      throw DownloadFailedException(
        'Cannot verify $path: the file does not exist',
        url: Uri.file(path),
      );
    }
    final actual = await checksumOf(path);
    if (Checksums.matches(expectedSha256, actual)) return;
    await file.delete();
    throw ChecksumMismatchException(
      expected: expectedSha256.toLowerCase(),
      actual: actual,
    );
  }

  /// Releases the underlying HTTP client, if this manager created it.
  void close() {
    if (_ownsClient) _http.close();
  }

  // ------------------------------------------------------------- internals --

  Future<DownloadResult> _transfer({
    required Uri url,
    required File file,
    required String? expectedSha256,
    required Map<String, String> headers,
    required void Function(DownloadProgress progress)? onProgress,
    required bool resume,
  }) async {
    final existing = resume && await file.exists() ? await file.length() : 0;

    final response = await _open(
      url,
      headers: {
        ...headers,
        if (existing > 0) 'range': ByteRange.from(existing).toHeaderValue(),
      },
      acceptPartial: true,
    );

    // A server that ignores the range answers 200 with the whole body. Appending
    // that to a partial file would silently produce a corrupt artifact, so the
    // partial data is discarded and the transfer restarts.
    final isResuming = existing > 0 && response.statusCode == 206;
    final startFrom = isResuming ? existing : 0;
    if (existing > 0 && !isResuming) {
      await file.delete();
    }

    final total = response.contentLength == null
        ? null
        : response.contentLength! + startFrom;

    final sink = file.openWrite(
      mode: isResuming ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );
    var received = startFrom;
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(
          DownloadProgress(
            received: received,
            total: total,
            resumedFrom: startFrom,
          ),
        );
      }
      await sink.flush();
    } on Object catch (e) {
      await sink.close();
      // The partial file is deliberately kept: the next attempt resumes from
      // it, which is the whole point of writing incrementally.
      throw DownloadFailedException(
        'Transfer of $url failed after $received bytes: $e',
        url: url,
      );
    }
    await sink.close();

    // Hashed from the file rather than from the stream, so a resumed download
    // verifies the bytes already on disk as well as the ones just fetched.
    final checksum = await ChecksumStream.of(file.openRead());
    if (expectedSha256 != null &&
        !Checksums.matches(expectedSha256, checksum.sha256)) {
      await file.delete();
      throw ChecksumMismatchException(
        expected: expectedSha256.toLowerCase(),
        actual: checksum.sha256,
      );
    }

    return DownloadResult(
      file: file,
      sizeBytes: checksum.sizeBytes,
      sha256: checksum.sha256,
      resumed: isResuming,
    );
  }

  /// Whether [file] is already the artifact being asked for.
  Future<bool> _isAlreadyComplete(
    File file,
    String? expectedSha256,
    int? expectedSize,
  ) async {
    if (!await file.exists()) return false;
    final size = await file.length();
    if (expectedSize != null && size != expectedSize) return false;
    if (expectedSha256 == null) {
      // Without a checksum, a size match is the only evidence available — and
      // no evidence at all when the size was not supplied either, in which case
      // re-downloading is the safe answer.
      return expectedSize != null;
    }
    final actual = await ChecksumStream.of(file.openRead());
    return Checksums.matches(expectedSha256, actual.sha256);
  }

  Future<http.StreamedResponse> _open(
    Uri url, {
    Map<String, String> headers = const {},
    bool acceptPartial = false,
  }) async {
    final request = http.Request('GET', url)
      ..followRedirects = true
      ..headers.addAll({'user-agent': userAgent, ...headers});

    final http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(timeout);
    } on TimeoutException {
      throw DownloadFailedException(
        'Timed out after ${timeout.inSeconds}s waiting for $url',
        url: url,
      );
    } on http.ClientException catch (e) {
      throw DownloadFailedException(
        'Cannot reach $url: ${e.message}',
        url: url,
      );
    }

    final ok =
        response.statusCode == 200 ||
        (acceptPartial && response.statusCode == 206);
    if (!ok) {
      await response.stream.drain<void>();
      throw DownloadFailedException(
        'Server answered ${response.statusCode} for $url',
        url: url,
        responseStatus: response.statusCode,
      );
    }
    return response;
  }
}
