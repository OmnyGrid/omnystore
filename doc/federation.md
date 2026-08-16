# Hub and nodes

A **hub** is the discovery point. **Nodes** hold the metadata *and* the artifact
bytes for the organizations they serve, and dial the hub outbound over a
WebSocket — so a node can sit behind NAT, on a private network, or in a
different cloud, and still be part of a public registry.

```text
                        ┌─────────────── OmnyStoreHub ────────────────┐
   clients ──REST──►    │  routing table:  org → providers            │
                        │                                             │
                        │    acme   ─► node-eu, node-us               │
                        │    globex ─► node-eu                        │
                        │    *      ─► hub-local                      │
                        └──────────┬──────────────────────────────────┘
                                   │ outbound WebSocket (OmnyHub node plane)
                   ┌───────────────┼───────────────┐
                node-eu         node-us         hub-local
              (S3, eu-west-1)  (local disk)    (in-process)
```

**A hub can also be a provider**, so a small deployment is one process with no
separate node beside it. That is not a special case in the code: the hub's own
provider goes through the same `StoreProvider` interface a remote node does,
which is what keeps "hub with no nodes" and "hub with twelve nodes" exercising
the same routing logic.

## Organizations and nodes are many to many

One organization's releases may live on — or be replicated across — several
nodes, and one node may serve several organizations. Both directions are
ordinary.

Two sources decide who serves what, and they compose:

- **Node-declared.** A node advertises its organizations at registration. The
  common case: the operator knows what they are hosting.
- **Hub-bound.** `ProviderRegistry.bind(organization, providerId)` adds one from
  the hub side, for a deployment where the hub is the system of record and nodes
  are interchangeable capacity.

A provider with `servesAll` is a **catch-all**, selected only when no
organization-specific provider is eligible. The hub's own provider is one, which
is what lets a single-server deployment work with no configuration — and lets
attaching a node for `acme` later take over `acme`'s traffic without touching
the hub's settings. A node is never a catch-all, so joining cannot silently
capture organizations it was not given.

## Routing

Four rules. They are written down in one place because getting them consistent
*is* the job.

### Writes follow ownership

Creating a project goes to whichever provider holds its organization;
publishing a release goes to whichever holds its package; attaching an artifact
goes to whichever holds its release. Only `createOrganization` has no parent to
follow, and it goes to `ProviderRegistry.primaryFor`.

A write **never fans out**. Two providers each minting their own id for "the
same" new release would leave the hub unable to say which one a client meant.

`primaryFor` picks the best writable provider: highest `priority`, then most
free space, then id. Never registration order — the same fleet makes the same
decision every time.

```dart
registry.primaryFor('acme');                          // node-eu
registry.primaryFor('acme', labels: {'tier': 'cold'}); // node-archive
```

### Reads by id fan out

First hit wins, and the answer is cached in a bounded id→provider map. A stale
entry is corrected the moment its provider answers `null`, so the cache is a
pure optimisation over a fan-out that still works.

### Listings aggregate

Across every provider, deduplicated by **natural** key — `acme`,
`acme/agent`, `acme/agent/omnyagent` — rather than by id.

That distinction matters. Each provider mints its own ids, so an organization
replicated onto two nodes has two ids; keying on those would show it twice.
Keying on the entity's real uniqueness constraint collapses genuine replicas and
never collapses distinct records. Sharding (different packages on different
nodes) and replication (the same package on several) both work, and the client
cannot tell which it is looking at.

### Downloads prefer a redirect

If the provider holding the bytes can issue a URL, the client is sent straight
there and no artifact byte crosses the hub.

### Degradation

A provider failing a read is logged and skipped, not propagated: one unreachable
node must not break a federation-wide listing. A listing returns what the
healthy providers hold.

## Data planes

Artifact bytes travel one of three ways, chosen per provider from what it can
actually do:

| Mode | When | Cost to the registry |
|---|---|---|
| `presigned` | the backend can issue URLs (S3, GCS with a key) | one small response |
| `direct` | the node is reachable at `--public-url` | one redirect |
| `relay` | the node is behind NAT | the whole artifact, twice |

`relay` chunks bytes over the control channel in 256 KiB frames, base64-encoded.
It is correct everywhere and the slowest of the three — every byte crosses the
node→hub WebSocket and then the hub→client connection. It exists so a fully
firewalled node is still a usable provider, not as a default to settle for.

`OmnyStoreNode` picks the best mode its configuration allows and advertises it
in its descriptor, so improving the topology is a configuration change, not a
code change.

## Running it

```sh
# The hub. Also a provider, so it works before any node attaches.
omnystore server \
  --data /var/lib/omnystore \
  --port 443 \
  --tls-cert /etc/tls/fullchain.pem --tls-key /etc/tls/privkey.pem \
  --publish-token "$PUBLISH_TOKEN" \
  --node-token   "$NODE_TOKEN"

# A node in Europe, backed by S3, serving two organizations.
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
omnystore node \
  --hub wss://store.example.com/_node \
  --id node-eu \
  --token "$NODE_TOKEN" \
  --org acme --org globex \
  --label region=eu \
  --priority 10 \
  --data /var/lib/omnystore-node
```

```sh
omnystore providers
```

```text
ID         KIND  STATUS  DATA PLANE  ORGANIZATIONS
---------  ----  ------  ----------  -------------
hub-local  hub   online  relay       *
node-eu    node  online  presigned   acme,globex
node-us    node  online  relay       acme
```

## Admission

A node declares what it holds. Without a check, anyone who can reach the control
endpoint could declare themselves the provider for `acme` and start receiving
its releases. Two gates:

```dart
OmnyStoreServer(
  store: hub,
  // Who may connect at all.
  nodeAuthenticator: BearerTokenAuthenticator({nodeToken: nodePrincipal}),
  // What an authenticated node is actually allowed to serve.
  nodeAdmissionPolicy: (nodeId, declared, principal) {
    final allowed = allowedOrganizationsFor(nodeId);
    return declared.intersection(allowed);
  },
);
```

The policy returns the organizations the node may serve — usually `declared`,
possibly a subset. Returning an empty set rejects it. Refused organizations are
logged rather than silently dropped.

The hub also refuses a node whose protocol version it does not implement: a
mismatch is an operator error with a clear fix, and admitting a peer that will
misinterpret every payload is worse than turning it away.

## Replication

Metadata writes go to exactly one provider. Artifact *bytes* have no such
constraint, so replication is a separate, explicit step:

```dart
await hub.replicateAsset(asset.id, 'node-us');
```

It reads from the owner, writes to the target, and **verifies against the
source's digest on arrival** — a replica that silently differs is worse than no
replica, because clients would get different bytes depending on which node
answered.

Ids do not travel. The target's copy of the organization, project, package and
release is located by *natural* key — name, and version — and created if absent.
Re-running converges rather than failing: replication is a reconciliation pass,
and a scheduled reconciler that alarmed on every cycle would be useless.

```dart
// A reconciliation pass, in outline.
for (final release in await hub.listReleases('omnyagent')) {
  for (final asset in await hub.listAssets(release.id)) {
    for (final target in hub.providers.replicationCandidatesFor('acme')) {
      await hub.replicateAsset(asset.id, target.id);
    }
  }
}
```

## Retiring a node

**Drain first.** The hub stops placing new artifacts there immediately, while
every client already downloading finishes normally:

```sh
# Ctrl-C on `omnystore node` drains before disconnecting.
```

```dart
await node.drain();   // status → draining; reads still served, writes refused
await node.resume();  // back to accepting writes
```

Then replicate its artifacts elsewhere, confirm, and stop it. A node that
disconnects is removed from the routing table outright rather than retained as
offline: the hub is not the system of record for a node's catalogue, and keeping
a dead provider would make every lookup pay a failing round-trip.

A node that reconnects is re-admitted under the same id. Refusing a reconnecting
node would strand its organizations until the stale entry timed out.

## The control protocol

Nodes and the hub speak `StoreProtocol` over OmnyHub's node control channel.
Registry operations map to actions (`store.release.publish`,
`store.asset.list`); byte streams become **sessions**, because an RPC channel
deals in discrete messages:

```text
download:  store.asset.open  → store.asset.read × N → store.asset.close
upload:    store.asset.upload.begin → …chunk × N → …commit | …abort
```

Sessions hold real resources — an open object read, an in-flight upload — so
they time out. A hub that dies mid-download must not leak a file handle on
every node it was talking to; an abandoned read is closed when the consumer
stops, and an aborted upload unwinds the partial object out of storage rather
than leaving it to be discovered later.

Typed exceptions survive the hop: a `ConflictException` raised on a node arrives
at the hub — and then at the client — as a `ConflictException`, not as an opaque
transport error.

## Testing a federation

`RemoteNodeStoreProvider` takes a `NodeInvoker`, so a test can wire it straight
to a `StoreRpcServer` with no socket in between. Everything the wire protocol
does is still exercised — JSON encoding of every argument, chunked relay of
bytes, typed-exception round-tripping — which is what makes the federation
tests fast *and* about the protocol rather than a mock of it.

See `test/support/federation.dart`, and `test/integration/hub_node_test.dart`
for the same scenarios over a real WebSocket.
