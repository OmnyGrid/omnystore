# CLI reference

```sh
dart pub global activate omnystore
omnystore --help
```

Or without installing:

```sh
dart run omnystore:omnystore --help
dart run omnystore:omnystore_server --data ./registry
```

## Global options

Every command accepts these, and they select which registry the command acts
on.

| Option | Environment | Meaning |
|---|---|---|
| `-s, --server <url>` | `OMNYSTORE_URL` | Act on a remote registry |
| `-d, --data <dir>` | `OMNYSTORE_DATA` | Act on a local registry directory |
| `-t, --token <token>` | `OMNYSTORE_TOKEN` | Bearer token for authentication |
| `--json` | | Emit JSON instead of a table |
| `-q, --quiet` | | Suppress progress output |
| `-v, --verbose` | | Log what the CLI and server are doing (to stderr) |
| `-V, --version` | | Print the version and exit |

`--server` and `--data` are mutually exclusive: they select different
registries, and there is no sensible way to combine them.

**Prefer the environment variable for the token.** A token on a command line is
visible in the process table to every user on the machine.

```sh
export OMNYSTORE_URL=https://store.example.com
export OMNYSTORE_TOKEN=$CI_PUBLISH_TOKEN
omnystore release list --package omnyagent
```

Logs go to stderr, so `--json` output on stdout stays parsable even with
`--verbose` on:

```sh
omnystore --json release list --package omnyagent | jq '.[].version'
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | A runtime failure |
| `10` | `check-update` only: an update is available |
| `64` | Usage error (`EX_USAGE`) — a missing flag, an unknown command |
| `65` | Malformed input (`EX_DATAERR`) |
| `66` | A required input file was not found (`EX_NOINPUT`) |

`10` is distinct from `1` so a shell script can branch on "an update exists"
without confusing it with a real failure:

```sh
if omnystore check-update --package omnyagent --current "$VERSION" --quiet; then
  echo "up to date"
else
  [ $? -eq 10 ] && echo "update available"
fi
```

## `omnystore server`

Runs the REST API server, and the storage-node endpoint on the same port.

```sh
omnystore server --data /var/lib/omnystore --port 8080
```

| Option | Default | Meaning |
|---|---|---|
| `-P, --port` | `8080` | Port to listen on; `0` picks a free one |
| `--address` | `0.0.0.0` | Address to bind |
| `--cors` | | Comma-separated allowed origins, or `*` |
| `--publish-token` | `$OMNYSTORE_PUBLISH_TOKEN` | Require this token for every write |
| `--node-token` | `$OMNYSTORE_NODE_TOKEN` | Require this token from storage nodes |
| `--nodes` | on | Accept storage nodes |
| `--node-mount` | `/_node` | Path the node endpoint is mounted at |
| `--tls-cert`, `--tls-key` | | PEM files, to serve HTTPS |
| `--provider-id` | `hub-local` | Id this server advertises for its own provider |

The data directory holds everything:

```text
/var/lib/omnystore/
  metadata/     organizations.json, releases.json, … (readable, diffable)
  objects/      orgs/acme/packages/omnyagent/1.2.0/omnyagent-linux-x64.tar.gz
```

Back it up with `rsync`, mount it as a volume, `tar` it. There is no database.

**Without `--publish-token` writes are open** — anyone who can reach the server
can publish. The startup banner says so. Reads stay open either way, which is
what makes downloads and update checks work for anonymous clients.

```sh
omnystore server --data /var/lib/omnystore \
  --publish-token "$PUBLISH_TOKEN" \
  --node-token "$NODE_TOKEN" \
  --cors 'https://releases.example.com' \
  --tls-cert /etc/tls/fullchain.pem \
  --tls-key  /etc/tls/privkey.pem
```

## `omnystore node`

Runs a storage node that serves organizations through a hub. The node dials the
hub outbound, so it works behind NAT.

```sh
omnystore node \
  --hub wss://store.example.com/_node \
  --id node-eu \
  --org acme --org globex \
  --data /var/lib/omnystore-node \
  --token "$OMNYSTORE_NODE_TOKEN"
```

| Option | Meaning |
|---|---|
| `--hub` | Hub control endpoint (`$OMNYSTORE_HUB`) |
| `--id` | This node's id, unique within the hub |
| `-o, --org` | An organization this node serves; repeatable |
| `--token` | Bearer token sent to the hub (`$OMNYSTORE_NODE_TOKEN`) |
| `--public-url` | Publicly reachable base URL, enabling direct redirects |
| `--priority` | Selection weight; higher wins among nodes serving one org |
| `--label` | Placement label `key=value`; repeatable (`region=eu`) |
| `--capacity` | Total capacity in bytes |

Set `--public-url` when clients can reach the node directly: the hub then
redirects them instead of relaying every byte through itself. Without it — and
without a presigning backend — bytes are chunked over the control channel,
which is correct everywhere and the slowest option.

`Ctrl-C` drains before disconnecting: the hub stops placing new artifacts here
while downloads already in flight finish.

## Resources

```sh
omnystore org create acme --display-name 'Acme Corporation'
omnystore org list
omnystore org delete acme --force

omnystore project create agent --org acme --repository https://github.com/acme/agent
omnystore project list --org acme
omnystore project delete <project-id> --force

omnystore package create omnyagent --project <project-id> \
  --platform linux-x64 --platform macos-arm64 \
  --default-channel release
omnystore package list --org acme
omnystore package delete omnyagent --force
```

`--force` is required to delete anything that still has children, rather than
silently destroying every release underneath it.

`--metadata key=value` is accepted on every `create`, repeatable.

## `omnystore release`

```sh
omnystore release publish --package omnyagent --version 1.2.0 \
  --notes @CHANGELOG.md \
  --tag v1.2.0 \
  --asset build/omnyagent-linux-x64.tar.gz:linux-x64 \
  --asset build/omnyagent-macos-arm64.tar.gz:macos-arm64
```

The version's pre-release tag decides the channel: `1.2.0-dev.3` is dev,
`1.2.0-beta.1` is beta, `1.2.0` is release.

`--notes @path` reads a file — release notes are usually a changelog, and shells
make multi-line arguments awkward.

`--asset path:platform` attaches a file and tags its platform in one flag.
`--draft` stores the release without offering it to anyone.

```sh
omnystore release list --package omnyagent
omnystore release list --package omnyagent --channel beta --drafts --yanked

omnystore release latest --package omnyagent                    # stable
omnystore release latest --package omnyagent --channel beta     # beta + stable
omnystore release latest --package omnyagent --channel beta --exact
omnystore release latest --package omnyagent --channel any
```

**`release latest` defaults to the stable channel**, so a deploy script that
forgets the flag never picks up a pre-release. It exits `1` when there is
nothing to report, so `if omnystore release latest …` works in a script.

```sh
omnystore release promote <release-id> --to release
omnystore release yank <release-id> --reason 'Corrupts the config on first run'
omnystore release yank <release-id> --undo
omnystore release delete <release-id>
```

Prefer `yank` to `delete`. A yanked release stays downloadable for clients that
pinned it, but is never offered again; deleting breaks them.

## `omnystore asset`

```sh
omnystore asset upload --release <release-id> --file dist/agent.tar.gz \
  --platform linux-x64 --kind installer

omnystore asset upload --package omnyagent --version 1.2.0 \
  --file dist/agent.tar.gz

omnystore asset list --package omnyagent --version 1.2.0
omnystore asset delete <asset-id>
```

Uploads compute the file's checksum locally and require the server to agree
(`--verify`, on by default), so a corrupted transfer fails the command instead
of publishing bad bytes.

`--kind` marks what an artifact *is*: `installer`, `archive`, `checksums`,
`signature`. The update service never offers a checksum or signature file as
*the* download.

## `omnystore download`

```sh
omnystore download --package omnyagent --platform linux-x64 -o /opt
omnystore download --package omnyagent --version 1.2.0 --asset agent.tar.gz
omnystore download --package omnyagent --channel beta --platform macos-arm64
```

Resolves the release, picks the artifact, streams it with a progress bar,
resumes an interrupted transfer, and verifies the checksum. An
already-downloaded, verified file transfers nothing.

When a release has several artifacts and none is selected, the command lists
them and exits `64` rather than guessing.

## `omnystore check-update`

```sh
omnystore check-update --package omnyagent --current 1.0.0
omnystore check-update --package omnyagent --current 1.0.0 --channel beta \
  --platform macos-arm64
```

Exits `0` when current, `10` when an update exists. `--json` gives the full
answer including the release and the matching artifact.

## `omnystore providers`

```sh
omnystore providers
omnystore providers --org acme
```

```text
ID         KIND  STATUS  DATA PLANE  ORGANIZATIONS
---------  ----  ------  ----------  -------------
hub-local  hub   online  relay       *
node-eu    node  online  presigned   acme,globex
node-us    node  draining relay      acme
```

## A CI pipeline

```sh
export OMNYSTORE_URL=https://store.example.com
export OMNYSTORE_TOKEN=$CI_PUBLISH_TOKEN

case "$CI_BRANCH" in
  release) VERSION="$BASE_VERSION" ;;
  beta)    VERSION="$BASE_VERSION-beta.$CI_BUILD_NUMBER" ;;
  *)       VERSION="$BASE_VERSION-dev.$CI_BUILD_NUMBER" ;;
esac

omnystore release publish \
  --package omnyagent \
  --version "$VERSION" \
  --notes @CHANGELOG.md \
  --tag "$CI_COMMIT_TAG" \
  --metadata "commit=$CI_COMMIT_SHA" \
  --asset build/omnyagent-linux-x64.tar.gz:linux-x64 \
  --asset build/omnyagent-macos-arm64.tar.gz:macos-arm64 \
  --asset build/omnyagent-windows-x64.zip:windows-x64

# After the beta has soaked, promote it — the artifacts come across with it.
omnystore release promote "$RELEASE_ID" --to release
```

Re-running a published version is a `conflict` and exits `1`. That is the
correct outcome: releases are immutable, so a rebuild gets a new version rather
than overwriting one clients may already have downloaded.

## Using the CLI as a library

`runOmnyStoreCli` takes its arguments, environment and output sinks as
parameters, so the whole command surface runs in-process:

```dart
import 'package:omnystore/omnystore_cli.dart';

final out = StringBuffer();
final code = await runOmnyStoreCli(
  ['--json', 'release', 'latest', '--package', 'omnyagent'],
  environment: {'OMNYSTORE_URL': 'https://store.example.com'},
  out: out,
);
```

See [`example/operating/cli_workflow.dart`](../example/operating/cli_workflow.dart).
