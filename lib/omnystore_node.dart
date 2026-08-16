/// OmnyStore Node — a storage provider that dials a hub and serves its
/// organizations' releases through it.
///
/// A node holds the metadata *and* the artifact bytes for the organizations it
/// serves, and answers the hub over an outbound WebSocket — so it can sit
/// behind NAT, on a private network, or in a different cloud from the hub, and
/// still be part of a public registry.
///
/// ```dart
/// final node = OmnyStoreNode(
///   hubUri: Uri.parse('wss://store.example.com/_node'),
///   nodeId: 'node-eu',
///   organizations: {'acme', 'globex'},
///   store: OmnyStore(
///     repositories: MemoryRepositories(),
///     storage: S3ObjectStorage(
///       bucket: 'acme-releases',
///       region: 'eu-west-1',
///       credentials: EnvironmentAwsCredentialsProvider(Platform.environment),
///     ),
///     providerId: 'node-eu',
///   ),
///   authToken: Platform.environment['OMNYSTORE_NODE_TOKEN'],
/// );
///
/// await node.start();
/// ```
///
/// Organizations and nodes are **many to many**: one organization's releases
/// may live on several nodes, and one node may serve several organizations.
library;

export 'omnystore.dart';

export 'src/nodes/omnystore_node.dart';
export 'src/nodes/store_protocol.dart';
export 'src/nodes/store_provider.dart';
export 'src/nodes/store_rpc_server.dart';

// The node dials the hub over OmnyHub's node runtime; re-exported so callers
// can tune reconnection without a second import.
export 'package:omnyhub/omnyhub_node.dart'
    show NodeId, NodeState, ReconnectPolicy;
