import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../auth/auth_provider.dart';
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
import '../utils/checksum.dart';
import '../utils/json.dart';
import '../version.dart';

/// The client SDK: an [OmnyStoreApi] backed by a remote OmnyStore server.
///
/// **Web-compatible.** Nothing here imports `dart:io`; the only transport is
/// `package:http`, so the same code runs on the Dart VM, in Flutter, and
/// compiled to JavaScript in a browser.
///
/// ```dart
/// final client = OmnyStoreClient(baseUrl: 'https://store.example.com');
///
/// final latest = await client.latestRelease('omnyagent');
/// final update = await client.checkForUpdates(
///   packageReference: 'omnyagent',
///   currentVersion: Version.parse('1.0.0'),
///   channel: ReleaseChannel.beta,
///   platform: 'macos-arm64',
/// );
/// if (update.isInstallable) {
///   final bytes = await client.downloadAsset(update.asset!.id);
/// }
/// ```
///
/// **Errors keep their type across the network.** The server sends a code with
/// every failure and this client rebuilds the original exception from it, so
/// `on ReleaseNotFoundException` and `on ChecksumMismatchException` work
/// exactly as they do against an embedded store. That is what lets code written
/// against [OmnyStoreApi] move between embedded and remote with no changes.
///
/// **Uploads.** [attachAsset] streams on the VM. In a browser the underlying
/// HTTP client cannot stream a request body, so the artifact is buffered first
/// — fine for the sizes a browser uploads, and the reason CI publishing should
/// run on the VM.
class OmnyStoreClient implements OmnyStoreApi {
  /// The server's base URL (`https://store.example.com`), without the
  /// `/api/v1` suffix.
  final Uri baseUrl;

  /// Supplies credentials for each request.
  final AuthProvider auth;

  /// How long to wait for a response before giving up.
  final Duration timeout;

  /// The `user-agent` sent with every request.
  final String userAgent;

  final http.Client _http;
  final bool _ownsClient;

  /// Creates a client for the server at [baseUrl].
  ///
  /// Pass [httpClient] to share a connection pool, to install retries, or to
  /// supply a `MockClient` in tests. When omitted, one is created and closed by
  /// [close].
  OmnyStoreClient({
    required Object baseUrl,
    this.auth = const AnonymousAuthProvider(),
    this.timeout = const Duration(seconds: 30),
    String? userAgent,
    http.Client? httpClient,
  }) : baseUrl = _normalizeBase(baseUrl),
       userAgent = userAgent ?? 'omnystore-client/$omnyStoreVersion',
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// The base path every versioned endpoint hangs off.
  String get apiPath => '/api/$omnyStoreApiVersion';

  /// The URL an artifact is fetched from.
  ///
  /// A plain URL rather than a request: a download manager, a browser or
  /// `curl` can use it directly, and the server answers it with either the
  /// bytes or a redirect to wherever the holding provider keeps them.
  Uri assetDownloadUrl(String assetId) =>
      _url('$apiPath/assets/$assetId/download');

  /// The server's health document.
  ///
  /// Cheap and unauthenticated: use it as a readiness probe, and to discover
  /// the server's version before relying on a newer endpoint.
  Future<Map<String, dynamic>> health() async {
    final response = await _send('GET', _url('/health'));
    return Json.asObject(jsonDecode(response.body), 'health');
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
    await _postJson('$apiPath/organizations', {
      'name': name,
      'displayName': ?displayName,
      'description': ?description,
      'website': ?website,
      'metadata': metadata,
    }),
  );

  @override
  Future<Organization?> organization(String id) =>
      _getMaybe('$apiPath/organizations/$id', Organization.fromJson);

  @override
  Future<Organization?> organizationByName(String name) =>
      // The server resolves an organization by id *or* name on the same route,
      // so a name lookup needs no separate endpoint.
      _getMaybe('$apiPath/organizations/$name', Organization.fromJson);

  @override
  Future<List<Organization>> listOrganizations() =>
      _getList('$apiPath/organizations', Organization.fromJson);

  @override
  Future<Organization> updateOrganization(
    String id, {
    String? displayName,
    String? description,
    String? website,
    Map<String, String>? metadata,
  }) async => Organization.fromJson(
    await _putJson('$apiPath/organizations/$id', {
      'displayName': ?displayName,
      'description': ?description,
      'website': ?website,
      'metadata': ?metadata,
    }),
  );

  @override
  Future<void> deleteOrganization(String id, {bool force = false}) =>
      _delete('$apiPath/organizations/$id', {'force': '$force'});

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
    await _postJson('$apiPath/projects', {
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
  Future<Project?> project(String id) =>
      _getMaybe('$apiPath/projects/$id', Project.fromJson);

  @override
  Future<Project?> projectByName(String organizationId, String name) async {
    final projects = await listProjects(organizationId: organizationId);
    for (final project in projects) {
      if (project.name == name) return project;
    }
    return null;
  }

  @override
  Future<List<Project>> listProjects({String? organizationId}) => _getList(
    '$apiPath/projects',
    Project.fromJson,
    query: {'organizationId': ?organizationId},
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
    await _putJson('$apiPath/projects/$id', {
      'displayName': ?displayName,
      'description': ?description,
      'repository': ?repository,
      'website': ?website,
      'metadata': ?metadata,
    }),
  );

  @override
  Future<void> deleteProject(String id, {bool force = false}) =>
      _delete('$apiPath/projects/$id', {'force': '$force'});

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
    await _postJson('$apiPath/packages', {
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
  Future<Package?> package(String id) =>
      _getMaybe('$apiPath/packages/$id', Package.fromJson);

  @override
  Future<Package?> packageByName(String projectId, String name) async {
    final packages = await listPackages(projectId: projectId);
    for (final package in packages) {
      if (package.name == name) return package;
    }
    return null;
  }

  @override
  Future<Package> resolvePackage(String reference) async {
    final package = await _getMaybe(
      '$apiPath/packages/$reference',
      Package.fromJson,
    );
    if (package == null) throw PackageNotFoundException(reference);
    return package;
  }

  @override
  Future<List<Package>> listPackages({
    String? projectId,
    String? organizationId,
  }) => _getList(
    '$apiPath/packages',
    Package.fromJson,
    query: {'projectId': ?projectId, 'organizationId': ?organizationId},
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
    await _putJson('$apiPath/packages/$id', {
      'displayName': ?displayName,
      'description': ?description,
      'defaultChannel': ?defaultChannel?.name,
      'platforms': ?platforms,
      'metadata': ?metadata,
    }),
  );

  @override
  Future<void> deletePackage(String id, {bool force = false}) =>
      _delete('$apiPath/packages/$id', {'force': '$force'});

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
    await _postJson('$apiPath/packages/$packageReference/releases', {
      'version': version.toString(),
      'title': ?title,
      'notes': ?notes,
      'tag': ?tag,
      'draft': draft,
      'metadata': metadata,
    }),
  );

  @override
  Future<Release?> release(String id) =>
      _getMaybe('$apiPath/releases/$id', Release.fromJson);

  @override
  Future<Release?> releaseByVersion(String packageReference, Version version) =>
      _getMaybe(
        '$apiPath/packages/$packageReference/releases/$version',
        Release.fromJson,
      );

  @override
  Future<List<Release>> listReleases(
    String packageReference, {
    ReleaseQuery query = const ReleaseQuery(),
  }) => _getList(
    '$apiPath/packages/$packageReference/releases',
    Release.fromJson,
    query: query.toQueryParameters(),
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
    await _putJson('$apiPath/releases/$id', {
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
  Future<void> deleteRelease(String id) => _delete('$apiPath/releases/$id');

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
  }) => _getMaybe(
    '$apiPath/packages/$packageReference/releases/latest',
    Release.fromJson,
    query: {'channel': channel.name, 'exact': '$exact'},
  );

  @override
  Future<Release?> latestAny(String packageReference) => _getMaybe(
    '$apiPath/packages/$packageReference/releases/latest',
    Release.fromJson,
  );

  @override
  Future<Release> promoteRelease(
    String releaseId,
    ReleaseChannel channel, {
    String? notes,
  }) async => Release.fromJson(
    await _postJson('$apiPath/releases/$releaseId/promote', {
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
    final url = _url(
      '$apiPath/releases/$releaseId/assets',
      query: {
        'name': name,
        'sha256': ?expectedSha256,
        'platform': ?platform,
        'kind': ?kind,
      },
    );

    final request = http.StreamedRequest('POST', url)
      ..headers.addAll({...await _headers(), 'content-type': contentType});
    if (length != null) request.contentLength = length;

    // Not awaited: `send` is what drains the sink, so awaiting the pipe here
    // would deadlock waiting for a consumer that has not started.
    data.listen(
      request.sink.add,
      onError: request.sink.addError,
      onDone: request.sink.close,
      cancelOnError: true,
    );

    final streamed = await _sendRequest(request);
    final body = await streamed.stream.bytesToString();
    _throwForStatus(streamed.statusCode, body, url);
    return Asset.fromJson(_resultOf(body, url));
  }

  @override
  Future<Asset?> asset(String id) =>
      _getMaybe('$apiPath/assets/$id', Asset.fromJson);

  @override
  Future<Asset?> assetByName(String releaseId, String name) async {
    for (final asset in await listAssets(releaseId)) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  @override
  Future<List<Asset>> listAssets(String releaseId) =>
      _getList('$apiPath/releases/$releaseId/assets', Asset.fromJson);

  @override
  Future<void> deleteAsset(String id) => _delete('$apiPath/assets/$id');

  @override
  Future<AssetDownload> openAsset(String id, {ByteRange? range}) async {
    final asset = await this.asset(id);
    if (asset == null) throw AssetNotFoundException(id);

    final url = _url('$apiPath/assets/$id/download');
    final request = http.Request('GET', url)
      ..followRedirects = true
      ..headers.addAll(await _headers());
    if (range != null) request.headers['range'] = range.toHeaderValue();

    final response = await _sendRequest(request);
    if (response.statusCode != 200 && response.statusCode != 206) {
      final body = await response.stream.bytesToString();
      _throwForStatus(response.statusCode, body, url);
    }

    return AssetDownload(
      asset: asset,
      stream: response.stream,
      length: response.contentLength ?? asset.sizeBytes,
      range: response.statusCode == 206 ? range : null,
      providerId: response.headers['x-omnystore-provider'],
    );
  }

  /// Downloads the asset with [id] into memory and verifies its checksum.
  ///
  /// Convenience over [openAsset] for artifacts small enough to hold — a
  /// manifest, a signature, a patch. Verification is not optional: bytes that
  /// do not match the recorded digest raise [ChecksumMismatchException] rather
  /// than being returned for the caller to maybe check.
  ///
  /// For a large artifact on the VM, use `DownloadManager.downloadToFile`,
  /// which streams to disk and can resume.
  Future<Uint8List> downloadAsset(String id, {ByteRange? range}) async {
    final download = await openAsset(id, range: range);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in download.stream) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();

    // A ranged read covers part of the artifact, so the whole-object digest
    // cannot apply to it.
    if (range == null && download.asset.sha256.isNotEmpty) {
      Checksums.require(download.asset.sha256, Checksums.sha256Hex(bytes));
    }
    return bytes;
  }

  @override
  Future<DownloadTarget> downloadTarget(
    String id, {
    Duration expiresIn = const Duration(minutes: 15),
  }) async {
    // Ask the server for the redirect without following it, so the caller can
    // hand the URL to a browser or a download manager rather than fetching the
    // artifact through this client.
    final url = _url('$apiPath/assets/$id/download');
    final request = http.Request('GET', url)
      ..followRedirects = false
      ..headers.addAll(await _headers());

    final response = await _sendRequest(request);
    await response.stream.drain<void>();

    final location = response.headers['location'];
    if (response.statusCode == 302 && location != null) {
      return RedirectDownload(
        url: url.resolve(location),
        expiresAt: DateTime.now().toUtc().add(expiresIn),
        providerId: response.headers['x-omnystore-provider'] ?? 'server',
      );
    }
    if (response.statusCode == 404) throw AssetNotFoundException(id);
    return StreamedDownload(
      providerId: response.headers['x-omnystore-provider'] ?? 'server',
      reason: 'the server streams this asset rather than redirecting',
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
  }) async => throw const UnsupportedOperationException(
    'Downloads are recorded by the server as it serves them; a client cannot '
    'record one on its behalf.',
  );

  @override
  Future<List<DownloadRecord>> listDownloads(
    String packageReference, {
    int? limit,
    DateTime? from,
    DateTime? to,
  }) => _getList(
    '$apiPath/packages/$packageReference/downloads',
    DownloadRecord.fromJson,
    query: {
      'limit': ?limit?.toString(),
      'from': ?from?.toIso8601String(),
      'to': ?to?.toIso8601String(),
    },
  );

  @override
  Future<DownloadStats> downloadStats(
    String packageReference, {
    DateTime? from,
    DateTime? to,
  }) async {
    final url = _url(
      '$apiPath/packages/$packageReference/downloads/stats',
      query: {'from': ?from?.toIso8601String(), 'to': ?to?.toIso8601String()},
    );
    final response = await _send('GET', url);
    return DownloadStats.fromJson(_resultOf(response.body, url));
  }

  // ------------------------------------------------------------- updates ---

  @override
  Future<UpdateInfo> checkForUpdates({
    required String packageReference,
    required Version currentVersion,
    ReleaseChannel? channel,
    String? platform,
  }) async {
    final url = _url(
      '$apiPath/packages/$packageReference/updates',
      query: {
        'version': currentVersion.toString(),
        'channel': ?channel?.name,
        'platform': ?platform,
      },
    );
    final response = await _send('GET', url);
    return UpdateInfo.fromJson(_resultOf(response.body, url));
  }

  // ----------------------------------------------------------- providers ---

  @override
  Future<List<ProviderDescriptor>> listProviders({String? organization}) =>
      _getList(
        '$apiPath/providers',
        ProviderDescriptor.fromJson,
        query: {'organization': ?organization},
      );

  @override
  Future<void> close() async {
    await auth.close();
    if (_ownsClient) _http.close();
  }

  // ------------------------------------------------------------- plumbing --

  Uri _url(String path, {Map<String, String> query = const {}}) {
    final base = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(
      path: '$base$path',
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Future<Map<String, String>> _headers() async => {
    'accept': 'application/json',
    'user-agent': userAgent,
    ...await auth.headers(),
  };

  Future<T?> _getMaybe<T>(
    String path,
    T Function(Map<String, dynamic>) parse, {
    Map<String, String> query = const {},
  }) async {
    final url = _url(path, query: query);
    final response = await _send('GET', url, allowNotFound: true);
    if (response.statusCode == 404) return null;
    final result = _resultOrNull(response.body, url);
    return result == null ? null : parse(result);
  }

  Future<List<T>> _getList<T>(
    String path,
    T Function(Map<String, dynamic>) parse, {
    Map<String, String> query = const {},
  }) async {
    final url = _url(path, query: query);
    final response = await _send('GET', url);
    final decoded = Json.asObject(jsonDecode(response.body), 'response');
    return [
      for (final item in Json.asList(decoded['result'] ?? const [], 'result'))
        parse(Json.asObject(item, 'item')),
    ];
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final url = _url(path);
    final response = await _send('POST', url, body: body);
    return _resultOf(response.body, url);
  }

  Future<Map<String, dynamic>> _putJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final url = _url(path);
    final response = await _send('PUT', url, body: body);
    return _resultOf(response.body, url);
  }

  Future<void> _delete(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    await _send('DELETE', _url(path, query: query));
  }

  /// Sends a request, retrying once if the credentials could be refreshed.
  Future<http.Response> _send(
    String method,
    Uri url, {
    Map<String, dynamic>? body,
    bool allowNotFound = false,
  }) async {
    var response = await _sendOnce(method, url, body);
    if (response.statusCode == 401 && await auth.refresh()) {
      response = await _sendOnce(method, url, body);
    }
    if (allowNotFound && response.statusCode == 404) return response;
    _throwForStatus(response.statusCode, response.body, url);
    return response;
  }

  Future<http.Response> _sendOnce(
    String method,
    Uri url,
    Map<String, dynamic>? body,
  ) async {
    final request = http.Request(method, url)
      ..headers.addAll({
        ...await _headers(),
        if (body != null) 'content-type': 'application/json; charset=utf-8',
      });
    if (body != null) request.body = jsonEncode(body);

    final streamed = await _sendRequest(request);
    return http.Response.fromStream(streamed);
  }

  Future<http.StreamedResponse> _sendRequest(http.BaseRequest request) async {
    try {
      return await _http.send(request).timeout(timeout);
    } on http.ClientException catch (e) {
      throw ApiException(
        'Cannot reach ${request.url}: ${e.message}',
        url: request.url,
        code: ErrorCodes.apiError,
        statusCode: 503,
      );
    } on Object catch (e) {
      // Covers the TimeoutException from `.timeout` and any transport-specific
      // failure a custom http.Client raises.
      if (e is OmnyStoreException) rethrow;
      throw ApiException(
        'Request to ${request.url} failed: $e',
        url: request.url,
        code: ErrorCodes.apiError,
        statusCode: 503,
      );
    }
  }

  /// Turns a non-2xx response into the typed exception the server intended.
  static void _throwForStatus(int statusCode, String body, Uri url) {
    if (statusCode >= 200 && statusCode < 300) return;

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = (decoded['error'] as Map).cast<String, dynamic>();
        final details = error['details'];
        throw omnyStoreExceptionForCode(
          Json.optString(error, 'code') ?? ErrorCodes.apiError,
          Json.optString(error, 'message') ?? 'Request failed',
          statusCode: statusCode,
          url: url,
          details: details is Map
              ? details.map((k, v) => MapEntry('$k', v as Object?))
              : const {},
        );
      }
    } on FormatException {
      // Not a JSON error envelope — fall through to the generic failure below,
      // which keeps the raw body so the caller can see what a proxy or a load
      // balancer actually returned.
    }

    throw ApiException(
      'Request to $url failed with $statusCode',
      url: url,
      body: body.length > 500 ? '${body.substring(0, 500)}…' : body,
      statusCode: statusCode,
    );
  }

  static Map<String, dynamic> _resultOf(String body, Uri url) {
    final result = _resultOrNull(body, url);
    if (result == null) {
      throw ApiException('Server returned no result', url: url);
    }
    return result;
  }

  static Map<String, dynamic>? _resultOrNull(String body, Uri url) {
    if (body.trim().isEmpty) return null;
    final decoded = Json.asObject(jsonDecode(body), 'response');
    final result = decoded['result'];
    return result == null ? null : Json.asObject(result, 'result');
  }

  static Uri _normalizeBase(Object baseUrl) {
    final uri = baseUrl is Uri ? baseUrl : Uri.parse('$baseUrl');
    if (!uri.hasScheme) {
      throw ValidationException(
        "Base URL '$baseUrl' has no scheme; expected http:// or https://",
        field: 'baseUrl',
      );
    }
    // The `/api/v1` prefix is added per request, so a base URL that already
    // carries it would produce `/api/v1/api/v1/...`.
    var path = uri.path;
    if (path.endsWith('/api/$omnyStoreApiVersion')) {
      path = path.substring(
        0,
        path.length - '/api/$omnyStoreApiVersion'.length,
      );
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return uri.replace(path: path, query: null, fragment: null);
  }
}
