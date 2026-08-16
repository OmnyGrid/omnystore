import 'dart:async';
import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../exceptions/error_codes.dart';
import '../exceptions/omnystore_exception.dart';
import '../models/asset.dart';
import '../models/download_record.dart';
import '../models/organization.dart';
import '../models/package.dart';
import '../models/project.dart';
import '../models/provider_descriptor.dart';
import '../models/release.dart';
import '../models/update_info.dart';
import '../repositories/release_query.dart';
import '../services/asset_download.dart';
import '../services/omnystore_api.dart';
import '../storage/object_storage.dart';
import '../utils/json.dart';
import 'store_protocol.dart';
import 'store_provider.dart';

/// Invokes [action] on a node and returns its response payload.
///
/// The seam between this proxy and the transport. In production it is backed by
/// OmnyHub's `NodeGateway.request`; in tests it is a direct call into a
/// [StoreRpcServer], which is what makes the whole federation testable without
/// binding a socket.
typedef NodeInvoker =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, dynamic> payload,
    );

/// The hub-side face of a connected storage node: an [OmnyStoreApi] whose every
/// call is forwarded over the node's control channel.
///
/// This is what makes a node indistinguishable from an in-process store as far
/// as [OmnyStoreHub] is concerned. The hub routes to a `StoreProvider`; whether
/// that provider is a local [OmnyStore] or a machine in another datacentre is
/// not something the routing code knows or needs to.
///
/// **Byte streaming.** [openAsset] pulls the artifact over the control channel
/// in chunks and re-exposes it as an ordinary [Stream], so callers upstream see
/// a normal byte stream regardless of how far away the bytes were. [attachAsset]
/// does the reverse. Both are the [DataPlaneMode.relay] path, used when the node
/// can neither presign a URL nor be reached directly; see [StoreProtocol] for
/// why the other two modes are preferable when the topology allows them.
class RemoteNodeStoreProvider implements StoreProvider, OmnyStoreApi {
  /// Forwards an action to the node.
  final NodeInvoker invoke;

  /// Bytes requested per relay chunk.
  final int chunkBytes;

  ProviderDescriptor _descriptor;

  /// Creates a proxy for the node described by [descriptor].
  RemoteNodeStoreProvider({
    required ProviderDescriptor descriptor,
    required this.invoke,
    this.chunkBytes = StoreProtocol.defaultChunkBytes,
  }) : _descriptor = descriptor;

  @override
  String get id => _descriptor.id;

  @override
  ProviderDescriptor get descriptor => _descriptor;

  @override
  OmnyStoreApi get store => this;

  @override
  bool get isReadable => _descriptor.isReadable;

  @override
  bool get isWritable => _descriptor.isWritable;

  @override
  bool serves(String organization) => _descriptor.serves(organization);

  /// Replaces the cached descriptor — called as the node heartbeats, so
  /// capacity and liveness stay current between registrations.
  void updateDescriptor(ProviderDescriptor descriptor) =>
      _descriptor = descriptor;

  /// Re-reads the node's descriptor over the control channel.
  Future<ProviderDescriptor> refreshDescriptor() async {
    final response = await _call(StoreProtocol.describe, const {});
    _descriptor = ProviderDescriptor.fromJson(
      Json.asObject(response['provider'], 'provider descriptor'),
    );
    return _descriptor;
  }

  // ---------------------------------------------------------------- orgs ---

  @override
  Future<Organization> createOrganization({
    required String name,
    String? displayName,
    String? description,
    String? website,
    Map<String, String> metadata = const {},
  }) async => Organization.fromJson(
    await _result(StoreProtocol.organizationCreate, {
      'name': name,
      'displayName': ?displayName,
      'description': ?description,
      'website': ?website,
      'metadata': metadata,
    }),
  );

  @override
  Future<Organization?> organization(String id) async => _maybe(
    await _call(StoreProtocol.organizationGet, {'id': id}),
    Organization.fromJson,
  );

  @override
  Future<Organization?> organizationByName(String name) async => _maybe(
    await _call(StoreProtocol.organizationByName, {'name': name}),
    Organization.fromJson,
  );

  @override
  Future<List<Organization>> listOrganizations() async => _list(
    await _call(StoreProtocol.organizationList, const {}),
    Organization.fromJson,
  );

  @override
  Future<Organization> updateOrganization(
    String id, {
    String? displayName,
    String? description,
    String? website,
    Map<String, String>? metadata,
  }) async => Organization.fromJson(
    await _result(StoreProtocol.organizationUpdate, {
      'id': id,
      'displayName': ?displayName,
      'description': ?description,
      'website': ?website,
      'metadata': ?metadata,
    }),
  );

  @override
  Future<void> deleteOrganization(String id, {bool force = false}) =>
      _call(StoreProtocol.organizationDelete, {'id': id, 'force': force});

  // ------------------------------------------------------------ projects ---

  @override
  Future<Project> createProject({
    required String organizationId,
    required String name,
    String? displayName,
    String? description,
    String? repository,
    String? website,
    Map<String, String> metadata = const {},
  }) async => Project.fromJson(
    await _result(StoreProtocol.projectCreate, {
      'organizationId': organizationId,
      'name': name,
      'displayName': ?displayName,
      'description': ?description,
      'repository': ?repository,
      'website': ?website,
      'metadata': metadata,
    }),
  );

  @override
  Future<Project?> project(String id) async => _maybe(
    await _call(StoreProtocol.projectGet, {'id': id}),
    Project.fromJson,
  );

  @override
  Future<Project?> projectByName(String organizationId, String name) async =>
      _maybe(
        await _call(StoreProtocol.projectByName, {
          'organizationId': organizationId,
          'name': name,
        }),
        Project.fromJson,
      );

  @override
  Future<List<Project>> listProjects({String? organizationId}) async => _list(
    await _call(StoreProtocol.projectList, {'organizationId': ?organizationId}),
    Project.fromJson,
  );

  @override
  Future<Project> updateProject(
    String id, {
    String? displayName,
    String? description,
    String? repository,
    String? website,
    Map<String, String>? metadata,
  }) async => Project.fromJson(
    await _result(StoreProtocol.projectUpdate, {
      'id': id,
      'displayName': ?displayName,
      'description': ?description,
      'repository': ?repository,
      'website': ?website,
      'metadata': ?metadata,
    }),
  );

  @override
  Future<void> deleteProject(String id, {bool force = false}) =>
      _call(StoreProtocol.projectDelete, {'id': id, 'force': force});

  // ------------------------------------------------------------ packages ---

  @override
  Future<Package> createPackage({
    required String projectId,
    required String name,
    String? displayName,
    String? description,
    ReleaseChannel defaultChannel = ReleaseChannel.release,
    List<String> platforms = const [],
    Map<String, String> metadata = const {},
  }) async => Package.fromJson(
    await _result(StoreProtocol.packageCreate, {
      'projectId': projectId,
      'name': name,
      'displayName': ?displayName,
      'description': ?description,
      'defaultChannel': defaultChannel.name,
      'platforms': platforms,
      'metadata': metadata,
    }),
  );

  @override
  Future<Package?> package(String id) async => _maybe(
    await _call(StoreProtocol.packageGet, {'id': id}),
    Package.fromJson,
  );

  @override
  Future<Package?> packageByName(String projectId, String name) async => _maybe(
    await _call(StoreProtocol.packageByName, {
      'projectId': projectId,
      'name': name,
    }),
    Package.fromJson,
  );

  @override
  Future<Package> resolvePackage(String reference) async => Package.fromJson(
    await _result(StoreProtocol.packageResolve, {'reference': reference}),
  );

  @override
  Future<List<Package>> listPackages({
    String? projectId,
    String? organizationId,
  }) async => _list(
    await _call(StoreProtocol.packageList, {
      'projectId': ?projectId,
      'organizationId': ?organizationId,
    }),
    Package.fromJson,
  );

  @override
  Future<Package> updatePackage(
    String id, {
    String? displayName,
    String? description,
    ReleaseChannel? defaultChannel,
    List<String>? platforms,
    Map<String, String>? metadata,
  }) async => Package.fromJson(
    await _result(StoreProtocol.packageUpdate, {
      'id': id,
      'displayName': ?displayName,
      'description': ?description,
      'defaultChannel': ?defaultChannel?.name,
      'platforms': ?platforms,
      'metadata': ?metadata,
    }),
  );

  @override
  Future<void> deletePackage(String id, {bool force = false}) =>
      _call(StoreProtocol.packageDelete, {'id': id, 'force': force});

  // ------------------------------------------------------------ releases ---

  @override
  Future<Release> publishRelease({
    required String packageReference,
    required Version version,
    String? title,
    String? notes,
    String? tag,
    bool draft = false,
    Map<String, String> metadata = const {},
  }) async => Release.fromJson(
    await _result(StoreProtocol.releasePublish, {
      'packageReference': packageReference,
      'version': version.toString(),
      'title': ?title,
      'notes': ?notes,
      'tag': ?tag,
      'draft': draft,
      'metadata': metadata,
    }),
  );

  @override
  Future<Release?> release(String id) async => _maybe(
    await _call(StoreProtocol.releaseGet, {'id': id}),
    Release.fromJson,
  );

  @override
  Future<Release?> releaseByVersion(
    String packageReference,
    Version version,
  ) async => _maybe(
    await _call(StoreProtocol.releaseByVersion, {
      'packageReference': packageReference,
      'version': version.toString(),
    }),
    Release.fromJson,
  );

  @override
  Future<List<Release>> listReleases(
    String packageReference, {
    ReleaseQuery query = const ReleaseQuery(),
  }) async => _list(
    await _call(StoreProtocol.releaseList, {
      'packageReference': packageReference,
      ...StoreProtocol.encodeQuery(query),
    }),
    Release.fromJson,
  );

  @override
  Future<Release> updateRelease(
    String id, {
    String? title,
    String? notes,
    String? tag,
    bool? draft,
    bool? yanked,
    String? yankedReason,
    Map<String, String>? metadata,
  }) async => Release.fromJson(
    await _result(StoreProtocol.releaseUpdate, {
      'id': id,
      'title': ?title,
      'notes': ?notes,
      'tag': ?tag,
      'draft': ?draft,
      'yanked': ?yanked,
      'yankedReason': ?yankedReason,
      'metadata': ?metadata,
    }),
  );

  @override
  Future<void> deleteRelease(String id) =>
      _call(StoreProtocol.releaseDelete, {'id': id});

  @override
  Future<Release?> latestRelease(String packageReference) =>
      latestChannel(packageReference, ReleaseChannel.release, exact: true);

  @override
  Future<Release?> latestBeta(String packageReference) =>
      latestChannel(packageReference, ReleaseChannel.beta, exact: true);

  @override
  Future<Release?> latestDev(String packageReference) =>
      latestChannel(packageReference, ReleaseChannel.dev, exact: true);

  @override
  Future<Release?> latestChannel(
    String packageReference,
    ReleaseChannel channel, {
    bool exact = false,
  }) async => _maybe(
    await _call(StoreProtocol.releaseLatest, {
      'packageReference': packageReference,
      'channel': channel.name,
      'exact': exact,
    }),
    Release.fromJson,
  );

  @override
  Future<Release?> latestAny(String packageReference) async => _maybe(
    await _call(StoreProtocol.releaseLatest, {
      'packageReference': packageReference,
    }),
    Release.fromJson,
  );

  @override
  Future<Release> promoteRelease(
    String releaseId,
    ReleaseChannel channel, {
    String? notes,
  }) async => Release.fromJson(
    await _result(StoreProtocol.releasePromote, {
      'id': releaseId,
      'channel': channel.name,
      'notes': ?notes,
    }),
  );

  // -------------------------------------------------------------- assets ---

  @override
  Future<Asset> attachAsset({
    required String releaseId,
    required String name,
    required Stream<List<int>> data,
    int? length,
    String contentType = 'application/octet-stream',
    String? expectedSha256,
    String? platform,
    String? kind,
    Map<String, String> metadata = const {},
  }) async {
    final begin = await _call(StoreProtocol.uploadBegin, {
      'releaseId': releaseId,
      'name': name,
      'length': ?length,
      'contentType': contentType,
      'expectedSha256': ?expectedSha256,
      'platform': ?platform,
      'kind': ?kind,
      'metadata': metadata,
    });
    final uploadId = Json.requireString(begin, 'uploadId');

    try {
      // Re-chunked to the protocol's frame size: the source's own boundaries
      // come from wherever the bytes originated (a file read, an HTTP body) and
      // may be far larger than a control frame should carry.
      var buffer = <int>[];
      await for (final chunk in data) {
        buffer.addAll(chunk);
        while (buffer.length >= chunkBytes) {
          await _sendChunk(uploadId, buffer.sublist(0, chunkBytes));
          buffer = buffer.sublist(chunkBytes);
        }
      }
      if (buffer.isNotEmpty) await _sendChunk(uploadId, buffer);

      return Asset.fromJson(
        await _result(StoreProtocol.uploadCommit, {'uploadId': uploadId}),
      );
    } on Object {
      // Tell the node to unwind its partial object rather than leaving it to
      // the session timeout, which would keep the bytes around for minutes.
      await _abortQuietly(uploadId);
      rethrow;
    }
  }

  @override
  Future<Asset?> asset(String id) async =>
      _maybe(await _call(StoreProtocol.assetGet, {'id': id}), Asset.fromJson);

  @override
  Future<Asset?> assetByName(String releaseId, String name) async => _maybe(
    await _call(StoreProtocol.assetByName, {
      'releaseId': releaseId,
      'name': name,
    }),
    Asset.fromJson,
  );

  @override
  Future<List<Asset>> listAssets(String releaseId) async => _list(
    await _call(StoreProtocol.assetList, {'releaseId': releaseId}),
    Asset.fromJson,
  );

  @override
  Future<void> deleteAsset(String id) =>
      _call(StoreProtocol.assetDelete, {'id': id});

  @override
  Future<AssetDownload> openAsset(String id, {ByteRange? range}) async {
    final opened = await _call(StoreProtocol.chunkOpen, {
      'id': id,
      ...StoreProtocol.encodeRange(range),
    });
    final readId = Json.requireString(opened, 'readId');
    final asset = Asset.fromJson(Json.asObject(opened['asset'], 'asset'));

    return AssetDownload(
      asset: asset,
      stream: _readChunks(readId),
      length: Json.requireInt(opened, 'length'),
      range: range,
      providerId: Json.optString(opened, 'providerId') ?? id,
    );
  }

  @override
  Future<DownloadTarget> downloadTarget(
    String id, {
    Duration expiresIn = const Duration(minutes: 15),
  }) async {
    final response = await _call(StoreProtocol.assetDownloadTarget, {
      'id': id,
      'expiresIn': expiresIn.inSeconds,
    });
    if (Json.optString(response, 'kind') == 'redirect') {
      return RedirectDownload(
        url: Uri.parse(Json.requireString(response, 'url')),
        expiresAt: Json.requireTimestamp(response, 'expiresAt'),
        providerId: Json.requireString(response, 'providerId'),
      );
    }
    return StreamedDownload(
      providerId: Json.optString(response, 'providerId') ?? this.id,
      reason: Json.optString(response, 'reason') ?? 'node cannot presign',
    );
  }

  // ----------------------------------------------------------- downloads ---

  @override
  Future<DownloadRecord> recordDownload({
    required String assetId,
    String? clientAddress,
    String? userAgent,
    String? principalId,
    String? providerId,
    int? bytesServed,
  }) async => DownloadRecord.fromJson(
    await _result(StoreProtocol.downloadRecord, {
      'assetId': assetId,
      'clientAddress': ?clientAddress,
      'userAgent': ?userAgent,
      'principalId': ?principalId,
      'providerId': ?providerId,
      'bytesServed': ?bytesServed,
    }),
  );

  @override
  Future<List<DownloadRecord>> listDownloads(
    String packageReference, {
    int? limit,
    DateTime? from,
    DateTime? to,
  }) async => _list(
    await _call(StoreProtocol.downloadList, {
      'packageReference': packageReference,
      'limit': ?limit,
      'from': ?from?.toIso8601String(),
      'to': ?to?.toIso8601String(),
    }),
    DownloadRecord.fromJson,
  );

  @override
  Future<DownloadStats> downloadStats(
    String packageReference, {
    DateTime? from,
    DateTime? to,
  }) async => StoreProtocol.decodeStats(
    await _result(StoreProtocol.downloadStats, {
      'packageReference': packageReference,
      'from': ?from?.toIso8601String(),
      'to': ?to?.toIso8601String(),
    }),
  );

  // ------------------------------------------------------------- updates ---

  @override
  Future<UpdateInfo> checkForUpdates({
    required String packageReference,
    required Version currentVersion,
    ReleaseChannel? channel,
    String? platform,
  }) async => UpdateInfo.fromJson(
    await _result(StoreProtocol.updateCheck, {
      'packageReference': packageReference,
      'version': currentVersion.toString(),
      'channel': ?channel?.name,
      'platform': ?platform,
    }),
  );

  // ----------------------------------------------------------- providers ---

  @override
  Future<List<ProviderDescriptor>> listProviders({
    String? organization,
  }) async => _list(
    await _call(StoreProtocol.providerList, {'organization': ?organization}),
    ProviderDescriptor.fromJson,
  );

  @override
  Future<void> close() async {}

  // -------------------------------------------------------------- plumbing --

  /// Pulls an open read to exhaustion, closing the node-side session if the
  /// consumer stops early.
  Stream<List<int>> _readChunks(String readId) async* {
    try {
      while (true) {
        final chunk = await _call(StoreProtocol.chunkRead, {
          'readId': readId,
          'maxBytes': chunkBytes,
        });
        if (Json.optBool(chunk, 'eof')) return;
        final data = Json.optString(chunk, 'data') ?? '';
        if (data.isEmpty) return;
        yield base64Decode(data);
      }
    } finally {
      // Runs on cancellation too — a client that aborts a download halfway
      // must not leave an object read pinned open on the node.
      await _closeQuietly(readId);
    }
  }

  Future<void> _sendChunk(String uploadId, List<int> data) => _call(
    StoreProtocol.uploadChunk,
    {'uploadId': uploadId, 'data': base64Encode(data)},
  );

  Future<void> _closeQuietly(String readId) async {
    try {
      await _call(StoreProtocol.chunkClose, {'readId': readId});
    } on Object {
      // The session times out on its own; a failure here must not replace the
      // error the caller is already handling.
    }
  }

  Future<void> _abortQuietly(String uploadId) async {
    try {
      await _call(StoreProtocol.uploadAbort, {'uploadId': uploadId});
    } on Object {
      // Same reasoning as `_closeQuietly`.
    }
  }

  /// Invokes [action], translating a returned error payload back into the
  /// original typed exception.
  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final response = await invoke(action, payload);
    final error = StoreProtocol.exceptionFrom(response);
    if (error != null) throw error;
    return response;
  }

  /// Invokes [action] and returns its non-null `result` object.
  Future<Map<String, dynamic>> _result(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final response = await _call(action, payload);
    final result = response['result'];
    if (result == null) {
      throw ApiException(
        "Node returned no result for '$action'",
        code: ErrorCodes.apiError,
      );
    }
    return Json.asObject(result, 'result');
  }

  static T? _maybe<T>(
    Map<String, dynamic> response,
    T Function(Map<String, dynamic>) parse,
  ) {
    final result = response['result'];
    return result == null ? null : parse(Json.asObject(result, 'result'));
  }

  static List<T> _list<T>(
    Map<String, dynamic> response,
    T Function(Map<String, dynamic>) parse,
  ) => [
    for (final item in Json.asList(response['result'] ?? const [], 'result'))
      parse(Json.asObject(item, 'item')),
  ];
}
