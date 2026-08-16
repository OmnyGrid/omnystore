# Client SDK guide

```dart
import 'package:omnystore/omnystore_client.dart';

final client = OmnyStoreClient(baseUrl: 'https://store.example.com');
final latest = await client.latestRelease('omnyagent');
```

`omnystore_client.dart` imports no `dart:io`. It compiles to JavaScript and runs
unchanged on the Dart VM, in Flutter, and in a browser — the only transport is
`package:http`.

## The same interface, everywhere

`OmnyStoreClient` implements `OmnyStoreApi`, the same contract the embedded
`OmnyStore` and the federating `OmnyStoreHub` implement. Write against the
interface and the code moves between them by changing one line:

```dart
Future<void> publishNightly(OmnyStoreApi store, List<int> bytes) async {
  final release = await store.publishRelease(
    packageReference: 'omnyagent',
    version: Versions.stamp(baseVersion, ReleaseChannel.dev, buildNumber),
  );
  await store.attachAsset(
    releaseId: release.id,
    name: 'omnyagent-linux-x64.tar.gz',
    data: Stream.value(bytes),
    platform: 'linux-x64',
  );
}

await publishNightly(OmnyStore(…), bytes);                       // embedded
await publishNightly(OmnyStoreClient(baseUrl: '…'), bytes);      // remote
```

## Errors keep their type

The server sends a stable `code` with every failure and the client rebuilds the
original exception from it. `on ReleaseNotFoundException` works across the
network exactly as it does in-process — which is what makes the substitution
above safe, rather than merely compiling.

```dart
try {
  final latest = await client.latestRelease('omnyagent');
} on PackageNotFoundException catch (e) {
  print('No such package: ${e.reference}');
} on ReleaseNotFoundException {
  print('Nothing published on that channel yet.');
} on ChecksumMismatchException catch (e) {
  // The artifact did not match its recorded digest. Treat it as hostile.
  print('Corrupt download: expected ${e.expected}, got ${e.actual}');
} on UnauthorizedException {
  print('Credentials rejected.');
} on ApiException catch (e) {
  // The registry is unreachable, or answered something unexpected.
  print('${e.statusCode}: ${e.message}');
}
```

`ApiException` is the catch-all for transport failures and unrecognised codes.
A code this client version does not know round-trips verbatim rather than
degrading into something meaningless, so a newer server never breaks an older
client's reporting.

## Authentication

```dart
OmnyStoreClient(
  baseUrl: 'https://store.example.com',
  auth: const TokenAuthProvider(myToken),
);
```

| Provider | Use |
|---|---|
| `AnonymousAuthProvider` | The default. Reads on a public registry. |
| `TokenAuthProvider` | A fixed bearer token — CI credentials, machine access. |
| `RefreshingAuthProvider` | A short-lived credential: OIDC, workload identity. |
| `CompositeAuthProvider` | Several headers at once — a token plus a tenant header. |

`headers()` is called before *every* request, not once, which is what makes a
rotating credential possible. On a `401` the client calls `refresh()` and, if it
reports the credentials changed, retries once — so an expiring token does not
surface as a spurious failure. The bundled fixed providers return `false`, since
retrying against an unchanged credential would turn one clear `401` into two.

```dart
OmnyStoreClient(
  baseUrl: 'https://store.example.com',
  auth: RefreshingAuthProvider(() async => fetchAccessToken()),
);
```

## Checking for updates

```dart
final update = await client.checkForUpdates(
  packageReference: 'omnyagent',
  currentVersion: Version.parse(myVersion),
  channel: ReleaseChannel.beta,
  platform: Platforms.current,   // 'macos-arm64' on Apple Silicon
);
```

`Platforms.current` reports this process's `os-arch` token, which is what an
updater almost always wants — an Intel build offered to an Apple Silicon
machine fails at launch, on the user's machine. It reads the architecture from
the Dart VM's own target triple, and `Platforms.normalize` understands the
spellings other toolchains use (`darwin-aarch64`, `osx-x86_64`, `win32-amd64`).

It uses `dart:io`, so it is in `package:omnystore/omnystore.dart` rather than
the web client barrel. A browser has no native architecture; pass
`Platforms.web` there, or omit the platform entirely.

Three outcomes worth distinguishing:

```dart
if (!update.updateAvailable) {
  // Current, or ahead of the registry. Never a downgrade.
} else if (!update.isInstallable) {
  // An update exists, but ships no artifact for this platform.
  // Gate a download button on `isInstallable`, not `updateAvailable`.
} else {
  print('${update.latestVersion}: ${update.notes}');
  print('${update.asset!.name}, ${update.asset!.sizeBytes} bytes');
}
```

`UpdateChecker` wraps this for the polling case:

```dart
final checker = UpdateChecker.forVersion(
  store: client,
  packageReference: 'omnyagent',
  currentVersion: myVersion,
  channel: ReleaseChannel.release,
  platform: 'linux-x64',
);

checker
    .watch(
      interval: const Duration(hours: 6),
      onError: (error, _) => log.warning('Update check failed: $error'),
    )
    .listen((info) {
      if (info.updateAvailable) showBanner(info);
    });
```

`watch` emits only when the answer *changes*, so a subscriber can drive a
"restart to update" banner directly without deduplicating. A failed poll is
swallowed rather than closing the stream — over a long-running process the
registry will be briefly unreachable at some point, and a background updater
that dies the first time is worse than useless.

## Downloading

### On the VM and Flutter

`DownloadManager` streams to disk, resumes, retries, and verifies:

```dart
final result = await DownloadManager().downloadAsset(
  asset: update.asset!,
  url: client.assetDownloadUrl(update.asset!.id),
  destination: '/opt/omnyagent',
  onProgress: (p) => stdout.write('\r${p.percent}%'),
);

if (result.wasCached) print('already up to date');
if (result.resumed)   print('resumed an interrupted download');
```

Expectations come from the asset record, so there is no way to forget them. A
file that fails its checksum is **deleted** before the exception is thrown —
there is no flag to skip that, because an update mechanism that leaves
unverified bytes on disk is a malware delivery channel for anyone who can
interpose on the network or write to the artifact store.

Resume verifies the bytes *already on disk* as well as the newly fetched ones,
so a partial file with a corrupt prefix cannot be completed into a
plausible-looking, broken artifact.

### In a browser

There is no filesystem, so there are two paths:

```dart
// Small enough to hold: fetched and verified against the recorded digest.
final bytes = await client.downloadAsset(asset.id);

// Large: hand the URL to the browser and let it do the download.
anchor.href = client.assetDownloadUrl(asset.id).toString();
```

`assetDownloadUrl` is a plain URL with no credentials of its own. The server
answers it with either the bytes or a `302` to wherever the holding provider
keeps them.

## Browser requirements

Two things the server must do, both one line:

```dart
OmnyStoreServer(
  store: store,
  allowedOrigins: const ['https://releases.example.com'],
);
```

1. **Allow the origin.** CORS is mounted in OmnyHub's *outer* middleware, so
   preflights are answered before authentication and the browser can read error
   responses rather than seeing an opaque network failure.
2. **Expose `x-omnystore-sha256`.** Done automatically. Without it the digest is
   on the wire but invisible to JavaScript, and a browser-side downloader could
   not verify what it fetched.

Verify web-safety yourself:

```sh
dart compile js -o /tmp/out.js example/building_on_it/web_client.dart
```

## Sharing a connection pool

```dart
final http = IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 5));

final client = OmnyStoreClient(baseUrl: '…', httpClient: http);
```

A supplied client is not closed by `OmnyStoreClient.close()` — its lifetime
belongs to whoever created it. It is also the seam for a `MockClient` in tests,
and for retry or tracing middleware.

## Reference

```dart
// Discovery
await client.health();
await client.listOrganizations();
await client.listProjects(organizationId: org.id);
await client.listPackages(projectId: project.id);

// Releases
await client.listReleases('omnyagent', query: const ReleaseQuery(limit: 20));
await client.releaseByVersion('omnyagent', Version.parse('1.2.0'));
await client.latestRelease('omnyagent');
await client.latestBeta('omnyagent');
await client.latestDev('omnyagent');
await client.latestChannel('omnyagent', ReleaseChannel.beta, exact: true);
await client.latestAny('omnyagent');

// Artifacts
await client.listAssets(release.id);
await client.downloadAsset(asset.id);              // verified bytes
await client.openAsset(asset.id, range: ByteRange(0, 1023));
client.assetDownloadUrl(asset.id);                 // a plain URL

// Publishing
await client.publishRelease(packageReference: 'omnyagent', version: v);
await client.attachAsset(releaseId: r.id, name: n, data: stream);
await client.promoteRelease(r.id, ReleaseChannel.release);
await client.updateRelease(r.id, yanked: true, yankedReason: '…');

// Analytics
await client.downloadStats('omnyagent', from: lastWeek);

// Topology
await client.listProviders();
```

`recordDownload` is the one operation a client cannot perform: the server
records a download as it serves it, and letting clients report their own would
make the numbers meaningless. It raises `UnsupportedOperationException`.
