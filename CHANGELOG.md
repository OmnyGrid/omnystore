## 1.0.0

- Initial version.

**Core SDK**

- Immutable, JSON-serialisable models with value equality: `Organization`,
  `Project`, `Package`, `Release`, `Asset`, `DownloadRecord`, `DownloadStats`,
  `AssetLocation`, `ProviderDescriptor`, `UpdateInfo`.
- `ReleaseChannel` (`dev` / `beta` / `release`) derived from a version's
  pre-release tag, with inclusive-downward stability ordering.
- `OmnyStore`: the full lifecycle — create, publish, attach, promote, yank,
  delete, download, record, check for updates — with injected `Clock`,
  `IdGenerator` and `Logger` and no global state.
- `OmnyStoreApi`: one contract implemented by the embedded store, the
  federating hub and the HTTP client, so code moves between them unchanged.
- Sealed `OmnyStoreException` hierarchy with stable error codes, structured
  details, and reconstruction from the wire.

**Storage**

- `ObjectStorage` port with four adapters: in-memory, local directory (atomic
  writes, checksum sidecars, incomplete-upload sweeping), AWS S3 (and any
  S3-compatible service) with SigV4 presigning, and Google Cloud Storage with
  V4 signing from a service-account key.
- Seven repository ports with in-memory and write-through JSON-file adapters.
- SHA-256 computed while streaming on every upload; verified on download.

**Hub and nodes**

- `OmnyStoreHub`: organization → provider routing, aggregation with
  natural-key deduplication, and explicit, verified, idempotent replication.
- `OmnyStoreNode`: a storage provider that dials a hub outbound, so it works
  behind NAT; serves several organizations, and an organization may be served
  by several nodes.
- Three data planes — presigned, direct redirect, and a chunked relay over the
  control channel — chosen from what each provider can do.
- Node admission policy and protocol-version checking.

**Server, client and CLI**

- REST API on OmnyHub: `/api/v1` plus an unversioned `/health`, CORS, ranged
  downloads with `206`, redirect-or-stream artifact serving, optional TLS, and
  the node endpoint — all on one port.
- `OmnyStoreClient`: web-compatible (no `dart:io`), rebuilding the server's
  typed exceptions from the error envelope.
- `UpdateChecker` with change-only polling; `DownloadManager` with resume,
  retry and mandatory checksum verification.
- `Platforms.current` reports this process's `os-arch` token, and the CLI's
  `download` and `check-update` default to it — so an artifact is fetched for
  the machine asking, and never for another architecture.
- `omnystore` CLI: server, node, org, project, package, release, asset,
  download, check-update and providers, against a remote server or a local
  directory, with `--json` output and meaningful exit codes.

**Documentation and tests**

- Twenty runnable examples, an architecture overview, and REST, CLI, client,
  federation, storage and workflow guides.
- 411 tests: unit, integration over real sockets, the federation protocol end
  to end, AWS's published SigV4 vectors, and real RSA signature verification.
