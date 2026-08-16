# REST API reference

Base path `/api/v1`. `GET /health` is deliberately **unversioned** — a load
balancer's probe should not need updating when the API version changes.

Every response is JSON. Successful reads and writes return their payload under
`result`; listings add a `count`. Deletes return `204` with no body.

```json
{ "result": { "id": "org-…", "name": "acme" } }
{ "result": [ … ], "count": 3 }
```

## Errors

Every failure renders the same envelope, with the HTTP status the failure
carries:

```json
{
  "error": {
    "code": "release_not_found",
    "message": "Release not found: omnyagent@beta",
    "details": { }
  }
}
```

`code` is the wire contract — key retry and reporting decisions off it, not off
`message`, which is free to change. `details` is present only for failures whose
fields matter as values; a checksum mismatch carries `expected` and `actual` so
a client can compare digests rather than parse a sentence.

`OmnyStoreClient` reads this envelope back and rethrows the original exception
type, so `on ReleaseNotFoundException` works across the network.

| Code | Status | Meaning |
|---|---|---|
| `validation_error` | 400 | A value failed validation |
| `invalid_json` | 400 | The body was not the expected JSON shape |
| `unauthorized` | 401 | Missing or invalid credentials |
| `forbidden` | 403 | Authenticated, but not permitted |
| `organization_not_found` | 404 | |
| `project_not_found` | 404 | |
| `package_not_found` | 404 | |
| `release_not_found` | 404 | Includes "no release on that channel" |
| `asset_not_found` | 404 | |
| `conflict` | 409 | A unique key is taken; a version is already published |
| `checksum_mismatch` | 422 | Uploaded bytes did not match the declared digest |
| `not_implemented` / `unsupported` | 501 | The configured backend cannot do this |
| `storage_error` | 500 | The object-storage backend failed |
| `download_failed` | 502 | A download could not be completed |
| `timeout` | 504 | An operation exceeded its deadline |

## Health

```http
GET /health
```

```json
{ "status": "ok", "version": "1.0.0", "api": "v1", "providers": 3 }
```

Never requires authentication: a probe carries no credentials, and a probe that
`401`s reads as an outage.

## Organizations

```http
GET    /api/v1/organizations
POST   /api/v1/organizations
GET    /api/v1/organizations/{id-or-name}
PUT    /api/v1/organizations/{id}
DELETE /api/v1/organizations/{id}?force=true
GET    /api/v1/organizations/{id}/projects
GET    /api/v1/organizations/{id}/packages
```

The single-resource route accepts an **id or a name**, because requiring an
opaque id for the common single-tenant case makes the API unusable by hand.

```http
POST /api/v1/organizations
{ "name": "acme", "displayName": "Acme Corporation", "website": "https://acme.example.com" }
```

`name` is validated: 1–100 characters of lower-case letters, digits and single
`.`, `_` or `-` separators. It is a routing key in a federated deployment and
appears in URLs and storage keys, so it cannot be changed after creation —
`PUT` updates `displayName`, `description`, `website` and `metadata` only.

`DELETE` without `force=true` on a populated organization is a `409`, rather
than silently destroying every release it owns.

## Projects

```http
GET    /api/v1/projects?organizationId=…
POST   /api/v1/projects
GET    /api/v1/projects/{id}
PUT    /api/v1/projects/{id}
DELETE /api/v1/projects/{id}?force=true
GET    /api/v1/projects/{id}/packages
```

```http
POST /api/v1/projects
{ "organizationId": "org-…", "name": "agent", "repository": "https://github.com/acme/agent" }
```

## Packages

```http
GET    /api/v1/packages?projectId=…&organizationId=…
POST   /api/v1/packages
GET    /api/v1/packages/{id-or-name}
PUT    /api/v1/packages/{id}
DELETE /api/v1/packages/{id}?force=true
```

```http
POST /api/v1/packages
{
  "projectId": "proj-…",
  "name": "omnyagent",
  "defaultChannel": "release",
  "platforms": ["linux-x64", "macos-arm64"]
}
```

`defaultChannel` is what a client is offered when it does not name one. It
defaults to `release`, so a caller who has not opted in to pre-releases is never
handed one.

A bare name that matches packages in more than one project is a `400`
`validation_error`, never resolved by picking one — publishing a release into
the wrong project because two of them named a package `agent` is exactly the
failure that must not happen silently.

## Releases

```http
GET    /api/v1/packages/{id}/releases
POST   /api/v1/packages/{id}/releases
GET    /api/v1/packages/{id}/releases/latest
GET    /api/v1/packages/{id}/releases/{version}
GET    /api/v1/releases/{id}
PUT    /api/v1/releases/{id}
DELETE /api/v1/releases/{id}
POST   /api/v1/releases/{id}/promote
```

### Publishing

```http
POST /api/v1/packages/omnyagent/releases
{
  "version": "1.2.0-beta.3",
  "notes": "Fixes a crash on startup.",
  "tag": "v1.2.0-beta.3",
  "draft": false
}
```

The channel is **derived** from the version's pre-release tag — `beta` here —
so the two can never disagree. Re-publishing an existing version is a `409`:
releases are immutable, because a client that already downloaded one has no way
to learn the bytes changed underneath it.

### Listing

```http
GET /api/v1/packages/omnyagent/releases
      ?channel=beta          exactly that channel
      &acceptedBy=beta       that channel and every more stable one
      &includeDrafts=true
      &includeYanked=true
      &limit=20&offset=0
```

Newest first. Drafts, yanked and unpublished releases are excluded by default —
the client's view. Sorting happens before paging, so `offset` walks a stable
sequence.

### Latest

```http
GET /api/v1/packages/omnyagent/releases/latest              newest on any channel
GET /api/v1/packages/omnyagent/releases/latest?channel=beta beta + stable
GET /api/v1/packages/omnyagent/releases/latest?channel=beta&exact=true  beta only
```

`404` `release_not_found` when the package has nothing offerable there — an
empty answer for a real question, not an error in the request.

### Updating and yanking

```http
PUT /api/v1/releases/{id}
{ "yanked": true, "yankedReason": "Corrupts the config file on first run." }
```

A yanked release stays downloadable — clients that pinned it must keep working
— but is excluded from every `latest*` query and never offered as an update.
Prefer it to `DELETE`, which breaks those clients. Un-yanking clears the reason.

Publishing a draft is `{"draft": false}`; that is the moment `publishedAt` is
stamped.

### Promotion

```http
POST /api/v1/releases/{id}/promote
{ "channel": "release", "notes": "Promoted after two weeks of testing." }
```

Publishes a new version carrying the target channel's tag (`1.2.0-beta.3` →
`1.2.0`), copies the artifacts across, and leaves the original in place.
Promotion only moves *towards* stability; the reverse is a `400`.

## Assets

```http
GET    /api/v1/releases/{id}/assets
POST   /api/v1/releases/{id}/assets?name=…
GET    /api/v1/assets/{id}
DELETE /api/v1/assets/{id}
GET    /api/v1/assets/{id}/download
```

### Uploading

```http
POST /api/v1/releases/{id}/assets
     ?name=omnyagent-linux-x64.tar.gz
     &platform=linux-x64
     &kind=archive
     &sha256=<expected digest>
Content-Type: application/gzip
Content-Length: 4194304

<raw bytes>
```

The body is the artifact itself — not multipart — so it streams straight into
object storage without being buffered. The SHA-256 and size are computed as the
bytes pass; when `sha256` is supplied they are verified against it and **nothing
is stored** on mismatch (`422`).

`platform` is what lets the update service answer "is there an update *for
me*", so set it on every platform-specific artifact.

```sh
curl -X POST "$URL/api/v1/releases/$ID/assets?name=agent.tar.gz&platform=linux-x64" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/gzip' \
  --data-binary @build/agent.tar.gz
```

### Downloading

```http
GET /api/v1/assets/{id}/download
```

Answers one of two ways, depending on the provider holding the bytes:

- **`302`** to a presigned bucket URL or the node's own endpoint. No artifact
  byte crosses the registry.
- **`200`** streaming the bytes through the server.

Either way the response carries:

| Header | Purpose |
|---|---|
| `content-disposition` | Saves under the artifact's own name |
| `accept-ranges: bytes` | Tells a download manager it may resume |
| `x-omnystore-sha256` | The recorded digest, for verification |

A `Range` request is always served **by the registry**, never redirected — a
presigned URL covers the whole object, so redirecting would silently ignore the
range a resuming client asked for:

```http
GET /api/v1/assets/{id}/download
Range: bytes=4194304-

206 Partial Content
Content-Range: bytes 4194304-8388607/8388608
```

A malformed or multi-range header is *ignored* and the whole representation
served, as RFC 9110 requires.

## Updates

```http
GET /api/v1/packages/{id}/updates?version=1.0.0&channel=beta&platform=macos-arm64
```

```json
{
  "result": {
    "currentVersion": "1.0.0",
    "latestVersion": "1.1.0",
    "updateAvailable": true,
    "channel": "release",
    "packageName": "omnyagent",
    "notes": "Fixes a crash on startup.",
    "release": { … },
    "asset": { … }
  }
}
```

`version` is required (`400` without it). `channel` defaults to the package's
own `defaultChannel`. The whole release and the matching asset are included, so
a client that decides to update needs no further round-trips.

`updateAvailable` is `false` — not an error — when the client is current *or
ahead*; a developer on a local build is never offered a downgrade. When
`release` is present but `asset` is `null`, an update exists but ships nothing
this platform can install: gate a download button on that distinction.

## Downloads

```http
GET /api/v1/packages/{id}/downloads?limit=50&from=…&to=…
GET /api/v1/packages/{id}/downloads/stats?from=…&to=…
```

`from` is inclusive, `to` exclusive, both ISO-8601.

```json
{
  "result": {
    "total": 178,
    "byVersion": { "1.0.0": 52, "1.1.0": 126 },
    "byAsset": { "asset-…": 135 },
    "from": "2026-03-01T00:00:00.000Z",
    "to": null
  }
}
```

## Providers

```http
GET /api/v1/providers?organization=acme
```

The hub and every connected node, with the organizations each serves, its data
plane, its liveness and its reported capacity. A single-process store reports
exactly one provider — itself.

## Authentication

Optional, and asymmetric by design: **reads stay open**, because serving
downloads and update checks to anonymous clients is the point of a distribution
platform. Writes and node registration are what get guarded.

```http
Authorization: Bearer <token>
```

```dart
OmnyStoreServer(
  store: hub,
  requireAuthForWrites: true,
  writeRoles: const {'publisher'},
  writeAuthenticator: BearerTokenAuthenticator({
    token: Principal(id: 'ci', roles: const {'publisher'}),
  }),
  nodeAuthenticator: BearerTokenAuthenticator({nodeToken: nodePrincipal}),
);
```

A hub-wide `Authorizer` cannot express this: it runs on *every* request, so a
role requirement there would also gate the anonymous reads. `writeRoles` applies
to the mutating routes only — no principal is a `401`, a principal without the
role is a `403`.

## CORS

```dart
OmnyStoreServer(store: store, allowedOrigins: ['https://releases.example.com']);
OmnyStoreServer(store: store, allowAnyOrigin: true);
```

Mounted in OmnyHub's *outer* middleware, so preflights are answered before
authentication and a browser can read error responses rather than seeing an
opaque network failure. `content-disposition`, `content-range` and
`x-omnystore-sha256` are exposed — without that last one the digest is on the
wire but invisible to JavaScript, and a browser-side downloader could not verify
what it fetched.
