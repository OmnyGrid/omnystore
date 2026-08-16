import '../channels/release_channel.dart';
import '../exceptions/error_codes.dart';
import '../exceptions/omnystore_exception.dart';
import '../models/download_record.dart';
import '../repositories/release_query.dart';
import '../storage/object_storage.dart';
import '../utils/json.dart';
import '../utils/version_codec.dart';

/// The wire contract between a hub and its storage nodes.
///
/// Nodes reach the hub over OmnyHub's node control channel — a WebSocket the
/// node dials outward, which is what lets a node sit behind NAT and still serve
/// a public registry. This library names the RPC actions carried on it and the
/// shape of their payloads.
///
/// **Two planes, deliberately.** Registry operations (create a package, publish
/// a release, list assets) are small JSON round-trips and travel on the control
/// channel directly. Artifact *bytes* are a different problem: an installer is
/// gigabytes and the control channel frames JSON. So bytes travel one of three
/// ways, chosen per provider by [DataPlaneMode]:
///
/// * [DataPlaneMode.presigned] — the node's bucket issues a URL and the client
///   fetches it directly. Nothing crosses the hub or the node.
/// * [DataPlaneMode.direct] — the node is reachable, and the hub redirects the
///   client to the node's own HTTP endpoint.
/// * [DataPlaneMode.relay] — the node is not reachable, so bytes are streamed
///   over the control channel in chunks ([chunkOpen], [chunkRead],
///   [uploadChunk]). Correct everywhere, and the slowest: every byte is
///   base64-framed and crosses two hops. The chunked actions exist so that even
///   a fully firewalled node is a usable provider.
class StoreProtocol {
  const StoreProtocol._();

  /// The protocol version advertised at registration. A hub refuses a node
  /// whose major version it does not implement.
  static const int version = 1;

  /// The capability token a storage node advertises to the hub, so a hub
  /// sharing its OmnyHub instance with other node types can tell them apart.
  static const String capability = 'omnystore-provider';

  /// The registration payload key carrying the node's [ProviderDescriptor].
  static const String descriptorKey = 'provider';

  /// The registration payload key carrying the protocol version.
  static const String versionKey = 'protocolVersion';

  /// The registration ack key carrying the ticket-signing secret the hub
  /// issues to a [DataPlaneMode.direct] node.
  static const String ticketSecretKey = 'ticketSecret';

  // -------------------------------------------------------------- actions --

  /// Returns the node's current [ProviderDescriptor].
  static const String describe = 'store.describe';

  /// Organization operations.
  static const String organizationCreate = 'store.org.create';
  static const String organizationGet = 'store.org.get';
  static const String organizationByName = 'store.org.byName';
  static const String organizationList = 'store.org.list';
  static const String organizationUpdate = 'store.org.update';
  static const String organizationDelete = 'store.org.delete';

  /// Project operations.
  static const String projectCreate = 'store.project.create';
  static const String projectGet = 'store.project.get';
  static const String projectByName = 'store.project.byName';
  static const String projectList = 'store.project.list';
  static const String projectUpdate = 'store.project.update';
  static const String projectDelete = 'store.project.delete';

  /// Package operations.
  static const String packageCreate = 'store.package.create';
  static const String packageGet = 'store.package.get';
  static const String packageByName = 'store.package.byName';
  static const String packageResolve = 'store.package.resolve';
  static const String packageList = 'store.package.list';
  static const String packageUpdate = 'store.package.update';
  static const String packageDelete = 'store.package.delete';

  /// Release operations.
  static const String releasePublish = 'store.release.publish';
  static const String releaseGet = 'store.release.get';
  static const String releaseByVersion = 'store.release.byVersion';
  static const String releaseList = 'store.release.list';
  static const String releaseUpdate = 'store.release.update';
  static const String releaseDelete = 'store.release.delete';
  static const String releaseLatest = 'store.release.latest';
  static const String releasePromote = 'store.release.promote';

  /// Asset metadata operations.
  static const String assetGet = 'store.asset.get';
  static const String assetByName = 'store.asset.byName';
  static const String assetList = 'store.asset.list';
  static const String assetDelete = 'store.asset.delete';
  static const String assetDownloadTarget = 'store.asset.target';

  /// Chunked download: open a read, pull chunks, close it.
  static const String chunkOpen = 'store.asset.open';
  static const String chunkRead = 'store.asset.read';
  static const String chunkClose = 'store.asset.close';

  /// Chunked upload: begin, push chunks, commit or abort.
  static const String uploadBegin = 'store.asset.upload.begin';
  static const String uploadChunk = 'store.asset.upload.chunk';
  static const String uploadCommit = 'store.asset.upload.commit';
  static const String uploadAbort = 'store.asset.upload.abort';

  /// Download recording and statistics.
  static const String downloadRecord = 'store.download.record';
  static const String downloadList = 'store.download.list';
  static const String downloadStats = 'store.download.stats';

  /// Update checking.
  static const String updateCheck = 'store.update.check';

  /// Provider listing.
  static const String providerList = 'store.provider.list';

  /// The default relay chunk size.
  ///
  /// 256 KiB of payload becomes about 344 KiB once base64-framed, which is
  /// comfortably inside a WebSocket frame while keeping the per-chunk
  /// round-trip cost small relative to the data moved.
  static const int defaultChunkBytes = 256 * 1024;

  /// The largest chunk a node will accept or emit, so a malicious or buggy
  /// peer cannot force an allocation of arbitrary size.
  static const int maxChunkBytes = 8 * 1024 * 1024;

  // --------------------------------------------------------------- codecs --

  /// Encodes a [ReleaseQuery] into an RPC payload.
  static Map<String, dynamic> encodeQuery(ReleaseQuery query) => {
    'channel': ?query.channel?.name,
    'acceptedBy': ?query.acceptedBy?.name,
    'includeDrafts': query.includeDrafts,
    'includeYanked': query.includeYanked,
    'includeUnpublished': query.includeUnpublished,
    'limit': ?query.limit,
    'offset': query.offset,
  };

  /// Decodes a [ReleaseQuery] from an RPC payload.
  static ReleaseQuery decodeQuery(Map<String, dynamic> json) {
    final channel = Json.optString(json, 'channel');
    final acceptedBy = Json.optString(json, 'acceptedBy');
    return ReleaseQuery(
      channel: channel == null ? null : ReleaseChannel.parse(channel),
      acceptedBy: acceptedBy == null ? null : ReleaseChannel.parse(acceptedBy),
      includeDrafts: Json.optBool(json, 'includeDrafts'),
      includeYanked: Json.optBool(json, 'includeYanked'),
      includeUnpublished: Json.optBool(json, 'includeUnpublished'),
      limit: Json.optInt(json, 'limit'),
      offset: Json.optInt(json, 'offset', 0)!,
    );
  }

  /// Encodes a [ByteRange] into an RPC payload fragment.
  static Map<String, dynamic> encodeRange(ByteRange? range) => range == null
      ? const {}
      : {'rangeStart': range.start, 'rangeEnd': ?range.end};

  /// Decodes a [ByteRange] from an RPC payload fragment, or `null`.
  static ByteRange? decodeRange(Map<String, dynamic> json) {
    final start = Json.optInt(json, 'rangeStart');
    if (start == null) return null;
    return ByteRange(start, Json.optInt(json, 'rangeEnd'));
  }

  /// Encodes [DownloadStats] for the wire.
  static Map<String, dynamic> encodeStats(DownloadStats stats) =>
      stats.toJson();

  /// Decodes [DownloadStats] from the wire.
  static DownloadStats decodeStats(Map<String, dynamic> json) =>
      DownloadStats.fromJson(json);

  /// Renders an [OmnyStoreException] into an RPC error payload.
  ///
  /// The typed hierarchy has to survive the node→hub hop: a client asking the
  /// hub for a missing release should get [ReleaseNotFoundException], not a
  /// generic "node call failed". The code travels, and [exceptionFrom]
  /// reconstructs it.
  static Map<String, dynamic> encodeException(OmnyStoreException e) => {
    'error': {
      'code': e.code,
      'message': e.message,
      'statusCode': e.statusCode,
      if (e.details.isNotEmpty) 'details': e.details,
    },
  };

  /// Reconstructs an exception from an RPC error payload, or returns `null` if
  /// [json] carries no error.
  static OmnyStoreException? exceptionFrom(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is! Map) return null;
    final map = error.cast<String, dynamic>();
    final details = map['details'];
    return omnyStoreExceptionForCode(
      Json.optString(map, 'code') ?? ErrorCodes.apiError,
      Json.optString(map, 'message') ?? 'Node call failed',
      statusCode: Json.optInt(map, 'statusCode', 500)!,
      details: details is Map
          ? details.map((k, v) => MapEntry('$k', v as Object?))
          : const {},
    );
  }

  /// Reads a required semantic version field from an RPC payload.
  static Object requireVersion(Map<String, dynamic> json, String key) =>
      Versions.parse(Json.requireString(json, key));
}
