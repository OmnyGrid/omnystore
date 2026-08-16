# Architecture

OmnyStore is a layered system with one interface at its centre. Read this first
if you are going to extend it; the rest of the docs assume the vocabulary here.

## The shape

```text
   CLI              Client SDK             REST API (OmnyHub services)
    │                    │                          │
    └────────────────────┴──────────────────────────┘
                         │
                 ┌───────┴────────┐
                 │  OmnyStoreApi  │   the contract everything speaks
                 └───────┬────────┘
          ┌──────────────┼──────────────────┐
     OmnyStore      OmnyStoreHub       OmnyStoreClient
     (local)        (federating)       (remote, web-safe)
          │              │
          │         ProviderRegistry
          │              │
          │         RemoteNodeStoreProvider ──ws──► OmnyStoreNode ─► OmnyStore
          │
    ┌─────┴──────────────────────────┐
    │ StoreRepositories   (metadata) │  memory · JSON files · yours
    │ ObjectStorage       (bytes)    │  memory · local · S3 · GCS · yours
    └────────────────────────────────┘
```

## One interface, three implementations

`OmnyStoreApi` is the whole operation surface: organizations, projects,
packages, releases, assets, downloads, updates, providers. Three classes
implement it.

| Implementation | Where the data is | Typical use |
|---|---|---|
| `OmnyStore` | local repositories + object storage | embedded, or inside a node |
| `OmnyStoreHub` | federated across providers | the discovery point |
| `OmnyStoreClient` | a remote server, over REST | apps, CI, the CLI, browsers |

This is the load-bearing decision in the design. Because the REST service, the
CLI and the update checker are all written against the *interface*, none of
them contains a branch for "embedded vs. remote vs. federated". A release
workflow written once runs:

- in a test, against in-memory adapters;
- in a build script, against a directory;
- in production, against a hub with a dozen nodes;

by changing the construction and nothing else. It is also what makes
`StoreApiService` mountable over a hub or over a plain store without knowing
which it has.

**Errors are part of the contract.** `OmnyStoreClient` reconstructs the
server's exception type from the error envelope, and the node RPC layer does
the same across the control channel — so `on ReleaseNotFoundException` behaves
identically in-process, over HTTP, and across a WebSocket to another
datacentre. Without that, moving code between the three would silently change
its error handling.

## Layers

```text
lib/src/
  models/         immutable value objects, JSON-serialisable, value equality
  channels/       ReleaseChannel and the stability ordering
  repositories/   metadata ports + memory and JSON-file adapters
  storage/        ObjectStorage port + memory, local, S3, GCS adapters
  services/       OmnyStoreApi, OmnyStore, download targets
  updates/        UpdateResolver (pure rules) and UpdateChecker (client-side)
  downloads/      DownloadManager: streaming, resume, verification
  hub/            OmnyStoreHub federation, StoreNodeGateway
  nodes/          StoreProvider, ProviderRegistry, the RPC protocol, the node
  api/            REST service and server, error rendering
  client/         the web-safe client SDK
  auth/           AuthProvider for clients
  cli/            the command set
  exceptions/     the sealed failure hierarchy and stable error codes
  utils/          checksums, JSON helpers, name validation, version helpers
```

Dependencies point inwards. `models` and `channels` depend on nothing but
`pub_semver`; `services` depends on ports, never on adapters; `api`, `client`
and `cli` are all consumers of `services`.

## Ports and adapters

Everything replaceable is an `abstract interface class`:

| Port | Adapters shipped | What it abstracts |
|---|---|---|
| `OrganizationRepository`, … (7) | memory, JSON files | metadata persistence |
| `ObjectStorage` | memory, local, S3, GCS | where artifact bytes live |
| `StoreProvider` | local, remote node | who can serve an organization |
| `AuthProvider` | anonymous, token, refreshing, composite | client credentials |
| `AwsCredentialsProvider` | static, environment, refreshing | AWS credentials |
| `GcpCredentialsProvider` | service account, metadata server, static | GCP credentials |
| `Clock`, `IdGenerator`, `Logger` | from OmnyHub | time, ids, logging |

Ports are asynchronous even where the bundled adapter answers synchronously:
the contract has to fit a SQL or cloud backend without any caller changing, and
a synchronous signature would make that impossible to add later.

**Repositories are stores, not validators.** They enforce their own uniqueness
invariants and return `null` on a miss. Business rules — name validation,
referential integrity, release immutability, cascade deletes — live in
`OmnyStore`, so they hold identically whichever adapter is plugged in. A
repository that also validated would let two adapters drift apart on what is
legal.

## No global state

`Clock`, `IdGenerator` and `Logger` are constructor parameters with sensible
defaults. Nothing reads a singleton, so:

- tests fix time and get deterministic ids;
- two stores in one process share nothing;
- embedding the library never writes to stdout unless you ask it to.

```dart
final store = OmnyStore(
  repositories: MemoryRepositories(),
  storage: MemoryObjectStorage(),
  clock: FixedClock(DateTime.utc(2026)),
  idGenerator: SequentialIdGenerator(),
  logger: RecordingLogger(),
);
```

### Ids are provider-scoped

`OmnyStore` defaults its id generator to `ScopedIdGenerator(RandomIdGenerator(),
providerId)`, producing `rel-node-eu-1k3f9x`. Entity ids have to be unique
across a whole *federation*, not just within one store: the hub caches which
provider owns which id, and two nodes independently minting the same id would
route a write to the wrong machine. Independent processes cannot coordinate a
counter, so the scope is what keeps them apart — and it doubles as a diagnostic,
since an id in a log says which node created the record.

Aggregated listings additionally deduplicate on *natural* keys
(`acme/agent/omnyagent`) rather than ids, so a replicated record collapses to
one row even though its copies carry different ids.

## The two planes

Registry operations are small JSON round-trips. Artifact bytes are gigabytes.
Treating them the same would be a mistake in either direction, so they are
separated:

**Control plane** — organizations, releases, metadata. Over HTTP for clients,
over OmnyHub's node WebSocket for nodes. Small, chatty, latency-sensitive.

**Data plane** — artifact bytes. Chosen per provider:

| Mode | When | Cost to the registry |
|---|---|---|
| `presigned` | the backend can issue URLs (S3, GCS) | one small response |
| `direct` | the node is reachable at a public URL | one redirect |
| `relay` | the node is behind NAT | the whole artifact, twice |

`relay` chunks bytes over the control channel, base64-framed. It is correct
everywhere and the slowest of the three; it exists so that a fully firewalled
node is still a usable provider. `OmnyStoreNode` picks the best mode its
configuration allows and advertises it in its descriptor.

## Federation routing

`OmnyStoreHub` routes by four rules. They are stated once, here, because
getting them consistent *is* the job:

1. **Writes follow ownership.** Creating a project goes to whichever provider
   holds its organization; publishing a release goes to whichever holds its
   package. Only `createOrganization` has no parent, and it goes to
   `ProviderRegistry.primaryFor`. A write never fans out, so ids stay unique
   and unambiguous.
2. **Reads by id fan out**, first hit wins, cached in a bounded id→provider
   map. A stale entry is corrected the moment its provider answers `null`.
3. **Listings aggregate** across every provider serving the organization,
   deduplicated by natural key — which is what makes sharding and replication
   both work without the client knowing which it is looking at.
4. **Downloads prefer a redirect.** If the holding provider can issue a URL, the
   client goes straight there.

A provider failing a read degrades the answer rather than the request: one
unreachable node must not break a federation-wide listing.

## Error handling

`OmnyStoreException` is a `sealed` hierarchy, so callers can switch over it
exhaustively without a catch-all that silently swallows a new failure type.
Every failure carries:

- a stable machine-readable `code` (see `ErrorCodes`) — the wire contract;
- a human-readable `message`;
- the `statusCode` the REST API answers with;
- optional structured `details` for failures whose fields matter as *values*
  (a checksum mismatch carries `expected` and `actual`, not just a sentence).

It deliberately does **not** extend OmnyHub's own `sealed HubException` — two
sealed hierarchies cannot be merged. The API layer translates into OmnyHub's
`AppException` seam instead, which is exactly what that seam is for.

## Why OmnyHub

Connectivity is [OmnyHub](https://pub.dev/packages/omnyhub): transports, TLS
(static or automatic Let's Encrypt), routing, middleware, CORS, authentication,
and the node control plane with registration, heartbeats and reconnection.

That means the REST API and the node endpoint share **one port**, one
certificate and one authentication configuration — so the whole platform
deploys as a single container with a single exposed port. It also means
OmnyStore mounts into an OmnyHub application you already run, as two more
services.

## Extending it

**A new storage backend** — implement `ObjectStorage`. Five rules, listed on
the interface and demonstrated in
[`example/storage/custom_storage_backend.dart`](../example/storage/custom_storage_backend.dart).
The contract test suite in `test/unit/storage/object_storage_test.dart` runs
against every backend; add yours to it.

**A new metadata backend** — implement the seven repository interfaces and
bundle them as a `StoreRepositories`. `JsonFileRepositories` shows the shape,
including how it reuses the memory implementations via a change hook rather
than reimplementing every query.

**A new provider kind** — implement `StoreProvider`: a `ProviderDescriptor`
plus an `OmnyStoreApi`. The hub cannot tell yours from a local store or a
remote node.

**Custom authentication** — an `Authenticator` on the server (OmnyHub's port)
and an `AuthProvider` on the client.
