import 'dart:async';
import 'dart:convert';

import 'package:omnyhub/omnyhub.dart' show IdGenerator, RandomIdGenerator;

import '../channels/release_channel.dart';
import '../exceptions/omnystore_exception.dart';
import '../models/asset.dart';
import '../models/provider_descriptor.dart';
import '../services/asset_download.dart';
import '../services/omnystore_api.dart';
import '../utils/json.dart';
import '../utils/version_codec.dart';
import 'store_protocol.dart';

/// Answers [StoreProtocol] RPCs against a local [OmnyStoreApi].
///
/// This is the node's half of the control plane. `OmnyStoreNode` hands every
/// inbound action from the hub to [handle]; the hub's `RemoteNodeStoreProvider`
/// is the exact mirror, turning [OmnyStoreApi] calls back into these actions.
/// Keeping the two symmetric in one protocol is what lets the hub treat a
/// remote node and an in-process store as the same thing.
///
/// **Streams become sessions.** [OmnyStoreApi] deals in byte streams, and an
/// RPC channel deals in discrete messages, so a download becomes an open/read/
/// close session and an upload a begin/chunk/commit one. Sessions hold real
/// resources — an open object read, an in-flight upload — so they time out:
/// a hub that dies mid-download must not leak a file handle on every node it
/// was talking to.
class StoreRpcServer {
  /// The store being exposed.
  final OmnyStoreApi store;

  /// Supplies session identifiers.
  final IdGenerator idGenerator;

  /// How long an idle read or upload session survives before being reclaimed.
  final Duration sessionTimeout;

  /// Describes this node as a provider. Called for [StoreProtocol.describe].
  final Future<ProviderDescriptor> Function() describeProvider;

  final Map<String, _ReadSession> _reads = {};
  final Map<String, _UploadSession> _uploads = {};

  /// Creates a server over [store].
  StoreRpcServer({
    required this.store,
    required this.describeProvider,
    IdGenerator? idGenerator,
    this.sessionTimeout = const Duration(minutes: 10),
  }) : idGenerator = idGenerator ?? RandomIdGenerator();

  /// The number of open download sessions, for tests and diagnostics.
  int get openReads => _reads.length;

  /// The number of in-flight upload sessions.
  int get openUploads => _uploads.length;

  /// Handles [action] with [payload], returning the response payload.
  ///
  /// A thrown [OmnyStoreException] is rendered into the payload rather than
  /// propagated, so the hub can reconstruct the original typed exception
  /// instead of receiving an opaque transport failure.
  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> payload,
  ) async {
    try {
      return await _dispatch(action, payload);
    } on OmnyStoreException catch (e) {
      return StoreProtocol.encodeException(e);
    }
  }

  Future<Map<String, dynamic>> _dispatch(
    String action,
    Map<String, dynamic> p,
  ) async {
    switch (action) {
      case StoreProtocol.describe:
        return {'provider': (await describeProvider()).toJson()};

      // ------------------------------------------------------------ orgs --
      case StoreProtocol.organizationCreate:
        return _one(
          await store.createOrganization(
            name: Json.requireString(p, 'name'),
            displayName: Json.optString(p, 'displayName'),
            description: Json.optString(p, 'description'),
            website: Json.optString(p, 'website'),
            metadata: Json.optStringMap(p, 'metadata'),
          ),
        );
      case StoreProtocol.organizationGet:
        return _maybe(await store.organization(Json.requireString(p, 'id')));
      case StoreProtocol.organizationByName:
        return _maybe(
          await store.organizationByName(Json.requireString(p, 'name')),
        );
      case StoreProtocol.organizationList:
        return _many(await store.listOrganizations());
      case StoreProtocol.organizationUpdate:
        return _one(
          await store.updateOrganization(
            Json.requireString(p, 'id'),
            displayName: Json.optString(p, 'displayName'),
            description: Json.optString(p, 'description'),
            website: Json.optString(p, 'website'),
            metadata: p.containsKey('metadata')
                ? Json.optStringMap(p, 'metadata')
                : null,
          ),
        );
      case StoreProtocol.organizationDelete:
        await store.deleteOrganization(
          Json.requireString(p, 'id'),
          force: Json.optBool(p, 'force'),
        );
        return const {'ok': true};

      // -------------------------------------------------------- projects --
      case StoreProtocol.projectCreate:
        return _one(
          await store.createProject(
            organizationId: Json.requireString(p, 'organizationId'),
            name: Json.requireString(p, 'name'),
            displayName: Json.optString(p, 'displayName'),
            description: Json.optString(p, 'description'),
            repository: Json.optString(p, 'repository'),
            website: Json.optString(p, 'website'),
            metadata: Json.optStringMap(p, 'metadata'),
          ),
        );
      case StoreProtocol.projectGet:
        return _maybe(await store.project(Json.requireString(p, 'id')));
      case StoreProtocol.projectByName:
        return _maybe(
          await store.projectByName(
            Json.requireString(p, 'organizationId'),
            Json.requireString(p, 'name'),
          ),
        );
      case StoreProtocol.projectList:
        return _many(
          await store.listProjects(
            organizationId: Json.optString(p, 'organizationId'),
          ),
        );
      case StoreProtocol.projectUpdate:
        return _one(
          await store.updateProject(
            Json.requireString(p, 'id'),
            displayName: Json.optString(p, 'displayName'),
            description: Json.optString(p, 'description'),
            repository: Json.optString(p, 'repository'),
            website: Json.optString(p, 'website'),
            metadata: p.containsKey('metadata')
                ? Json.optStringMap(p, 'metadata')
                : null,
          ),
        );
      case StoreProtocol.projectDelete:
        await store.deleteProject(
          Json.requireString(p, 'id'),
          force: Json.optBool(p, 'force'),
        );
        return const {'ok': true};

      // -------------------------------------------------------- packages --
      case StoreProtocol.packageCreate:
        return _one(
          await store.createPackage(
            projectId: Json.requireString(p, 'projectId'),
            name: Json.requireString(p, 'name'),
            displayName: Json.optString(p, 'displayName'),
            description: Json.optString(p, 'description'),
            defaultChannel: ReleaseChannel.parse(
              Json.optString(p, 'defaultChannel', 'release')!,
            ),
            platforms: Json.optStringList(p, 'platforms'),
            metadata: Json.optStringMap(p, 'metadata'),
          ),
        );
      case StoreProtocol.packageGet:
        return _maybe(await store.package(Json.requireString(p, 'id')));
      case StoreProtocol.packageByName:
        return _maybe(
          await store.packageByName(
            Json.requireString(p, 'projectId'),
            Json.requireString(p, 'name'),
          ),
        );
      case StoreProtocol.packageResolve:
        return _one(
          await store.resolvePackage(Json.requireString(p, 'reference')),
        );
      case StoreProtocol.packageList:
        return _many(
          await store.listPackages(
            projectId: Json.optString(p, 'projectId'),
            organizationId: Json.optString(p, 'organizationId'),
          ),
        );
      case StoreProtocol.packageUpdate:
        final channel = Json.optString(p, 'defaultChannel');
        return _one(
          await store.updatePackage(
            Json.requireString(p, 'id'),
            displayName: Json.optString(p, 'displayName'),
            description: Json.optString(p, 'description'),
            defaultChannel: channel == null
                ? null
                : ReleaseChannel.parse(channel),
            platforms: p.containsKey('platforms')
                ? Json.optStringList(p, 'platforms')
                : null,
            metadata: p.containsKey('metadata')
                ? Json.optStringMap(p, 'metadata')
                : null,
          ),
        );
      case StoreProtocol.packageDelete:
        await store.deletePackage(
          Json.requireString(p, 'id'),
          force: Json.optBool(p, 'force'),
        );
        return const {'ok': true};

      // -------------------------------------------------------- releases --
      case StoreProtocol.releasePublish:
        return _one(
          await store.publishRelease(
            packageReference: Json.requireString(p, 'packageReference'),
            version: Versions.parse(Json.requireString(p, 'version')),
            title: Json.optString(p, 'title'),
            notes: Json.optString(p, 'notes'),
            tag: Json.optString(p, 'tag'),
            draft: Json.optBool(p, 'draft'),
            metadata: Json.optStringMap(p, 'metadata'),
          ),
        );
      case StoreProtocol.releaseGet:
        return _maybe(await store.release(Json.requireString(p, 'id')));
      case StoreProtocol.releaseByVersion:
        return _maybe(
          await store.releaseByVersion(
            Json.requireString(p, 'packageReference'),
            Versions.parse(Json.requireString(p, 'version')),
          ),
        );
      case StoreProtocol.releaseList:
        return _many(
          await store.listReleases(
            Json.requireString(p, 'packageReference'),
            query: StoreProtocol.decodeQuery(p),
          ),
        );
      case StoreProtocol.releaseUpdate:
        return _one(
          await store.updateRelease(
            Json.requireString(p, 'id'),
            title: Json.optString(p, 'title'),
            notes: Json.optString(p, 'notes'),
            tag: Json.optString(p, 'tag'),
            draft: p.containsKey('draft') ? Json.optBool(p, 'draft') : null,
            yanked: p.containsKey('yanked') ? Json.optBool(p, 'yanked') : null,
            yankedReason: Json.optString(p, 'yankedReason'),
            metadata: p.containsKey('metadata')
                ? Json.optStringMap(p, 'metadata')
                : null,
          ),
        );
      case StoreProtocol.releaseDelete:
        await store.deleteRelease(Json.requireString(p, 'id'));
        return const {'ok': true};
      case StoreProtocol.releaseLatest:
        final reference = Json.requireString(p, 'packageReference');
        final channel = Json.optString(p, 'channel');
        return _maybe(
          channel == null
              ? await store.latestAny(reference)
              : await store.latestChannel(
                  reference,
                  ReleaseChannel.parse(channel),
                  exact: Json.optBool(p, 'exact'),
                ),
        );
      case StoreProtocol.releasePromote:
        return _one(
          await store.promoteRelease(
            Json.requireString(p, 'id'),
            ReleaseChannel.parse(Json.requireString(p, 'channel')),
            notes: Json.optString(p, 'notes'),
          ),
        );

      // ---------------------------------------------------------- assets --
      case StoreProtocol.assetGet:
        return _maybe(await store.asset(Json.requireString(p, 'id')));
      case StoreProtocol.assetByName:
        return _maybe(
          await store.assetByName(
            Json.requireString(p, 'releaseId'),
            Json.requireString(p, 'name'),
          ),
        );
      case StoreProtocol.assetList:
        return _many(
          await store.listAssets(Json.requireString(p, 'releaseId')),
        );
      case StoreProtocol.assetDelete:
        await store.deleteAsset(Json.requireString(p, 'id'));
        return const {'ok': true};
      case StoreProtocol.assetDownloadTarget:
        final target = await store.downloadTarget(
          Json.requireString(p, 'id'),
          expiresIn: Duration(seconds: Json.optInt(p, 'expiresIn', 900)!),
        );
        return switch (target) {
          RedirectDownload(:final url, :final expiresAt, :final providerId) => {
            'kind': 'redirect',
            'url': url.toString(),
            'expiresAt': expiresAt.toIso8601String(),
            'providerId': providerId,
          },
          StreamedDownload(:final providerId, :final reason) => {
            'kind': 'stream',
            'providerId': providerId,
            'reason': reason,
          },
        };

      // ---------------------------------------------------- relay: read --
      case StoreProtocol.chunkOpen:
        return _openRead(p);
      case StoreProtocol.chunkRead:
        return _readChunk(p);
      case StoreProtocol.chunkClose:
        _closeRead(Json.requireString(p, 'readId'));
        return const {'ok': true};

      // -------------------------------------------------- relay: upload --
      case StoreProtocol.uploadBegin:
        return _beginUpload(p);
      case StoreProtocol.uploadChunk:
        return _uploadChunk(p);
      case StoreProtocol.uploadCommit:
        return _commitUpload(p);
      case StoreProtocol.uploadAbort:
        await _abortUpload(Json.requireString(p, 'uploadId'), 'aborted by hub');
        return const {'ok': true};

      // ------------------------------------------------------- downloads --
      case StoreProtocol.downloadRecord:
        return _one(
          await store.recordDownload(
            assetId: Json.requireString(p, 'assetId'),
            clientAddress: Json.optString(p, 'clientAddress'),
            userAgent: Json.optString(p, 'userAgent'),
            principalId: Json.optString(p, 'principalId'),
            providerId: Json.optString(p, 'providerId'),
            bytesServed: Json.optInt(p, 'bytesServed'),
          ),
        );
      case StoreProtocol.downloadList:
        return _many(
          await store.listDownloads(
            Json.requireString(p, 'packageReference'),
            limit: Json.optInt(p, 'limit'),
            from: Json.optTimestamp(p, 'from'),
            to: Json.optTimestamp(p, 'to'),
          ),
        );
      case StoreProtocol.downloadStats:
        return {
          'result': StoreProtocol.encodeStats(
            await store.downloadStats(
              Json.requireString(p, 'packageReference'),
              from: Json.optTimestamp(p, 'from'),
              to: Json.optTimestamp(p, 'to'),
            ),
          ),
        };

      // --------------------------------------------------------- updates --
      case StoreProtocol.updateCheck:
        final channel = Json.optString(p, 'channel');
        return _one(
          await store.checkForUpdates(
            packageReference: Json.requireString(p, 'packageReference'),
            currentVersion: Versions.parse(Json.requireString(p, 'version')),
            channel: channel == null ? null : ReleaseChannel.parse(channel),
            platform: Json.optString(p, 'platform'),
          ),
        );

      // ------------------------------------------------------- providers --
      case StoreProtocol.providerList:
        return _many(
          await store.listProviders(
            organization: Json.optString(p, 'organization'),
          ),
        );

      default:
        throw ValidationException(
          "Unknown store action '$action'",
          field: 'action',
        );
    }
  }

  /// Closes every open session. Called when the node stops or the hub
  /// connection drops — an orphaned session would otherwise hold its object
  /// read open until it timed out.
  Future<void> closeSessions() async {
    for (final id in _reads.keys.toList()) {
      _closeRead(id);
    }
    for (final id in _uploads.keys.toList()) {
      await _abortUpload(id, 'connection closed');
    }
  }

  // ----------------------------------------------------------- sessions ---

  Future<Map<String, dynamic>> _openRead(Map<String, dynamic> p) async {
    final download = await store.openAsset(
      Json.requireString(p, 'id'),
      range: StoreProtocol.decodeRange(p),
    );
    final readId = idGenerator.next('read');
    _reads[readId] = _ReadSession(
      download,
      onExpire: () => _closeRead(readId),
      timeout: sessionTimeout,
    );
    return {
      'readId': readId,
      'length': download.length,
      'asset': download.asset.toJson(),
      'providerId': ?download.providerId,
    };
  }

  Future<Map<String, dynamic>> _readChunk(Map<String, dynamic> p) async {
    final readId = Json.requireString(p, 'readId');
    final session = _reads[readId];
    if (session == null) {
      throw ValidationException(
        'Read session $readId is not open; it may have timed out',
        field: 'readId',
      );
    }
    final maxBytes = (Json.optInt(
      p,
      'maxBytes',
      StoreProtocol.defaultChunkBytes,
    )!).clamp(1, StoreProtocol.maxChunkBytes);

    final chunk = await session.next(maxBytes);
    if (chunk == null) {
      _closeRead(readId);
      return const {'eof': true, 'data': ''};
    }
    return {'eof': false, 'data': base64Encode(chunk)};
  }

  void _closeRead(String readId) => _reads.remove(readId)?.dispose();

  Future<Map<String, dynamic>> _beginUpload(Map<String, dynamic> p) async {
    final uploadId = idGenerator.next('upload');
    final chunks = StreamController<List<int>>();

    // `attachAsset` consumes the stream as chunks arrive, so the artifact is
    // never held whole on the node. The future settles on commit.
    final pending = store.attachAsset(
      releaseId: Json.requireString(p, 'releaseId'),
      name: Json.requireString(p, 'name'),
      data: chunks.stream,
      length: Json.optInt(p, 'length'),
      contentType: Json.optString(
        p,
        'contentType',
        'application/octet-stream',
      )!,
      expectedSha256: Json.optString(p, 'expectedSha256'),
      platform: Json.optString(p, 'platform'),
      kind: Json.optString(p, 'kind'),
      metadata: Json.optStringMap(p, 'metadata'),
    );
    // The failure is surfaced on commit; without this the future would be an
    // unhandled async error the moment `attachAsset` rejects the release id.
    pending.ignore();

    _uploads[uploadId] = _UploadSession(
      chunks,
      pending,
      onExpire: () => _abortUpload(uploadId, 'upload timed out'),
      timeout: sessionTimeout,
    );
    return {'uploadId': uploadId};
  }

  Future<Map<String, dynamic>> _uploadChunk(Map<String, dynamic> p) async {
    final uploadId = Json.requireString(p, 'uploadId');
    final session = _uploads[uploadId];
    if (session == null) {
      throw ValidationException(
        'Upload session $uploadId is not open; it may have timed out',
        field: 'uploadId',
      );
    }
    final data = base64Decode(Json.requireString(p, 'data'));
    if (data.length > StoreProtocol.maxChunkBytes) {
      await _abortUpload(uploadId, 'chunk too large');
      throw ValidationException(
        'Chunk of ${data.length} bytes exceeds the '
        '${StoreProtocol.maxChunkBytes}-byte limit',
        field: 'data',
      );
    }
    session.add(data);
    return {'received': session.received};
  }

  Future<Map<String, dynamic>> _commitUpload(Map<String, dynamic> p) async {
    final uploadId = Json.requireString(p, 'uploadId');
    final session = _uploads.remove(uploadId);
    if (session == null) {
      throw ValidationException(
        'Upload session $uploadId is not open; it may have timed out',
        field: 'uploadId',
      );
    }
    final Asset asset;
    try {
      asset = await session.commit();
    } finally {
      session.dispose();
    }
    return _one(asset);
  }

  Future<void> _abortUpload(String uploadId, String reason) async {
    final session = _uploads.remove(uploadId);
    if (session == null) return;
    await session.abort(reason);
    session.dispose();
  }

  // ------------------------------------------------------------- shaping ---

  static Map<String, dynamic> _one(dynamic model) => {
    'result': (model as dynamic).toJson(),
  };

  static Map<String, dynamic> _maybe(dynamic model) => {
    'result': model == null ? null : (model as dynamic).toJson(),
  };

  static Map<String, dynamic> _many(List<dynamic> models) => {
    'result': [for (final model in models) (model as dynamic).toJson()],
  };
}

/// One open download, pulled chunk by chunk by the hub.
class _ReadSession {
  final StreamIterator<List<int>> _chunks;
  final Duration _timeout;
  final void Function() _onExpire;

  Timer? _expiry;
  List<int> _pending = const [];

  _ReadSession(
    AssetDownload download, {
    required void Function() onExpire,
    required Duration timeout,
  }) : _chunks = StreamIterator(download.stream),
       _onExpire = onExpire,
       _timeout = timeout {
    _touch();
  }

  /// The next chunk of at most [maxBytes], or `null` at end of stream.
  ///
  /// The source stream's chunk boundaries are whatever the object store
  /// produced — a local file yields 64 KiB blocks, S3 yields whatever the
  /// socket delivered — so they are re-split here to the size the hub asked
  /// for. Without that, one oversized chunk from a backend could exceed the
  /// protocol's frame limit.
  Future<List<int>?> next(int maxBytes) async {
    _touch();
    if (_pending.isEmpty) {
      if (!await _chunks.moveNext()) return null;
      _pending = _chunks.current;
    }
    if (_pending.length <= maxBytes) {
      final chunk = _pending;
      _pending = const [];
      return chunk;
    }
    final chunk = _pending.sublist(0, maxBytes);
    _pending = _pending.sublist(maxBytes);
    return chunk;
  }

  void _touch() {
    _expiry?.cancel();
    _expiry = Timer(_timeout, _onExpire);
  }

  void dispose() {
    _expiry?.cancel();
    _expiry = null;
    _chunks.cancel();
  }
}

/// One in-flight upload, fed chunk by chunk by the hub.
class _UploadSession {
  final StreamController<List<int>> _chunks;
  final Future<Asset> _pending;
  final Duration _timeout;
  final void Function() _onExpire;

  Timer? _expiry;
  int received = 0;

  _UploadSession(
    this._chunks,
    this._pending, {
    required void Function() onExpire,
    required Duration timeout,
  }) : _onExpire = onExpire,
       _timeout = timeout {
    _touch();
  }

  void add(List<int> data) {
    _touch();
    received += data.length;
    _chunks.add(data);
  }

  Future<Asset> commit() async {
    await _chunks.close();
    return _pending;
  }

  Future<void> abort(String reason) async {
    // Erroring the stream makes `attachAsset` fail, which unwinds the partial
    // object out of storage — a commit-or-nothing guarantee even when the hub
    // vanishes mid-upload.
    _chunks.addError(StorageException('Upload aborted: $reason'));
    await _chunks.close();
    try {
      await _pending;
    } on Object {
      // Expected: the abort above is what failed it.
    }
  }

  void _touch() {
    _expiry?.cancel();
    _expiry = Timer(_timeout, _onExpire);
  }

  void dispose() {
    _expiry?.cancel();
    _expiry = null;
  }
}
