import 'package:omnystore/omnystore_client.dart';

/// **19 — The registry from a browser.**
///
/// This file compiles to JavaScript. `package:omnystore/omnystore_client.dart`
/// imports no `dart:io`, so a Flutter Web app or a plain Dart web app can talk
/// to the registry directly — a release dashboard, an in-app "update
/// available" banner, a download page.
///
/// ```sh
/// # Verify it really is web-safe:
/// dart compile js -o /tmp/out.js example/building_on_it/web_client.dart
/// ```
///
/// **Two things the server must do for a browser to work:**
///
/// 1. Allow the origin. `OmnyStoreServer(allowedOrigins: ['https://…'])`
///    mounts CORS in OmnyHub's *outer* middleware, so preflights are answered
///    before authentication and the browser can read error responses rather
///    than seeing an opaque network failure.
/// 2. Expose `x-omnystore-sha256`. The server does this automatically; without
///    it the header is on the wire but invisible to JavaScript, so a
///    browser-side downloader could not verify what it fetched.
Future<void> main() async {
  final client = OmnyStoreClient(baseUrl: 'https://store.example.com');

  try {
    // ------------------------------------------------ a release page ---
    final releases = await client.listReleases(
      'omnyagent',
      query: const ReleaseQuery(limit: 10),
    );
    for (final release in releases) {
      print('${release.version}  ${release.channel.name}  ${release.title}');
      for (final asset in await client.listAssets(release.id)) {
        // Hand this straight to an <a href>; it is a plain URL, and the server
        // answers it with either the bytes or a redirect to wherever the
        // holding provider keeps them.
        print('  ${asset.name} → ${client.assetDownloadUrl(asset.id)}');
      }
    }

    // --------------------------------------- an in-app update banner ---
    final update = await client.checkForUpdates(
      packageReference: 'omnyagent',
      currentVersion: Version.parse('1.0.0'),
      channel: ReleaseChannel.release,
      platform: 'web',
    );
    if (update.updateAvailable) {
      print('\nA new version is available: ${update.latestVersion}');
      print(update.notes ?? '');
    }

    // ----------------------------------- downloading, with the check ---
    // `downloadAsset` verifies the bytes against the recorded digest before
    // returning them. In a browser this is the only download path — there is
    // no filesystem to stream to — so keep it to artifacts small enough to
    // hold in memory, and let the browser follow `assetDownloadUrl` for the
    // large ones.
    final asset = update.asset;
    if (asset != null && asset.sizeBytes < 8 * 1024 * 1024) {
      final bytes = await client.downloadAsset(asset.id);
      print('Fetched and verified ${bytes.length} bytes of ${asset.name}');
    }
  } on ChecksumMismatchException catch (e) {
    // The artifact did not match its recorded digest. Treat it as hostile.
    print('Corrupt download: expected ${e.expected}, got ${e.actual}');
  } on PackageNotFoundException {
    print('That package is not in this registry.');
  } on ApiException catch (e) {
    // Includes the case a browser hits when CORS is not configured: the
    // request never reaches the server, and this is where it surfaces.
    print('Registry unreachable: ${e.message}');
  } finally {
    await client.close();
  }
}
