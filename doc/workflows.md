# Release and update workflows

Two workflows, end to end: getting a build into the registry, and getting it
onto a machine.

## The release workflow

### 1. Set up the hierarchy, once

```sh
omnystore org create acme --display-name 'Acme Corporation'
omnystore project create agent --org acme \
  --repository https://github.com/acme/agent
omnystore package create omnyagent --project "$PROJECT_ID" \
  --platform linux-x64 --platform macos-arm64 --platform windows-x64 \
  --default-channel release
```

`--default-channel` is what a client is offered when it does not name one. It
defaults to `release`, so a caller who has not opted in to pre-releases is never
handed one.

### 2. Let the branch decide the channel

The version's pre-release tag *is* the channel, so one pipeline produces all
three without any conditional publishing logic:

```sh
case "$CI_BRANCH" in
  release) VERSION="$BASE_VERSION" ;;                              # 1.4.0
  beta)    VERSION="$BASE_VERSION-beta.$CI_BUILD_NUMBER" ;;        # 1.4.0-beta.7
  *)       VERSION="$BASE_VERSION-dev.$CI_BUILD_NUMBER" ;;         # 1.4.0-dev.412
esac
```

In Dart:

```dart
Versions.stamp(baseVersion, channel, buildNumber);   // 1.4.0-beta.7
```

### 3. Publish, with the artifacts

```sh
omnystore release publish \
  --package omnyagent \
  --version "$VERSION" \
  --notes @CHANGELOG.md \
  --tag "$CI_COMMIT_TAG" \
  --metadata "commit=$CI_COMMIT_SHA" \
  --asset build/omnyagent-linux-x64.tar.gz:linux-x64 \
  --asset build/omnyagent-macos-arm64.tar.gz:macos-arm64 \
  --asset build/omnyagent-windows-x64.zip:windows-x64
```

Uploads compute the file's checksum locally and require the server to agree, so
a corrupted transfer fails the build instead of publishing bad bytes.

**Always set the platform.** It is what lets the update service answer "is there
an update *for me*"; without it, a `macos-arm64` client can be offered a Linux
binary or nothing at all.

### One release, many architectures

A release is a *version*; the builds hang off it as artifacts, each tagged with
the `os-arch` platform it was compiled for. `macos-x64` (Intel) and
`macos-arm64` (Apple Silicon) are two artifacts on the same `1.4.0`, not two
releases:

```text
1.4.0
├── omnyagent-linux-x64.tar.gz       platform: linux-x64
├── omnyagent-linux-arm64.tar.gz     platform: linux-arm64
├── omnyagent-macos-x64.tar.gz       platform: macos-x64      ← Intel
├── omnyagent-macos-arm64.tar.gz     platform: macos-arm64    ← Apple Silicon
└── omnyagent-windows-x64.zip        platform: windows-x64
```

`Package.platforms` advertises which ones you build for, so a client can tell
whether a build exists for it before downloading anything.

The rule the update service enforces: **a client is never handed a build for
another architecture.** An Intel binary offered to an Apple Silicon machine
fails after the download, at launch, on the user's machine — worse than
offering nothing. So the match is exact, and the only fallback is a genuinely
platform-independent artifact (one published with no `platform` at all).

When a build is missing for one architecture — a matrix runner failed, say —
that platform's clients get `updateAvailable: true` with `asset: null`. That is
the `isInstallable` distinction: the update exists, but not for them.

Re-publishing an existing version is a `conflict` and exits `1`. That is
correct: releases are immutable, so a rebuild gets a new version rather than
overwriting one clients may already have downloaded.

### 4. Stage with a draft, if you need to check first

```sh
omnystore release publish --package omnyagent --version 1.4.0 --draft
omnystore asset upload --release "$ID" --file build/agent.tar.gz --platform linux-x64
# …verify the artifacts…
omnystore release yank "$ID" --undo   # or, to publish:
```

```dart
await store.updateRelease(id, draft: false);   // stamps publishedAt
```

A draft is stored but never offered by any `latest*` query or the update
service. Nobody sees it until you publish.

### 5. Promote when it has soaked

```sh
omnystore release promote "$BETA_RELEASE_ID" --to release
```

`1.4.0-beta.7` → `1.4.0`, artifacts copied across, the beta left in place for
anyone still on it. Promotion only moves towards stability.

Because channel queries are inclusive downward, publishing `1.4.0` immediately
reaches beta *and* dev subscribers too — no republishing per channel.

### 6. Retract a bad release

```sh
omnystore release yank "$RELEASE_ID" --reason 'Corrupts the config on first run'
```

A yanked release **stays downloadable** — clients that pinned it keep working —
but is excluded from every `latest*` query and never offered as an update.
Prefer it to `delete`, which breaks those clients.

Then ship the fix as a new version. Un-yanking clears the reason.

### 7. Watch the rollout

```sh
omnystore --json release list --package omnyagent | jq '.[0].version'
```

```dart
final stats = await store.downloadStats('omnyagent', from: rolloutStarted);
stats.byVersion;   // {'1.3.0': 52, '1.4.0': 126}
```

Adoption per version is what tells you whether the rollout is progressing — and
whether a yank actually stopped the bleeding.

## The update workflow

### 1. Ask

```dart
final checker = UpdateChecker.forVersion(
  store: OmnyStoreClient(baseUrl: 'https://store.example.com'),
  packageReference: 'omnyagent',
  currentVersion: omnyAgentVersion,       // the generated constant
  channel: userSelectedChannel,           // release by default
  platform: currentPlatform,              // 'macos-arm64'
);

final update = await checker.checkForUpdates();
```

### 2. Branch on three outcomes, not two

```dart
if (!update.updateAvailable) {
  // Current, or ahead of the registry — a developer on a local build is
  // never pushed backwards.
} else if (!update.isInstallable) {
  // An update exists, but ships nothing this platform can install.
  // A download button gated on `updateAvailable` would offer a dead end.
  log.info('${update.latestVersion} is out, but not for $currentPlatform yet');
} else {
  showBanner(update.latestVersion, update.notes);
}
```

### 3. Download, verified and resumable

```dart
final result = await DownloadManager().downloadAsset(
  asset: update.asset!,
  url: client.assetDownloadUrl(update.asset!.id),
  destination: '/opt/omnyagent',
  onProgress: (p) => reportProgress(p.fraction),
);
```

Expectations come from the asset record, so there is no way to forget them. A
file that fails its checksum is deleted before the exception is thrown. Calling
this on every start is safe: an already-complete, verified file transfers
nothing and reports `wasCached`.

An interrupted download resumes from what is on disk, and verifies the bytes
that were already there — so a partial file with a corrupt prefix cannot be
completed into a plausible-looking, broken artifact.

### 4. Poll in the background

```dart
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
banner directly. A failed poll is swallowed rather than closing the stream: over
a long-running process the registry will be briefly unreachable at some point,
and an updater that dies the first time is worse than useless.

### Letting users choose a channel

```dart
// Show what is on each channel without switching to it.
for (final channel in ReleaseChannel.values) {
  final release = await checker.latestChannel(channel);
  print('${channel.name}: ${release?.version ?? '—'}');
}
```

Switching a user to `beta` means they accept beta *and* stable, so a newer
stable release still reaches them. Switching back to `release` offers only
stable — and if they are currently on a beta *newer* than the latest stable,
they are simply told they are current rather than being downgraded.

## Shell-only update loop

For a machine with no Dart runtime:

```sh
#!/bin/sh
set -e
export OMNYSTORE_URL=https://store.example.com

CURRENT=$(omnyagent --version)

if omnystore check-update --package omnyagent --current "$CURRENT" --quiet; then
  exit 0                                  # 0 = already current
fi                                        # 10 = an update exists

omnystore download \
  --package omnyagent \
  --platform linux-x64 \
  --output /opt/omnyagent/staging

systemctl stop omnyagent
tar -xzf /opt/omnyagent/staging/*.tar.gz -C /opt/omnyagent
systemctl start omnyagent
```

The download is checksum-verified before it lands, so the `tar` step never sees
bytes the registry did not vouch for.

### Pulling a whole release

An updater wants one artifact; a mirror, a signing step or a GitHub-release
publisher wants all of them. `--platform all` fetches every artifact in the
release into a directory, each verified against its own digest:

```sh
omnystore download --package omnyagent --version 1.4.0 --platform all -o dist/
gh release create v1.4.0 dist/*
```

A subset works the same way — repeat the flag, or comma-separate it:

```sh
omnystore download --package omnyagent \
  --platform macos-x64,macos-arm64 -o dist/
```

`--kind` narrows by what an artifact *is* rather than what it targets, and the
two compose:

```sh
omnystore download --package omnyagent --kind installer          # this machine
omnystore download --package omnyagent --platform all \
  --kind installer,archive -o dist/                              # builds only
omnystore download --package omnyagent --platform all \
  --kind checksums -o dist/                                      # digests only
```

Without `--kind`, a single-artifact download never picks a checksum file or a
signature, and prefers an `installer` over an `archive` — the same rule the
update service applies. `--platform all` keeps the auxiliary files, since a
mirror wants the digests too.

## Migrating an existing registry

Publishing historical releases keeps their real timestamps out of the way — the
version ordering is what `latest*` uses, not `publishedAt`:

```dart
for (final old in existingReleases) {
  final release = await store.publishRelease(
    packageReference: 'omnyagent',
    version: Versions.parse(old.version),
    notes: old.notes,
    metadata: {'migratedFrom': old.url},
  );
  for (final artifact in old.artifacts) {
    await store.attachAsset(
      releaseId: release.id,
      name: artifact.name,
      data: artifact.openRead(),
      length: artifact.length,
      expectedSha256: artifact.knownDigest,   // fails loudly if it drifted
      platform: artifact.platform,
    );
  }
}
```

Passing `expectedSha256` from whatever the old registry recorded turns a silent
corruption during migration into a hard failure — which is exactly when you want
to find out.
