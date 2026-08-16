# Storage

Two storage layers, deliberately separate:

- **Metadata** — organizations, releases, asset records. Small, queried
  constantly. Behind seven repository interfaces.
- **Artifact bytes** — installers, tarballs. Gigabytes, written once, read many
  times. Behind one `ObjectStorage` interface.

Everything above them deals in metadata and never touches an artifact byte,
which is what lets one deployment keep artifacts in a directory and another in
S3 with identical business logic.

## Object storage

| Backend | Bytes live in | Presigned URLs | Download path |
|---|---|---|---|
| `MemoryObjectStorage` | the heap | no | through the server |
| `LocalObjectStorage` | a directory | no | through the server |
| `S3ObjectStorage` | an S3 bucket | yes | client → bucket |
| `GcsObjectStorage` | a GCS bucket | with a service-account key | client → bucket |

**Presigning is the decision that matters.** With it, the hub answers a download
with a `302` and never sees the artifact; without it, every byte crosses the
registry and its bandwidth becomes the distribution platform's ceiling. Nothing
else in the system changes either way — which is exactly why the choice can be
deferred and revisited.

### Layout

Keys are hierarchical and human-readable:

```text
orgs/{organization}/packages/{package}/{version}/{filename}
```

That is not cosmetic. When something goes wrong the operator is looking at a
bucket listing or a directory tree, and a flat namespace of opaque ids gives
them nothing to work with. The prefix structure also makes "delete this
release's artifacts" a prefix delete, and makes per-organization lifecycle rules
and cost attribution expressible in a cloud console.

`StorageKeys.requireSafe` rejects any key that could escape its prefix — `..`
segments, absolute paths, backslashes — on **every** entry point of **every**
backend, so no backend has to remember to do it.

### Local directory

```dart
LocalObjectStorage('/var/lib/omnystore/objects');
```

The right starting point for a self-hosted single server.

**Durability.** Uploads are written to a temporary file in the same directory
and renamed into place only after the last byte lands and the checksum
verifies. `rename` within one filesystem is atomic, so a reader never observes a
half-written artifact and a crash mid-upload leaves a stray temp file rather
than a corrupt release.

```dart
// A long-lived server should sweep at startup and periodically; a crash
// between "open temp file" and "rename" leaves a partial behind, and nothing
// reads them but they consume disk forever.
await storage.sweepIncomplete(olderThan: const Duration(hours: 24));
```

**Sidecars.** The SHA-256 and content type are recorded in a
`.omnystore-meta.json` beside each object, because a filesystem has nowhere else
to put them. A missing or corrupt sidecar is not an error — `head` then reports
a `null` checksum, exactly as an S3 object uploaded by another tool would, and
the artifact stays downloadable.

Empty directories are pruned after a delete, so a store that has had everything
removed does not leave a skeleton of folders.

### AWS S3

```dart
S3ObjectStorage(
  bucket: 'acme-releases',
  region: 'eu-west-1',
  credentials: EnvironmentAwsCredentialsProvider(Platform.environment),
  prefix: 'registry',                    // one bucket, several registries
  storageClass: 'INTELLIGENT_TIERING',
  serverSideEncryption: 'aws:kms',
);
```

SigV4 is implemented directly rather than pulled from an SDK: the signature is a
well-specified ~80 lines of hashing, and an AWS SDK dependency would drag a
large transitive tree into a package whose point is to stay embeddable. It is
verified against **AWS's own published test vectors** in
`test/unit/storage/cloud_credentials_test.dart`.

Credentials come from a provider, called before every signature — because the
credentials a long-running registry signs with are usually temporary:

| Provider | Use |
|---|---|
| `StaticAwsCredentialsProvider` | A fixed key pair |
| `EnvironmentAwsCredentialsProvider` | `AWS_ACCESS_KEY_ID`, … |
| `RefreshingAwsCredentialsProvider` | An instance profile, an assumed role, STS |

`RefreshingAwsCredentialsProvider` caches until shortly before expiry and
collapses concurrent refreshes onto one fetch, so a burst of parallel uploads
does not become a burst of STS calls.

**Uploads are single-part**, capped at S3's 5 GB limit. Larger artifacts need
the multipart API; `put` fails cleanly with a `StorageException` rather than
truncating, so the limit is visible rather than silent.

### S3-compatible services

MinIO, Cloudflare R2, Backblaze B2, Ceph, DigitalOcean Spaces:

```dart
S3ObjectStorage(
  bucket: 'releases',
  region: 'us-east-1',           // conventional when the service ignores it
  endpoint: Uri.parse('https://minio.internal:9000'),
  usePathStyle: true,            // most self-hosted services need this
  credentials: StaticAwsCredentialsProvider.of(
    accessKeyId: '…', secretAccessKey: '…',
  ),
);
```

### Google Cloud Storage

```dart
GcsObjectStorage(
  bucket: 'acme-releases',
  credentials: GcpServiceAccountCredentials.fromJsonString(
    File('service-account.json').readAsStringSync(),
  ),
);
```

**Signed downloads depend on the credentials**, and this is the one place the
choice changes behaviour:

| Credentials | `supportsPresignedUrls` | Downloads |
|---|---|---|
| `GcpServiceAccountCredentials` | `true` | redirected to the bucket |
| `GcpMetadataServerCredentials` | `false` | streamed through the hub |
| `GcpStaticCredentials` | `false` | streamed through the hub |

A service-account key holds an RSA private key, so V4 URLs are signed locally.
Ambient credentials on GCE/GKE/Cloud Run have no key to sign with, so
`presignedUrl` returns `null` and the hub streams instead — correct, just not
free. Returning `null` rather than throwing is the contract: it means "stream it
instead", not "this failed".

Access tokens use the standard JWT bearer grant: a short assertion signed with
the account's key, exchanged at Google's token endpoint, cached until shortly
before expiry.

### Choosing

**A single self-hosted server** — `LocalObjectStorage`. One directory to back
up, no credentials to manage, artifacts you can inspect with `ls`.

**Public downloads at any volume** — S3 or GCS with a signing credential. The
registry stops carrying artifact bandwidth.

**Running on Google Cloud with no key file** — `GcpMetadataServerCredentials`,
accepting that downloads stream through the hub. Or supply a service-account key
if the bandwidth matters more than the key management.

**Tests** — `MemoryObjectStorage`. Bounded by default (256 MiB), because an
unbounded one in a long-lived process is a silent leak.

## Writing your own backend

Five rules. Honour them and the registry, the channels, the update service and
the federation all work unchanged.

1. **`put` streams** — never buffer the whole object — computes the SHA-256 of
   what it actually wrote, and verifies it against `expectedSha256`, leaving
   nothing behind on mismatch.
2. **`get` throws `AssetNotFoundException`** for a missing key rather than
   returning an empty stream, and honours `ByteRange` when it can.
3. **`delete` is idempotent.** Deleting what is not there is a success.
4. **`presignedUrl` returns `null`** when the backend cannot issue one.
5. **Every entry point validates the key** with `StorageKeys.requireSafe`.

```dart
class AzureBlobStorage implements ObjectStorage {
  @override
  String get id => 'azure:$container';

  @override
  bool get supportsPresignedUrls => true;   // SAS tokens

  @override
  Future<StoredObject> put(String key, Stream<List<int>> data, { … }) async {
    StorageKeys.requireSafe(key);
    late ChecksumResult checksum;
    final hashed = ChecksumStream.transform(data, (r) => checksum = r);
    await _upload(key, hashed);
    if (expectedSha256 != null &&
        !Checksums.matches(expectedSha256, checksum.sha256)) {
      await delete(key);
      throw ChecksumMismatchException(
        expected: expectedSha256, actual: checksum.sha256,
      );
    }
    return StoredObject(key: key, sizeBytes: checksum.sizeBytes, sha256: checksum.sha256);
  }
  …
}
```

`ChecksumStream.transform` hashes bytes as they flow through, so the digest
costs nothing extra — no second pass, no buffering.

The contract suite in `test/unit/storage/object_storage_test.dart` is written
once and run against every backend. Add yours to it:

```dart
objectStorageContract('AzureBlobStorage', () async => AzureBlobStorage(…));
```

Wrapping an existing backend — for caching, metrics or tiering — is often
simpler than implementing from scratch; see
[`example/storage/custom_storage_backend.dart`](../example/storage/custom_storage_backend.dart).

## Metadata repositories

Seven interfaces bundled as a `StoreRepositories`, swapped together because an
adapter implements all of them against one backend. Mixing a SQL release
repository with an in-memory package repository would give you a store that
half-survives a restart.

| Adapter | Use |
|---|---|
| `MemoryRepositories` | Tests, and an embedded registry rebuilt at startup |
| `JsonFileRepositories` | A self-hosted server: readable, diffable, backup-able |

```dart
final repositories = await JsonFileRepositories.open('/var/lib/omnystore/metadata');
```

`JsonFileRepositories` is **write-through**: a mutation does not return until
the bytes are on disk, and writes go to a temporary file renamed into place, so
a crash mid-write leaves the previous version intact.

Know its limits before choosing it. Rewriting a whole collection per mutation is
`O(n)` in that collection's size — fine for the thousands of releases a
self-hosted registry holds, wrong for millions of download records (cap those
with `maxDownloadRecords`). It also assumes a **single writer**: two processes
sharing one directory will clobber each other.

A corrupt file makes `open` fail rather than starting with an empty catalogue.
That is deliberate: to every client, an empty registry is indistinguishable from
every release having been deleted, and they would act on it.

### Writing a repository adapter

Implement the seven interfaces and bundle them:

```dart
class PostgresRepositories extends StoreRepositories {
  PostgresRepositories(Connection db) : super(
    organizations: PostgresOrganizationRepository(db),
    …
  );
}
```

**Repositories are stores, not validators.** They enforce their own uniqueness
invariants and return `null` on a miss; business rules live in `OmnyStore`, so
they hold identically whichever adapter is plugged in.

`ReleaseQuery` is passed *into* the repository rather than applied by the
caller, so a SQL adapter can push the filter into the query instead of loading
every release of a package into memory to discard most of it. `ReleaseQuery.apply`
defines the semantics your adapter must match.

`JsonFileRepositories` shows a useful trick: it reuses the memory
implementations through a change hook rather than reimplementing every query, so
there is one implementation of `latest`, of paging, of the channel filter — and
no chance of the two drifting.
