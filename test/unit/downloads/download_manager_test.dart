import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnystore/omnystore.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/harness.dart';

/// A stand-in origin server that honours `Range`, so resume is exercised for
/// real rather than assumed.
///
/// Records every request so a test can assert *what was asked for* — the
/// difference between "the file ended up right" and "only the missing bytes
/// were fetched" is the whole point of resuming.
class FakeOrigin {
  final List<int> body;
  final List<String?> rangeHeaders = [];
  int requests = 0;

  /// Whether to ignore `Range` and answer `200` with the whole body, as some
  /// proxies and object stores do.
  bool ignoreRanges = false;

  /// Fails the first [failures] requests mid-stream.
  int failures = 0;

  FakeOrigin(String content) : body = utf8.encode(content);

  http.Client get client => MockClient.streaming((request, bodyStream) async {
    requests++;
    final range = request.headers['range'];
    rangeHeaders.add(range);

    if (failures > 0) {
      failures--;
      throw http.ClientException('connection reset', request.url);
    }

    if (range == null || ignoreRanges) {
      return http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
      );
    }

    final start = int.parse(
      RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
    );
    final slice = body.sublist(start);
    return http.StreamedResponse(
      Stream.value(slice),
      206,
      contentLength: slice.length,
      headers: {
        'content-range': 'bytes $start-${body.length - 1}/${body.length}',
      },
    );
  });
}

void main() {
  final url = Uri.parse('https://store.example.com/download');
  const payload = 'the complete artifact payload, long enough to resume';
  final payloadDigest = Checksums.sha256OfString(payload);

  group('downloadToMemory', () {
    test('returns the bytes with their digest', () async {
      final origin = FakeOrigin(payload);
      final manager = DownloadManager(httpClient: origin.client);
      addTearDown(manager.close);

      final result = await manager.downloadToMemory(url: url);

      expect(utf8.decode(result.bytes!), payload);
      expect(result.sizeBytes, payload.length);
      expect(result.sha256, payloadDigest);
    });

    test('verifies a supplied checksum', () async {
      final manager = DownloadManager(httpClient: FakeOrigin(payload).client);
      addTearDown(manager.close);

      await expectLater(
        manager.downloadToMemory(
          url: url,
          expectedSha256: Checksums.sha256OfString('something else'),
        ),
        throwsA(isA<ChecksumMismatchException>()),
      );
    });

    test('reports progress', () async {
      final manager = DownloadManager(httpClient: FakeOrigin(payload).client);
      addTearDown(manager.close);

      final seen = <DownloadProgress>[];
      await manager.downloadToMemory(url: url, onProgress: seen.add);

      expect(seen, isNotEmpty);
      expect(seen.last.received, payload.length);
      expect(seen.last.percent, 100);
      expect(seen.last.fraction, 1.0);
    });

    test('refuses a body above the caller limit', () async {
      final manager = DownloadManager(httpClient: FakeOrigin(payload).client);
      addTearDown(manager.close);

      await expectLater(
        manager.downloadToMemory(url: url, maxBytes: 10),
        throwsA(isA<DownloadFailedException>()),
      );
    });

    test('reports a bad status as a download failure', () async {
      final manager = DownloadManager(
        httpClient: MockClient((_) async => http.Response('nope', 404)),
        maxRetries: 0,
      );
      addTearDown(manager.close);

      await expectLater(
        manager.downloadToMemory(url: url),
        throwsA(
          isA<DownloadFailedException>()
              .having((e) => e.responseStatus, 'status', 404)
              .having((e) => e.url, 'url', url),
        ),
      );
    });

    test('reports an unreachable origin as a download failure', () async {
      final manager = DownloadManager(
        httpClient: MockClient(
          (request) async => throw http.ClientException('refused', request.url),
        ),
      );
      addTearDown(manager.close);

      await expectLater(
        manager.downloadToMemory(url: url),
        throwsA(isA<DownloadFailedException>()),
      );
    });
  });

  group('downloadToFile', () {
    test('writes the artifact and verifies it', () async {
      await withTempDir((dir) async {
        final manager = DownloadManager(httpClient: FakeOrigin(payload).client);
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'agent.tar.gz');

        final result = await manager.downloadToFile(
          url: url,
          destination: destination,
          expectedSha256: payloadDigest,
        );

        expect(File(destination).readAsStringSync(), payload);
        expect(result.sha256, payloadDigest);
        expect(result.wasCached, isFalse);
        expect(result.resumed, isFalse);
      });
    });

    test('creates the destination directory', () async {
      await withTempDir((dir) async {
        final manager = DownloadManager(httpClient: FakeOrigin(payload).client);
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'a', 'b', 'agent.tar.gz');

        await manager.downloadToFile(url: url, destination: destination);

        expect(File(destination).existsSync(), isTrue);
      });
    });

    test('deletes a corrupt download rather than leaving it', () async {
      await withTempDir((dir) async {
        final manager = DownloadManager(httpClient: FakeOrigin(payload).client);
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'agent.tar.gz');

        await expectLater(
          manager.downloadToFile(
            url: url,
            destination: destination,
            expectedSha256: Checksums.sha256OfString('something else'),
          ),
          throwsA(isA<ChecksumMismatchException>()),
        );

        // An update mechanism that leaves unverified bytes on disk is a
        // malware delivery channel for anyone who can interpose.
        expect(File(destination).existsSync(), isFalse);
      });
    });

    test('does not retry a checksum failure', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload);
        final manager = DownloadManager(
          httpClient: origin.client,
          maxRetries: 5,
          retryDelay: Duration.zero,
        );
        addTearDown(manager.close);

        await expectLater(
          manager.downloadToFile(
            url: url,
            destination: p.join(dir.path, 'agent.tar.gz'),
            expectedSha256: Checksums.sha256OfString('something else'),
          ),
          throwsA(isA<ChecksumMismatchException>()),
        );

        // Retrying would fetch the same wrong bytes five more times.
        expect(origin.requests, 1);
      });
    });

    test('skips a file that is already complete and verified', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload);
        final manager = DownloadManager(httpClient: origin.client);
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'agent.tar.gz');
        File(destination).writeAsStringSync(payload);

        final result = await manager.downloadToFile(
          url: url,
          destination: destination,
          expectedSha256: payloadDigest,
        );

        // Safe to call on every application start.
        expect(result.wasCached, isTrue);
        expect(origin.requests, 0);
      });
    });

    test('re-downloads when the existing file does not verify', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload);
        final manager = DownloadManager(httpClient: origin.client);
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'agent.tar.gz');
        File(destination).writeAsStringSync('stale contents');

        final result = await manager.downloadToFile(
          url: url,
          destination: destination,
          expectedSha256: payloadDigest,
          resume: false,
        );

        expect(result.wasCached, isFalse);
        expect(File(destination).readAsStringSync(), payload);
      });
    });
  });

  group('resume', () {
    test('fetches only the missing bytes', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload);
        final manager = DownloadManager(httpClient: origin.client);
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'agent.tar.gz');
        // A partial file from an interrupted attempt.
        File(destination).writeAsStringSync(payload.substring(0, 20));

        final result = await manager.resumeDownload(
          url: url,
          destination: destination,
          expectedSha256: payloadDigest,
        );

        expect(result.resumed, isTrue);
        expect(File(destination).readAsStringSync(), payload);
        expect(origin.rangeHeaders.single, 'bytes=20-');
      });
    });

    test('verifies the bytes already on disk, not just the new ones', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload);
        final manager = DownloadManager(
          httpClient: origin.client,
          maxRetries: 0,
        );
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'agent.tar.gz');
        // A partial file whose prefix is wrong — appending the remainder would
        // produce a plausible-looking, corrupt artifact.
        File(destination).writeAsStringSync('X' * 20);

        await expectLater(
          manager.resumeDownload(
            url: url,
            destination: destination,
            expectedSha256: payloadDigest,
          ),
          throwsA(isA<ChecksumMismatchException>()),
        );
        expect(File(destination).existsSync(), isFalse);
      });
    });

    test('restarts when the server ignores the range', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload)..ignoreRanges = true;
        final manager = DownloadManager(httpClient: origin.client);
        addTearDown(manager.close);
        final destination = p.join(dir.path, 'agent.tar.gz');
        File(destination).writeAsStringSync(payload.substring(0, 20));

        final result = await manager.downloadToFile(
          url: url,
          destination: destination,
          expectedSha256: payloadDigest,
        );

        // Appending a full body to a partial file would silently corrupt it.
        expect(result.resumed, isFalse);
        expect(File(destination).readAsStringSync(), payload);
      });
    });

    test('retries a dropped transfer, resuming from what it wrote', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload)..failures = 2;
        final manager = DownloadManager(
          httpClient: origin.client,
          maxRetries: 3,
          retryDelay: Duration.zero,
        );
        addTearDown(manager.close);

        final result = await manager.downloadToFile(
          url: url,
          destination: p.join(dir.path, 'agent.tar.gz'),
          expectedSha256: payloadDigest,
        );

        expect(result.sha256, payloadDigest);
        expect(origin.requests, 3);
      });
    });

    test('gives up after the retry budget', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload)..failures = 99;
        final manager = DownloadManager(
          httpClient: origin.client,
          maxRetries: 2,
          retryDelay: Duration.zero,
        );
        addTearDown(manager.close);

        await expectLater(
          manager.downloadToFile(
            url: url,
            destination: p.join(dir.path, 'agent.tar.gz'),
          ),
          throwsA(isA<DownloadFailedException>()),
        );
        expect(origin.requests, 3);
      });
    });
  });

  group('checksums', () {
    test('computes a file digest by streaming it', () async {
      await withTempDir((dir) async {
        final manager = DownloadManager();
        addTearDown(manager.close);
        final path = p.join(dir.path, 'x.bin');
        File(path).writeAsStringSync(payload);

        expect(await manager.checksumOf(path), payloadDigest);
        expect(await manager.verifyChecksum(path, payloadDigest), isTrue);
        expect(await manager.verifyChecksum(path, 'deadbeef'), isFalse);
      });
    });

    test('treats a missing file as not matching', () async {
      final manager = DownloadManager();
      addTearDown(manager.close);

      // "Is this the artifact I want?" has the same answer whether it is wrong
      // or absent.
      expect(
        await manager.verifyChecksum('/nonexistent/path', payloadDigest),
        isFalse,
      );
    });

    test('requireChecksum deletes a mismatching file', () async {
      await withTempDir((dir) async {
        final manager = DownloadManager();
        addTearDown(manager.close);
        final path = p.join(dir.path, 'x.bin');
        File(path).writeAsStringSync('wrong');

        await expectLater(
          manager.requireChecksum(path, payloadDigest),
          throwsA(isA<ChecksumMismatchException>()),
        );
        expect(File(path).existsSync(), isFalse);
      });
    });

    test('requireChecksum passes a matching file through', () async {
      await withTempDir((dir) async {
        final manager = DownloadManager();
        addTearDown(manager.close);
        final path = p.join(dir.path, 'x.bin');
        File(path).writeAsStringSync(payload);

        await manager.requireChecksum(path, payloadDigest);
        expect(File(path).existsSync(), isTrue);
      });
    });
  });

  group('downloadAsset', () {
    test('takes its expectations from the asset record', () async {
      await withTempDir((dir) async {
        final origin = FakeOrigin(payload);
        final manager = DownloadManager(httpClient: origin.client);
        addTearDown(manager.close);

        final asset = Asset(
          id: 'asset-1',
          releaseId: 'rel-1',
          packageId: 'pkg-1',
          organizationId: 'org-1',
          name: 'omnyagent-linux-x64.tar.gz',
          storageKey: 'k',
          sizeBytes: payload.length,
          sha256: payloadDigest,
          createdAt: DateTime.utc(2026),
        );

        // A directory destination saves under the asset's own name.
        final result = await manager.downloadAsset(
          asset: asset,
          url: url,
          destination: dir.path,
        );

        expect(
          result.file!.path,
          p.join(dir.path, 'omnyagent-linux-x64.tar.gz'),
        );
        expect(result.sha256, payloadDigest);
      });
    });

    test('catches a substituted artifact using the recorded digest', () async {
      await withTempDir((dir) async {
        final manager = DownloadManager(
          httpClient: FakeOrigin('malicious replacement').client,
          maxRetries: 0,
        );
        addTearDown(manager.close);

        final asset = Asset(
          id: 'asset-1',
          releaseId: 'rel-1',
          packageId: 'pkg-1',
          organizationId: 'org-1',
          name: 'agent.tar.gz',
          storageKey: 'k',
          sizeBytes: payload.length,
          sha256: payloadDigest,
          createdAt: DateTime.utc(2026),
        );

        await expectLater(
          manager.downloadAsset(asset: asset, url: url, destination: dir.path),
          throwsA(isA<ChecksumMismatchException>()),
        );
        expect(File(p.join(dir.path, 'agent.tar.gz')).existsSync(), isFalse);
      });
    });
  });

  group('DownloadProgress', () {
    test('reports an unknown total as an unknown fraction', () {
      const progress = DownloadProgress(received: 50);
      expect(progress.fraction, isNull);
      expect(progress.percent, isNull);
    });

    test('clamps to 1.0 if more arrives than expected', () {
      const progress = DownloadProgress(received: 120, total: 100);
      expect(progress.fraction, 1.0);
      expect(progress.percent, 100);
    });

    test('handles a zero total without dividing by zero', () {
      const progress = DownloadProgress(received: 0, total: 0);
      expect(progress.fraction, isNull);
    });
  });
}
