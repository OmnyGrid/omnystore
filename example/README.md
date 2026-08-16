# OmnyStore examples

Twenty runnable programs, grouped by what you are trying to do. Every one of
them runs as written:

```sh
dart run example/getting_started/embedded_registry.dart
```

Those marked **serves** bind a port and wait for `Ctrl-C`; the rest run to
completion and exit.

## [`getting_started/`](getting_started/)

From "the whole thing in thirty lines" to a server you can `curl`.

| # | Example | What it shows |
|---|---|---|
| 1 | [`embedded_registry.dart`](getting_started/embedded_registry.dart) | The whole platform in one process: organization → project → package → release → artifact, with no server and no database. |
| 2 | [`channels_and_promotion.dart`](getting_started/channels_and_promotion.dart) | Why a release's channel comes from its *version*, what each subscriber is offered, and how promoting `1.1.0-beta.2` to `1.1.0` reaches everyone at once. |
| 3 | [`rest_api_server.dart`](getting_started/rest_api_server.dart) | **serves** — the REST API, a health probe and the storage-node endpoint on one port, over a directory that survives restarts. |
| 4 | [`client_sdk.dart`](getting_started/client_sdk.dart) | Talking to a remote registry. Run example 3 first. |

## [`shipping_software/`](shipping_software/)

Getting a build out, and getting it onto a machine.

| # | Example | What it shows |
|---|---|---|
| 5 | [`update_checker.dart`](shipping_software/update_checker.dart) | An application asking "is there a newer version for me?", once at startup and then on an interval. |
| 6 | [`download_manager.dart`](shipping_software/download_manager.dart) | Streaming an artifact to disk, resuming, and refusing anything that fails its checksum. |
| 10 | [`ci_release_pipeline.dart`](shipping_software/ci_release_pipeline.dart) | A build job: derive the version and channel from the branch, publish, upload every platform build. |
| 13 | [`drafts_and_yanking.dart`](shipping_software/drafts_and_yanking.dart) | Staging a release before anyone sees it, and withdrawing a bad one without breaking clients that pinned it. |
| 14 | [`download_analytics.dart`](shipping_software/download_analytics.dart) | Is the rollout progressing? Adoption per version and per artifact. |
| 20 | [`ranged_downloads.dart`](shipping_software/ranged_downloads.dart) | `Range`, `206 Partial Content` and `content-range` — the mechanism resume is built on. |

## [`storage/`](storage/)

Where the artifact bytes actually live.

| # | Example | What it shows |
|---|---|---|
| 8 | [`storage_backends.dart`](storage/storage_backends.dart) | Local directory, S3, any S3-compatible service, and Google Cloud Storage — and which of them let clients fetch straight from the bucket. |
| 9 | [`custom_storage_backend.dart`](storage/custom_storage_backend.dart) | Implementing `ObjectStorage` yourself: the five rules that make everything above it keep working. |
| 17 | [`persistent_registry.dart`](storage/persistent_registry.dart) | One directory holding readable JSON metadata and a browsable artifact tree. |

## [`hub_and_nodes/`](hub_and_nodes/)

Distributing storage across machines.

| # | Example | What it shows |
|---|---|---|
| 7 | [`hub_with_nodes.dart`](hub_and_nodes/hub_with_nodes.dart) | A hub federating two storage nodes over real WebSockets, including many-to-many organizations and draining a node. |
| 12 | [`replication_and_placement.dart`](hub_and_nodes/replication_and_placement.dart) | Which provider takes a write, and copying an artifact's bytes onto a second node — verified, and idempotent. |

## [`operating/`](operating/)

Running it for real.

| # | Example | What it shows |
|---|---|---|
| 11 | [`authentication.dart`](operating/authentication.dart) | Open reads, guarded writes, and why the node-join endpoint needs its own credential. |
| 15 | [`mount_into_existing_app.dart`](operating/mount_into_existing_app.dart) | **serves** — the registry as two services inside an OmnyHub application you already run. |
| 18 | [`cli_workflow.dart`](operating/cli_workflow.dart) | The `omnystore` command set, driven in-process. Mirrors a real shell session. |

## [`building_on_it/`](building_on_it/)

Extending it, and shipping it somewhere new.

| # | Example | What it shows |
|---|---|---|
| 16 | [`testing_a_release_workflow.dart`](building_on_it/testing_a_release_workflow.dart) | Deterministic tests: injected clock and ids, in-memory adapters that are not mocks. |
| 19 | [`web_client.dart`](building_on_it/web_client.dart) | The registry from a browser. Compiles to JavaScript — `dart compile js example/building_on_it/web_client.dart` proves it. |

## Where to start

**Evaluating it?** Run 1, then 2. Between them they cover most of what makes
this different from a directory full of tarballs.

**Self-hosting?** 3 and 17 are the deployment; 11 is what to configure before
it is reachable from anywhere untrusted.

**Distributing an app?** 5 and 6 are the client half; 10 is the pipeline that
feeds them.

**Running it at scale?** 7 and 12 are the federation; 8 is the decision that
determines whether your registry's bandwidth becomes your ceiling.
