# OmnyStore

[![pub package](https://img.shields.io/pub/v/omnystore.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/omnystore)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/OmnyGrid/omnystore/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/OmnyGrid/omnystore/actions/workflows/dart.yml)
[![GitHub Tag](https://img.shields.io/github/v/tag/OmnyGrid/omnystore?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnystore/releases)
[![New Commits](https://img.shields.io/github/commits-since/OmnyGrid/omnystore/latest?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnystore/network)
[![Last Commits](https://img.shields.io/github/last-commit/OmnyGrid/omnystore?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnystore/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/OmnyGrid/omnystore?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnystore/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/OmnyGrid/omnystore?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnystore)
[![License](https://img.shields.io/github/license/OmnyGrid/omnystore?logo=open-source-initiative&logoColor=green)](https://github.com/OmnyGrid/omnystore/blob/master/LICENSE)

**A complete release management and software distribution platform in pure
Dart.**

Organizations, projects, packages, releases, artifacts and channels behind one
SDK — with a REST API server, a web-compatible client, a resumable download
manager, an update service, a full CLI, and a Hub/Node architecture for
distributing storage across machines.

```text
                        ┌─────────────── OmnyStoreHub ────────────────┐
   clients ──REST──►    │  discovery + routing: org → providers       │
   CI      ──REST──►    │                                             │
   updaters──REST──►    │    acme   ─► node-eu, node-us               │
                        │    globex ─► node-eu                        │
                        │    *      ─► hub-local  (hub as provider)   │
                        └──────────┬──────────────────────────────────┘
                                   │ outbound WebSocket control plane
                   ┌───────────────┼───────────────┐
                node-eu         node-us         hub-local
              (S3, eu-west-1)  (local disk)    (in-process)
```

```dart
final store = OmnyStore(
  repositories: await JsonFileRepositories.open('/var/lib/omnystore/metadata'),
  storage: LocalObjectStorage('/var/lib/omnystore/objects'),
);

final release = await store.publishRelease(
  packageReference: 'omnyagent',
  version: Version.parse('1.2.0-beta.3'),   // channel is derived: beta
);
await store.attachAsset(
  releaseId: release.id,
  name: 'omnyagent-linux-x64.tar.gz',
  data: File('build/omnyagent-linux-x64.tar.gz').openRead(),
  platform: 'linux-x64',
);

await store.latestBeta('omnyagent');   // => 1.2.0-beta.3
await store.latestRelease('omnyagent'); // => 1.1.0 — betas are never offered
                                        //    to stable subscribers
```

```sh
omnystore server --data /var/lib/omnystore --port 8080
```

## API Documentation

See the full API docs at [pub.dev/documentation/omnystore][api_doc].

[api_doc]: https://pub.dev/documentation/omnystore/latest/

## Why this exists

Shipping software means answering four questions over and over: *what is the
newest build, is it right for this machine, where do I get it, and are these the
bytes you meant?* Most projects answer them with a directory of tarballs, a
hand-maintained `latest.json`, and hope.

OmnyStore answers them as a system:

- **The channel is the version.** `1.2.0-beta.3` *is* a beta; there is no
  separate flag that can drift out of sync with it, and a stable subscriber can
  never be handed a pre-release by accident.
- **Checksums are not optional.** Computed while streaming on upload, verified
  on download, and a mismatch deletes the file rather than returning it. An
  update mechanism that hands over unverified bytes is a malware delivery
  channel for anyone who can interpose.
- **Ranged and resumable.** A 4 GB installer interrupted at 90% costs 400 MB to
  finish, not 4 GB.
- **Storage is pluggable, and that decides your ceiling.** With S3 or GCS behind
  it, downloads redirect straight to the bucket and no artifact byte crosses the
  registry.

## Features

- **The whole lifecycle.** Organizations → projects → packages → releases →
  artifacts, with drafts, yanking, promotion between channels, and download
  analytics. Releases are immutable once published; retracting one is a *yank*,
  which stops it being offered without breaking clients that pinned it.
- **Channels derived from semver.** `dev`, `beta`, `release`, decided by the
  version's pre-release tag. Queries are inclusive downward in stability, so
  publishing `1.2.0` reaches beta *and* stable subscribers without republishing
  per channel. `latestRelease()`, `latestBeta()`, `latestDev()`,
  `latestChannel()`, `latestAny()`.
- **Four object-storage backends.** In-memory, a local directory (atomic
  writes, checksum sidecars, crash-safe temp sweeping), **AWS S3** (and any
  S3-compatible service — MinIO, R2, B2, Ceph) with hand-implemented SigV4
  presigning, and **Google Cloud Storage** with V4 URL signing from a service
  account. All behind one small `ObjectStorage` contract you can implement
  yourself.
- **Hub/Node architecture.** A hub is the discovery point; nodes hold the
  metadata *and* the bytes for the organizations they serve and dial the hub
  outbound, so they work behind NAT. **A hub can also be a provider**, so a
  small deployment is one process. Organizations and nodes are **many to
  many**.
- **Three data planes, chosen automatically.** Presigned URLs when the backend
  can issue them, a direct redirect when the node is reachable, and a chunked
  relay over the control channel when it is not — so even a fully firewalled
  node is a usable provider.
- **REST API on OmnyHub.** `/api/v1` plus an unversioned `/health`, with CORS,
  optional TLS (static or automatic Let's Encrypt), pluggable authentication,
  and the node control endpoint — all on **one port**. Mountable into an
  OmnyHub application you already run.
- **Web-compatible client SDK.** No `dart:io` anywhere in
  `omnystore_client.dart`; it compiles to JavaScript and runs in a browser. It
  implements the same interface as the embedded store, and **rebuilds the
  server's typed exceptions from the wire** — so `on ReleaseNotFoundException`
  works over HTTP exactly as it does in-process.
- **Update service.** `UpdateChecker` answers "is there a newer version *for
  me*", matching the client's platform, never offering a downgrade, and
  distinguishing "an update exists" from "an update exists that you can
  install".
- **Download manager.** Streams to disk, resumes with `Range`, retries a
  dropped transfer, verifies the whole file — including the bytes that were
  already there — and deletes anything that fails.
- **A CLI that is a library.** Every command runs in-process with injected
  arguments, environment and output sinks, so the whole surface is testable
  without spawning a subprocess. Machine-readable `--json` on every command;
  meaningful exit codes.
- **Strong typing, no global state.** Immutable models with value equality,
  sealed exception hierarchies, `abstract interface class` ports, and injected
  `Clock`/`IdGenerator`/`Logger` so tests are deterministic and two stores in
  one process share nothing.
- **Tested.** 411 tests: unit, integration over real sockets, the federation
  protocol end to end, AWS's own published SigV4 vectors, and real RSA
  signature verification.

## Concepts

| Term | Meaning |
|---|---|
| **Organization** | The top-level tenant, and the **unit of federation** — nodes serve organizations. |
| **Project** | A product within an organization; groups packages released together. |
| **Package** | The thing that has versions, and what a client asks about. |
| **Release** | A published version. Immutable. Its channel comes from its version. |
| **Asset** | A downloadable artifact attached to a release, with a mandatory SHA-256. |
| **Channel** | `dev` / `beta` / `release`, derived from the version's pre-release tag. |
| **Hub** | The discovery point: routing table, aggregation, REST API, node endpoint. |
| **Node** | A storage provider serving one or more organizations, dialling the hub outbound. |
| **Provider** | Anything that can hold and serve an organization's releases — a node, or the hub itself. |
| **ObjectStorage** | The pluggable backend where artifact bytes actually live. |

## Getting started

```yaml
dependencies:
  omnystore: ^1.0.0
```

### Embedded — no server

```dart
import 'package:omnystore/omnystore.dart';

final store = OmnyStore(
  repositories: MemoryRepositories(),
  storage: MemoryObjectStorage(),
);

final org = await store.createOrganization(name: 'acme');
final project = await store.createProject(
  organizationId: org.id, name: 'agent',
);
final package = await store.createPackage(
  projectId: project.id, name: 'omnyagent',
);

final release = await store.publishRelease(
  packageReference: package.id,
  version: Version.parse('1.0.0'),
);
await store.attachAsset(
  releaseId: release.id,
  name: 'omnyagent-linux-x64.tar.gz',
  data: Stream.value(bytes),
  platform: 'linux-x64',
);
```

### As a server

```sh
dart pub global activate omnystore
omnystore server --data /var/lib/omnystore --port 8080

curl localhost:8080/health
curl localhost:8080/api/v1/packages/omnyagent/releases/latest
curl -L -o agent.tar.gz localhost:8080/api/v1/assets/<id>/download
```

Locking it down before it is publicly reachable:

```sh
omnystore server --data /var/lib/omnystore \
  --publish-token "$PUBLISH_TOKEN" \
  --node-token "$NODE_TOKEN" \
  --cors 'https://releases.example.com' \
  --tls-cert /etc/tls/fullchain.pem --tls-key /etc/tls/privkey.pem
```

Reads stay open with a publish token set — that is the point of a distribution
platform — while publishing and node registration require credentials.

### From an application

```dart
import 'package:omnystore/omnystore_client.dart';

final client = OmnyStoreClient(baseUrl: 'https://store.example.com');

final update = await client.checkForUpdates(
  packageReference: 'omnyagent',
  currentVersion: Version.parse(myVersion),
  channel: ReleaseChannel.beta,
  platform: 'macos-arm64',
);

if (update.isInstallable) {
  await DownloadManager().downloadAsset(
    asset: update.asset!,
    url: client.assetDownloadUrl(update.asset!.id),
    destination: '/opt/omnyagent',
    onProgress: (p) => stdout.write('\r${p.percent}%'),
  );
}
```

`isInstallable` rather than `updateAvailable`: an update that ships no artifact
for this platform is a real state, and a download button gated on the wrong one
offers a dead end.

## Channels

A release's channel is **derived from its version**, so the two can never
disagree:

| Version | Channel |
|---|---|
| `1.0.0` | release |
| `2.0.0+build5` | release — build metadata never changes the channel |
| `1.1.0-beta.2` | beta |
| `1.1.0-dev.3` | dev |
| `1.1.0-rc.1` | dev — an unrecognised pre-release is the *least* stable thing it could be |

Queries are **inclusive downward in stability**. A `beta` subscriber accepts
beta and stable but never dev; a `release` subscriber accepts only stable:

```dart
await store.latestChannel('omnyagent', ReleaseChannel.beta);
// the newest of {beta, release} — so a newer stable release reaches
// beta subscribers without being republished

await store.latestChannel('omnyagent', ReleaseChannel.beta, exact: true);
// strictly the newest beta
```

Promotion publishes a new version carrying the target channel's tag and copies
the artifacts across, leaving the pre-release in place for anyone still on it:

```dart
await store.promoteRelease(betaRelease.id, ReleaseChannel.release);
// 1.2.0-beta.3 → 1.2.0
```

## Storage backends

| Backend | Bytes live in | Presigned URLs | Download path |
|---|---|---|---|
| `MemoryObjectStorage` | the heap | no | through the server |
| `LocalObjectStorage` | a directory | no | through the server |
| `S3ObjectStorage` | an S3 bucket | yes | client → bucket |
| `GcsObjectStorage` | a GCS bucket | with a service-account key | client → bucket |

```dart
S3ObjectStorage(
  bucket: 'acme-releases',
  region: 'eu-west-1',
  credentials: EnvironmentAwsCredentialsProvider(Platform.environment),
);

GcsObjectStorage(
  bucket: 'acme-releases',
  credentials: GcpServiceAccountCredentials.fromJsonString(
    File('service-account.json').readAsStringSync(),
  ),
);
```

With presigning, the hub answers a download with a `302` and never sees the
artifact — which is what stops the registry's bandwidth from becoming the
distribution platform's ceiling. Everything above the storage layer is
unchanged either way.

Implementing your own is five rules and one small interface — see
[`example/storage/custom_storage_backend.dart`](example/storage/custom_storage_backend.dart).

## Hub and nodes

A **hub** is the discovery point. **Nodes** hold their organizations' releases
and dial the hub outbound over a WebSocket, so a node can sit behind NAT, on a
private network, or in a different cloud, and still be part of a public
registry.

```sh
# The hub — also a provider, so no separate node is needed beside it.
omnystore server --data /var/lib/omnystore --node-token "$NODE_TOKEN"

# A node serving two organizations.
omnystore node \
  --hub wss://store.example.com/_node \
  --id node-eu --token "$NODE_TOKEN" \
  --org acme --org globex \
  --label region=eu --priority 10 \
  --data /var/lib/omnystore-node
```

Organizations and nodes are **many to many**: one organization's releases may
live on several nodes, and one node may serve several organizations.

The routing rules, in one place:

- **Writes follow ownership.** Creating a project goes to whichever provider
  holds its organization; publishing a release goes to whichever holds its
  package. A write never fans out, so ids stay unique.
- **Reads by id fan out**, first hit wins, and the answer is cached.
- **Listings aggregate** across every provider and deduplicate by *natural* key
  (`acme/agent/omnyagent`) rather than by id — because each provider mints its
  own ids, so replication stays invisible to clients.
- **Downloads prefer a redirect**, falling back to streaming.

Retiring a node is `omnystore node ... ` then `drain()`: new placements stop
while downloads already in flight finish.

## CLI

```text
omnystore server         Run the REST API server and the node endpoint
omnystore node           Run a storage node against a hub

omnystore org            create · list · delete
omnystore project        create · list · delete
omnystore package        create · list · delete
omnystore release        publish · list · latest · promote · yank · delete
omnystore asset          upload · list · delete
omnystore download       Fetch an artifact, verified
omnystore check-update   Exit 0 if current, 10 if an update exists
omnystore providers      Show the hub and its nodes
```

Every command works against a remote server (`--server`, `$OMNYSTORE_URL`) or a
local directory (`--data`, `$OMNYSTORE_DATA`) — the same code path drives both,
so a workflow developed locally runs unchanged against production. `--json`
makes every command machine-readable.

```sh
omnystore release publish --package omnyagent --version 1.4.0 \
  --notes @CHANGELOG.md \
  --asset build/omnyagent-linux-x64.tar.gz:linux-x64 \
  --asset build/omnyagent-macos-arm64.tar.gz:macos-arm64

omnystore release latest --package omnyagent --channel beta
omnystore download --package omnyagent --platform linux-x64 -o /opt
```

See [doc/cli.md](doc/cli.md) for the full reference.

## Architecture

```text
  CLI          Client SDK        REST API (OmnyHub)
   └──────────────┴──────────────────┘
                  │
          ┌───────┴────────┐
          │  OmnyStoreApi  │   one interface, three implementations
          └───────┬────────┘
       ┌──────────┼─────────────┐
  OmnyStore   OmnyStoreHub   OmnyStoreClient
  (local)     (federating)   (remote, web-safe)
       │           │
       │      ProviderRegistry ──► RemoteNodeStoreProvider ──► node
       │
  ┌────┴────────────────────┐
  │ StoreRepositories       │  metadata: memory, JSON files, your adapter
  │ ObjectStorage           │  bytes: memory, local, S3, GCS, yours
  └─────────────────────────┘
```

Clean architecture throughout: `abstract interface class` ports, dependencies
injected at construction, no global state anywhere. Business rules — name
validation, referential integrity, release immutability, cascade deletes — live
in the service layer, so they hold identically whichever adapter is plugged in.

See [doc/architecture.md](doc/architecture.md).

## Documentation

| Document | What it covers |
|---|---|
| [doc/architecture.md](doc/architecture.md) | Layers, ports, the shared `OmnyStoreApi`, and why each seam is where it is |
| [doc/api.md](doc/api.md) | Every REST endpoint, request and response shape, and the error envelope |
| [doc/cli.md](doc/cli.md) | Every command, flag, environment variable and exit code |
| [doc/client.md](doc/client.md) | The client SDK, including browser use and error handling |
| [doc/federation.md](doc/federation.md) | Hub/Node: routing, placement, replication, the control protocol |
| [doc/storage.md](doc/storage.md) | The storage backends, their trade-offs, and writing your own |
| [doc/workflows.md](doc/workflows.md) | Release and update workflows end to end, with CI recipes |
| [example/](example/) | Twenty runnable examples |

## Testing

```sh
dart test
dart test --tags server     # only the tests that bind a real port
```

The in-memory adapters are not mocks — they implement the same contracts as the
production ones, and the storage contract suite runs against every backend. With
an injected `Clock` and `IdGenerator` there is no wall clock and no randomness,
so assertions are exact:

```dart
final store = OmnyStore(
  repositories: MemoryRepositories(),
  storage: MemoryObjectStorage(),
  clock: FixedClock(),
  idGenerator: SequentialIdGenerator(),
);
```

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/OmnyGrid/omnystore).

Every change should keep `dart analyze --fatal-infos --fatal-warnings`,
`dart format` and `dart test` clean; new behaviour needs a test.

## Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
