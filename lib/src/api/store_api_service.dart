import 'dart:convert';

import 'package:omnyhub/omnyhub.dart'
    show
        HandlerService,
        HubRequest,
        HubResponse,
        Logger,
        NoopLogger,
        RouterService;

import '../channels/release_channel.dart';
import '../exceptions/omnystore_exception.dart';
import '../models/asset.dart';
import '../repositories/release_query.dart';
import '../services/asset_download.dart';
import '../services/omnystore_api.dart';
import '../storage/object_storage.dart';
import '../utils/json.dart';
import '../utils/version_codec.dart';
import '../version.dart';
import 'api_errors.dart';

/// Builds the `/api/v1` REST surface over any [OmnyStoreApi].
///
/// Because it is written against the interface rather than a concrete store,
/// the same routes serve an embedded single-process registry, a federating hub
/// with a dozen nodes, or (in tests) a store wired to in-memory everything —
/// with no conditional code anywhere in the handlers.
///
/// ## Endpoints
///
/// ```text
/// GET    /health
///
/// GET    /api/v1/organizations                     POST /api/v1/organizations
/// GET    /api/v1/organizations/{id}                PUT  /api/v1/organizations/{id}
/// DELETE /api/v1/organizations/{id}
/// GET    /api/v1/organizations/{id}/projects
/// GET    /api/v1/organizations/{id}/packages
///
/// GET    /api/v1/projects                          POST /api/v1/projects
/// GET    /api/v1/projects/{id}                     PUT  /api/v1/projects/{id}
/// DELETE /api/v1/projects/{id}
/// GET    /api/v1/projects/{id}/packages
///
/// GET    /api/v1/packages                          POST /api/v1/packages
/// GET    /api/v1/packages/{id}                     PUT  /api/v1/packages/{id}
/// DELETE /api/v1/packages/{id}
/// GET    /api/v1/packages/{id}/releases            POST /api/v1/packages/{id}/releases
/// GET    /api/v1/packages/{id}/releases/latest
/// GET    /api/v1/packages/{id}/releases/{version}
/// GET    /api/v1/packages/{id}/updates
/// GET    /api/v1/packages/{id}/downloads
/// GET    /api/v1/packages/{id}/downloads/stats
///
/// GET    /api/v1/releases/{id}                     PUT  /api/v1/releases/{id}
/// DELETE /api/v1/releases/{id}
/// POST   /api/v1/releases/{id}/promote
/// GET    /api/v1/releases/{id}/assets              POST /api/v1/releases/{id}/assets
///
/// GET    /api/v1/assets/{id}                       DELETE /api/v1/assets/{id}
/// GET    /api/v1/assets/{id}/download
///
/// GET    /api/v1/providers
/// ```
///
/// **Downloads redirect when they can.** `GET /assets/{id}/download` answers
/// `302` at a presigned bucket URL if the holding provider can issue one, and
/// streams the bytes itself otherwise — with `Range` and `206 Partial Content`
/// supported either way, so a client can resume an interrupted download.
class StoreApiService {
  const StoreApiService._();

  /// The path prefix every versioned route lives under.
  static const String basePath = '/api/$omnyStoreApiVersion';

  /// The unversioned health-check path.
  static const String healthPath = '/health';

  /// Builds the `GET /health` service.
  ///
  /// Its own service rather than a route on the API router because it lives
  /// *outside* `/api/v1`: the router is mounted at that prefix, so a `/health`
  /// route on it would never be reached. Keeping health unversioned is
  /// deliberate — a load balancer's probe should not have to be updated when
  /// the API version changes.
  static HandlerService health(
    OmnyStoreApi store, {
    String name = 'omnystore-health',
    Logger logger = const NoopLogger(),
  }) => HandlerService(
    name: name,
    mount: healthPath,
    handler: (request) => ApiErrors.guard(
      () async => HubResponse.json({
        'status': 'ok',
        'version': omnyStoreVersion,
        'api': omnyStoreApiVersion,
        'providers': (await store.listProviders()).length,
      }),
      logger: logger,
      request: request,
    ),
  );

  /// Builds the router for [store].
  ///
  /// [writeGuard] is invoked before every mutating request; throw from it to
  /// reject. It is the seam where an application enforces "publishers may
  /// write, everyone may read" without this service knowing anything about the
  /// application's identity model.
  static RouterService build(
    OmnyStoreApi store, {
    String name = 'omnystore-api',
    String mount = basePath,
    Logger logger = const NoopLogger(),
    void Function(HubRequest request)? writeGuard,
    Duration redirectLifetime = const Duration(minutes: 15),
    bool recordDownloads = true,
    bool captureClientAddress = true,
  }) {
    final router = RouterService(name: name, mount: mount);

    /// Wraps [handler] with error rendering, and with the write guard when the
    /// route mutates state.
    Future<HubResponse> Function(HubRequest, Map<String, String>) route(
      Future<HubResponse> Function(HubRequest request, Map<String, String> p)
      handler, {
      bool mutating = false,
    }) =>
        (request, params) => ApiErrors.guard(
          () async {
            if (mutating) writeGuard?.call(request);
            return handler(request, params);
          },
          logger: logger,
          request: request,
        );

    // ------------------------------------------------------ organizations --
    router
      ..get(
        '$basePath/organizations',
        route((request, _) async => _jsonList(await store.listOrganizations())),
      )
      ..post(
        '$basePath/organizations',
        route((request, _) async {
          final body = await _body(request);
          return _jsonOne(
            await store.createOrganization(
              name: Json.requireString(body, 'name'),
              displayName: Json.optString(body, 'displayName'),
              description: Json.optString(body, 'description'),
              website: Json.optString(body, 'website'),
              metadata: Json.optStringMap(body, 'metadata'),
            ),
            statusCode: 201,
          );
        }, mutating: true),
      )
      ..get(
        '$basePath/organizations/<id>',
        route((request, p) async {
          final id = p['id']!;
          final organization =
              await store.organization(id) ??
              await store.organizationByName(id);
          if (organization == null) throw OrganizationNotFoundException(id);
          return _jsonOne(organization);
        }),
      )
      ..put(
        '$basePath/organizations/<id>',
        route((request, p) async {
          final body = await _body(request);
          return _jsonOne(
            await store.updateOrganization(
              p['id']!,
              displayName: Json.optString(body, 'displayName'),
              description: Json.optString(body, 'description'),
              website: Json.optString(body, 'website'),
              metadata: body.containsKey('metadata')
                  ? Json.optStringMap(body, 'metadata')
                  : null,
            ),
          );
        }, mutating: true),
      )
      ..delete(
        '$basePath/organizations/<id>',
        route((request, p) async {
          await store.deleteOrganization(
            p['id']!,
            force: _flag(request, 'force'),
          );
          return HubResponse(statusCode: 204);
        }, mutating: true),
      )
      ..get(
        '$basePath/organizations/<id>/projects',
        route(
          (request, p) async =>
              _jsonList(await store.listProjects(organizationId: p['id']!)),
        ),
      )
      ..get(
        '$basePath/organizations/<id>/packages',
        route(
          (request, p) async =>
              _jsonList(await store.listPackages(organizationId: p['id']!)),
        ),
      );

    // ----------------------------------------------------------- projects --
    router
      ..get(
        '$basePath/projects',
        route(
          (request, _) async => _jsonList(
            await store.listProjects(
              organizationId: request.uri.queryParameters['organizationId'],
            ),
          ),
        ),
      )
      ..post(
        '$basePath/projects',
        route((request, _) async {
          final body = await _body(request);
          return _jsonOne(
            await store.createProject(
              organizationId: Json.requireString(body, 'organizationId'),
              name: Json.requireString(body, 'name'),
              displayName: Json.optString(body, 'displayName'),
              description: Json.optString(body, 'description'),
              repository: Json.optString(body, 'repository'),
              website: Json.optString(body, 'website'),
              metadata: Json.optStringMap(body, 'metadata'),
            ),
            statusCode: 201,
          );
        }, mutating: true),
      )
      ..get(
        '$basePath/projects/<id>',
        route((request, p) async {
          final project = await store.project(p['id']!);
          if (project == null) throw ProjectNotFoundException(p['id']!);
          return _jsonOne(project);
        }),
      )
      ..put(
        '$basePath/projects/<id>',
        route((request, p) async {
          final body = await _body(request);
          return _jsonOne(
            await store.updateProject(
              p['id']!,
              displayName: Json.optString(body, 'displayName'),
              description: Json.optString(body, 'description'),
              repository: Json.optString(body, 'repository'),
              website: Json.optString(body, 'website'),
              metadata: body.containsKey('metadata')
                  ? Json.optStringMap(body, 'metadata')
                  : null,
            ),
          );
        }, mutating: true),
      )
      ..delete(
        '$basePath/projects/<id>',
        route((request, p) async {
          await store.deleteProject(p['id']!, force: _flag(request, 'force'));
          return HubResponse(statusCode: 204);
        }, mutating: true),
      )
      ..get(
        '$basePath/projects/<id>/packages',
        route(
          (request, p) async =>
              _jsonList(await store.listPackages(projectId: p['id']!)),
        ),
      );

    // ----------------------------------------------------------- packages --
    router
      ..get(
        '$basePath/packages',
        route(
          (request, _) async => _jsonList(
            await store.listPackages(
              projectId: request.uri.queryParameters['projectId'],
              organizationId: request.uri.queryParameters['organizationId'],
            ),
          ),
        ),
      )
      ..post(
        '$basePath/packages',
        route((request, _) async {
          final body = await _body(request);
          final channel = Json.optString(body, 'defaultChannel');
          return _jsonOne(
            await store.createPackage(
              projectId: Json.requireString(body, 'projectId'),
              name: Json.requireString(body, 'name'),
              displayName: Json.optString(body, 'displayName'),
              description: Json.optString(body, 'description'),
              defaultChannel: channel == null
                  ? ReleaseChannel.release
                  : ReleaseChannel.parse(channel),
              platforms: Json.optStringList(body, 'platforms'),
              metadata: Json.optStringMap(body, 'metadata'),
            ),
            statusCode: 201,
          );
        }, mutating: true),
      )
      // Registered before `/packages/<id>` so the literal segment wins; the
      // router returns the first matching entry.
      ..get(
        '$basePath/packages/<id>/releases/latest',
        route((request, p) async {
          final channelName = request.uri.queryParameters['channel'];
          final exact = _flag(request, 'exact');
          final release = channelName == null
              ? await store.latestAny(p['id']!)
              : await store.latestChannel(
                  p['id']!,
                  ReleaseChannel.parse(channelName),
                  exact: exact,
                );
          if (release == null) {
            throw ReleaseNotFoundException(
              '${p['id']}@${channelName ?? 'any'}',
            );
          }
          return _jsonOne(release);
        }),
      )
      ..get(
        '$basePath/packages/<id>/releases/<version>',
        route((request, p) async {
          final release = await store.releaseByVersion(
            p['id']!,
            Versions.parse(p['version']!),
          );
          if (release == null) {
            throw ReleaseNotFoundException('${p['id']}@${p['version']}');
          }
          return _jsonOne(release);
        }),
      )
      ..get(
        '$basePath/packages/<id>/releases',
        route(
          (request, p) async => _jsonList(
            await store.listReleases(p['id']!, query: _query(request)),
          ),
        ),
      )
      ..post(
        '$basePath/packages/<id>/releases',
        route((request, p) async {
          final body = await _body(request);
          return _jsonOne(
            await store.publishRelease(
              packageReference: p['id']!,
              version: Versions.parse(Json.requireString(body, 'version')),
              title: Json.optString(body, 'title'),
              notes: Json.optString(body, 'notes'),
              tag: Json.optString(body, 'tag'),
              draft: Json.optBool(body, 'draft'),
              metadata: Json.optStringMap(body, 'metadata'),
            ),
            statusCode: 201,
          );
        }, mutating: true),
      )
      ..get(
        '$basePath/packages/<id>/updates',
        route((request, p) async {
          final query = request.uri.queryParameters;
          final current = query['version'] ?? query['currentVersion'];
          if (current == null) {
            throw const ValidationException(
              "An update check needs the client's current version: pass "
              '?version=1.2.3',
              field: 'version',
            );
          }
          final channel = query['channel'];
          return _jsonOne(
            await store.checkForUpdates(
              packageReference: p['id']!,
              currentVersion: Versions.parse(current),
              channel: channel == null ? null : ReleaseChannel.parse(channel),
              platform: query['platform'],
            ),
          );
        }),
      )
      ..get(
        '$basePath/packages/<id>/downloads/stats',
        route(
          (request, p) async => HubResponse.json({
            'result': (await store.downloadStats(
              p['id']!,
              from: _timestamp(request, 'from'),
              to: _timestamp(request, 'to'),
            )).toJson(),
          }),
        ),
      )
      ..get(
        '$basePath/packages/<id>/downloads',
        route(
          (request, p) async => _jsonList(
            await store.listDownloads(
              p['id']!,
              limit: _int(request, 'limit'),
              from: _timestamp(request, 'from'),
              to: _timestamp(request, 'to'),
            ),
          ),
        ),
      )
      ..get(
        '$basePath/packages/<id>',
        route(
          (request, p) async => _jsonOne(await store.resolvePackage(p['id']!)),
        ),
      )
      ..put(
        '$basePath/packages/<id>',
        route((request, p) async {
          final body = await _body(request);
          final channel = Json.optString(body, 'defaultChannel');
          return _jsonOne(
            await store.updatePackage(
              p['id']!,
              displayName: Json.optString(body, 'displayName'),
              description: Json.optString(body, 'description'),
              defaultChannel: channel == null
                  ? null
                  : ReleaseChannel.parse(channel),
              platforms: body.containsKey('platforms')
                  ? Json.optStringList(body, 'platforms')
                  : null,
              metadata: body.containsKey('metadata')
                  ? Json.optStringMap(body, 'metadata')
                  : null,
            ),
          );
        }, mutating: true),
      )
      ..delete(
        '$basePath/packages/<id>',
        route((request, p) async {
          await store.deletePackage(p['id']!, force: _flag(request, 'force'));
          return HubResponse(statusCode: 204);
        }, mutating: true),
      );

    // ----------------------------------------------------------- releases --
    router
      ..get(
        '$basePath/releases/<id>/assets',
        route(
          (request, p) async => _jsonList(await store.listAssets(p['id']!)),
        ),
      )
      ..post(
        '$basePath/releases/<id>/assets',
        route((request, p) async {
          final query = request.uri.queryParameters;
          final name = query['name'];
          if (name == null) {
            throw const ValidationException(
              'An asset upload needs a filename: pass ?name=agent-linux.tar.gz',
              field: 'name',
            );
          }
          return _jsonOne(
            await store.attachAsset(
              releaseId: p['id']!,
              name: name,
              // Streamed straight through: a multi-gigabyte installer must
              // never be buffered in the server's heap on its way to storage.
              data: request.read(),
              length: int.tryParse(request.header('content-length') ?? ''),
              contentType:
                  request.header('content-type') ?? 'application/octet-stream',
              expectedSha256: query['sha256'],
              platform: query['platform'],
              kind: query['kind'],
            ),
            statusCode: 201,
          );
        }, mutating: true),
      )
      ..post(
        '$basePath/releases/<id>/promote',
        route((request, p) async {
          final body = await _body(request);
          return _jsonOne(
            await store.promoteRelease(
              p['id']!,
              ReleaseChannel.parse(Json.requireString(body, 'channel')),
              notes: Json.optString(body, 'notes'),
            ),
            statusCode: 201,
          );
        }, mutating: true),
      )
      ..get(
        '$basePath/releases/<id>',
        route((request, p) async {
          final release = await store.release(p['id']!);
          if (release == null) throw ReleaseNotFoundException(p['id']!);
          return _jsonOne(release);
        }),
      )
      ..put(
        '$basePath/releases/<id>',
        route((request, p) async {
          final body = await _body(request);
          return _jsonOne(
            await store.updateRelease(
              p['id']!,
              title: Json.optString(body, 'title'),
              notes: Json.optString(body, 'notes'),
              tag: Json.optString(body, 'tag'),
              draft: body.containsKey('draft')
                  ? Json.optBool(body, 'draft')
                  : null,
              yanked: body.containsKey('yanked')
                  ? Json.optBool(body, 'yanked')
                  : null,
              yankedReason: Json.optString(body, 'yankedReason'),
              metadata: body.containsKey('metadata')
                  ? Json.optStringMap(body, 'metadata')
                  : null,
            ),
          );
        }, mutating: true),
      )
      ..delete(
        '$basePath/releases/<id>',
        route((request, p) async {
          await store.deleteRelease(p['id']!);
          return HubResponse(statusCode: 204);
        }, mutating: true),
      );

    // ------------------------------------------------------------- assets --
    router
      ..get(
        '$basePath/assets/<id>/download',
        route(
          (request, p) => _download(
            store,
            request,
            p['id']!,
            redirectLifetime: redirectLifetime,
            recordDownloads: recordDownloads,
            captureClientAddress: captureClientAddress,
            logger: logger,
          ),
        ),
      )
      ..get(
        '$basePath/assets/<id>',
        route((request, p) async {
          final asset = await store.asset(p['id']!);
          if (asset == null) throw AssetNotFoundException(p['id']!);
          return _jsonOne(asset);
        }),
      )
      ..delete(
        '$basePath/assets/<id>',
        route((request, p) async {
          await store.deleteAsset(p['id']!);
          return HubResponse(statusCode: 204);
        }, mutating: true),
      );

    // ---------------------------------------------------------- providers --
    router.get(
      '$basePath/providers',
      route(
        (request, _) async => _jsonList(
          await store.listProviders(
            organization: request.uri.queryParameters['organization'],
          ),
        ),
      ),
    );

    return router;
  }

  /// Serves an asset: a redirect when the provider can issue a URL, otherwise
  /// the bytes themselves.
  static Future<HubResponse> _download(
    OmnyStoreApi store,
    HubRequest request,
    String assetId, {
    required Duration redirectLifetime,
    required bool recordDownloads,
    required bool captureClientAddress,
    required Logger logger,
  }) async {
    final range = ByteRange.parseHeader(request.header('range'));

    // A ranged request has to be served by this process: the presigned URL is
    // for the whole object, and redirecting would silently ignore the range a
    // resuming client asked for.
    if (range == null) {
      final target = await store.downloadTarget(
        assetId,
        expiresIn: redirectLifetime,
      );
      if (target is RedirectDownload) {
        if (recordDownloads) {
          await _record(
            store,
            request,
            assetId,
            providerId: target.providerId,
            bytesServed: null,
            captureClientAddress: captureClientAddress,
            logger: logger,
          );
        }
        return HubResponse(
          statusCode: 302,
          headers: {
            'location': target.url.toString(),
            'cache-control': 'no-store',
          },
        );
      }
    }

    final download = await store.openAsset(assetId, range: range);
    if (recordDownloads) {
      await _record(
        store,
        request,
        assetId,
        providerId: download.providerId,
        bytesServed: download.length,
        captureClientAddress: captureClientAddress,
        logger: logger,
      );
    }

    return HubResponse.stream(
      download.stream,
      statusCode: download.isPartial ? 206 : 200,
      headers: {
        'content-type': download.contentType,
        'content-length': '${download.length}',
        // Advertised so a download manager knows it may resume rather than
        // restarting a multi-gigabyte artifact from zero.
        'accept-ranges': 'bytes',
        'content-disposition':
            'attachment; filename="${_sanitize(download.asset.name)}"',
        'x-omnystore-sha256': download.asset.sha256,
        if (download.range != null)
          'content-range': download.range!.toContentRange(
            download.asset.sizeBytes,
          ),
      },
    );
  }

  /// Records a download, never failing the download itself.
  ///
  /// Analytics are not worth a `500` on an artifact fetch: if the record cannot
  /// be written, the bytes should still be served.
  static Future<void> _record(
    OmnyStoreApi store,
    HubRequest request,
    String assetId, {
    required String? providerId,
    required int? bytesServed,
    required bool captureClientAddress,
    required Logger logger,
  }) async {
    try {
      await store.recordDownload(
        assetId: assetId,
        clientAddress: captureClientAddress ? _clientAddress(request) : null,
        userAgent: request.header('user-agent'),
        principalId: request.principal?.id,
        providerId: providerId,
        bytesServed: bytesServed,
      );
    } on Object catch (e) {
      logger.warn(
        'Could not record download',
        context: {'asset': assetId, 'error': '$e'},
      );
    }
  }

  /// The caller's address, preferring the left-most `x-forwarded-for` entry
  /// when the registry sits behind a proxy.
  ///
  /// Only trust this when a proxy you control sets the header — a direct client
  /// can send whatever it likes.
  static String? _clientAddress(HubRequest request) {
    final forwarded = request.header('x-forwarded-for');
    if (forwarded != null && forwarded.isNotEmpty) {
      return forwarded.split(',').first.trim();
    }
    return request.remoteAddress;
  }

  // ------------------------------------------------------------- helpers ---

  static Future<Map<String, dynamic>> _body(HubRequest request) async {
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) return const {};
    return Json.asObject(jsonDecode(raw), 'request body');
  }

  static HubResponse _jsonOne(dynamic model, {int statusCode = 200}) =>
      HubResponse.json({
        'result': (model as dynamic).toJson(),
      }, statusCode: statusCode);

  static HubResponse _jsonList(List<dynamic> models) => HubResponse.json({
    'result': [for (final model in models) (model as dynamic).toJson()],
    'count': models.length,
  });

  static ReleaseQuery _query(HubRequest request) {
    final query = request.uri.queryParameters;
    final channel = query['channel'];
    final acceptedBy = query['acceptedBy'];
    return ReleaseQuery(
      channel: channel == null ? null : ReleaseChannel.parse(channel),
      acceptedBy: acceptedBy == null ? null : ReleaseChannel.parse(acceptedBy),
      includeDrafts: query['includeDrafts'] == 'true',
      includeYanked: query['includeYanked'] == 'true',
      includeUnpublished: query['includeUnpublished'] == 'true',
      limit: int.tryParse(query['limit'] ?? ''),
      offset: int.tryParse(query['offset'] ?? '') ?? 0,
    );
  }

  static bool _flag(HubRequest request, String name) =>
      request.uri.queryParameters[name] == 'true';

  static int? _int(HubRequest request, String name) =>
      int.tryParse(request.uri.queryParameters[name] ?? '');

  static DateTime? _timestamp(HubRequest request, String name) {
    final raw = request.uri.queryParameters[name];
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw ValidationException(
        "Invalid timestamp '$raw' for '$name': expected ISO-8601",
        field: name,
      );
    }
    return parsed.toUtc();
  }

  /// Strips quotes and control characters bound for a `content-disposition`
  /// header, where an unescaped quote would let the rest of the header be
  /// rewritten by a crafted asset name.
  static String _sanitize(String filename) =>
      filename.replaceAll(RegExp(r'[\x00-\x1f"\\]'), '');
}

/// Convenience for the tests and for callers building a response themselves.
extension AssetResponseHeaders on Asset {
  /// The headers a download of this asset should carry.
  Map<String, String> get downloadHeaders => {
    'content-type': contentType,
    'content-length': '$sizeBytes',
    'accept-ranges': 'bytes',
    'x-omnystore-sha256': sha256,
  };
}
