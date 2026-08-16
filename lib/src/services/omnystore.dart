import 'package:omnyhub/omnyhub.dart'
    show Clock, IdGenerator, Logger, NoopLogger, RandomIdGenerator, SystemClock;
import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../exceptions/omnystore_exception.dart';
import '../models/asset.dart';
import '../models/asset_location.dart';
import '../models/download_record.dart';
import '../models/organization.dart';
import '../models/package.dart';
import '../models/project.dart';
import '../models/provider_descriptor.dart';
import '../models/release.dart';
import '../models/update_info.dart';
import '../repositories/release_query.dart';
import '../repositories/repositories.dart';
import '../storage/object_storage.dart';
import '../updates/update_resolver.dart';
import '../utils/ids.dart';
import '../utils/names.dart';
import '../utils/version_codec.dart';
import 'asset_download.dart';
import 'omnystore_api.dart';

/// The registry, backed by local repositories and one object store.
///
/// This is the whole system in a single process: create organizations,
/// projects and packages, publish releases, attach artifacts, serve downloads
/// and answer update checks. Everything else in the package is a way to reach
/// an `OmnyStore` — the REST API server exposes one, a node *is* one, the hub
/// federates several, and the client SDK speaks to one across the network.
///
/// ```dart
/// final store = OmnyStore(
///   repositories: MemoryRepositories(),
///   storage: LocalObjectStorage('/var/lib/omnystore'),
/// );
///
/// final org = await store.createOrganization(name: 'acme');
/// final project = await store.createProject(
///   organizationId: org.id, name: 'agent',
/// );
/// final package = await store.createPackage(
///   projectId: project.id, name: 'omnyagent',
/// );
///
/// final release = await store.publishRelease(
///   packageReference: package.id,
///   version: Version.parse('1.0.0'),
/// );
/// await store.attachAsset(
///   releaseId: release.id,
///   name: 'omnyagent-linux-x64.tar.gz',
///   data: File('build/omnyagent-linux-x64.tar.gz').openRead(),
/// );
///
/// await store.latestRelease('omnyagent'); // => 1.0.0
/// ```
///
/// **No global state.** [clock], [idGenerator] and [logger] are injected, so
/// tests fix time, get deterministic ids, and assert on log output without a
/// singleton anywhere. Two `OmnyStore`s in one process share nothing.
///
/// **Business rules live here, not in the repositories.** Name validation,
/// referential integrity, release immutability and cascade rules are enforced
/// in this class, so they hold identically whether the backing store is
/// in-memory, SQL or a remote node.
class OmnyStore implements OmnyStoreApi {
  /// The metadata repositories.
  final StoreRepositories repositories;

  /// Where asset bytes live.
  final ObjectStorage storage;

  /// The time source. Injected so tests can fix `now`.
  final Clock clock;

  /// The identifier generator. Injected so tests get deterministic ids.
  ///
  /// When not supplied it is a [RandomIdGenerator] wrapped in a
  /// [ScopedIdGenerator] carrying [providerId], because ids have to be unique
  /// across a whole federation: a hub caches which provider owns which id and
  /// deduplicates aggregated listings by it, so two nodes minting the same id
  /// would route writes to the wrong machine. Injecting a generator opts out of
  /// that scoping — inject one that is unique per store.
  final IdGenerator idGenerator;

  /// Structured logging. Defaults to a no-op: embedding OmnyStore never writes
  /// to stdout unless the application asks for it.
  final Logger logger;

  /// This store's provider id, recorded on the placements it writes.
  final String providerId;

  /// The organizations this store serves, when it runs as a node. Empty with
  /// [servesAllOrganizations] means "everything local".
  final Set<String> organizations;

  /// Whether this store serves every organization — the single-server default.
  final bool servesAllOrganizations;

  /// Creates a store over [repositories] and [storage].
  OmnyStore({
    required this.repositories,
    required this.storage,
    this.clock = const SystemClock(),
    IdGenerator? idGenerator,
    this.logger = const NoopLogger(),
    String? providerId,
    Set<String> organizations = const {},
    this.servesAllOrganizations = true,
  }) : idGenerator =
           idGenerator ??
           ScopedIdGenerator(RandomIdGenerator(), providerId ?? 'local'),
       providerId = providerId ?? 'local',
       organizations = Set.unmodifiable(organizations);

  /// This store's own provider descriptor, as reported to a hub and by
  /// [listProviders].
  Future<ProviderDescriptor> describeProvider({
    ProviderKind kind = ProviderKind.hub,
    DataPlaneMode? dataPlane,
    String? baseUrl,
    Map<String, String> labels = const {},
    int priority = 0,
    int? capacityBytes,
  }) async => ProviderDescriptor(
    id: providerId,
    kind: kind,
    organizations: organizations,
    servesAll: servesAllOrganizations,
    dataPlane:
        dataPlane ??
        (storage.supportsPresignedUrls
            ? DataPlaneMode.presigned
            : baseUrl != null
            ? DataPlaneMode.direct
            : DataPlaneMode.relay),
    baseUrl: baseUrl,
    labels: labels,
    priority: priority,
    capacityBytes: capacityBytes,
    usedBytes: await storage.usedBytes(),
    status: ProviderStatus.online,
    lastSeenAt: clock.now(),
  );

  // ---------------------------------------------------------------- orgs ---

  @override
  Future<Organization> createOrganization({
    required String name,
    String? displayName,
    String? description,
    String? website,
    Map<String, String> metadata = const {},
  }) async {
    Names.require(name, 'organization name');
    if (await repositories.organizations.byName(name) != null) {
      throw ConflictException(
        "An organization named '$name' already exists",
        reference: name,
      );
    }
    final now = clock.now();
    final organization = Organization(
      id: idGenerator.next('org'),
      name: name,
      displayName: displayName,
      description: description,
      website: website,
      createdAt: now,
      updatedAt: now,
      metadata: metadata,
    );
    await repositories.organizations.save(organization);
    logger.info('Organization created', context: {'name': name});
    return organization;
  }

  @override
  Future<Organization?> organization(String id) =>
      repositories.organizations.byId(id);

  @override
  Future<Organization?> organizationByName(String name) =>
      repositories.organizations.byName(name);

  @override
  Future<List<Organization>> listOrganizations() =>
      repositories.organizations.list();

  @override
  Future<Organization> updateOrganization(
    String id, {
    String? displayName,
    String? description,
    String? website,
    Map<String, String>? metadata,
  }) async {
    final existing = await _requireOrganization(id);
    final updated = existing.copyWith(
      displayName: displayName,
      description: description,
      website: website,
      metadata: metadata,
      updatedAt: clock.now(),
    );
    await repositories.organizations.save(updated);
    return updated;
  }

  @override
  Future<void> deleteOrganization(String id, {bool force = false}) async {
    final existing = await _requireOrganization(id);
    final projects = await repositories.projects.listByOrganization(id);
    if (projects.isNotEmpty && !force) {
      throw ConflictException(
        "Organization '${existing.name}' still has ${projects.length} "
        'project(s); pass force to delete them too',
        reference: existing.name,
      );
    }
    for (final project in projects) {
      await deleteProject(project.id, force: true);
    }
    await repositories.organizations.delete(id);
    logger.info('Organization deleted', context: {'name': existing.name});
  }

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
  }) async {
    Names.require(name, 'project name');
    await _requireOrganization(organizationId);
    if (await repositories.projects.byName(organizationId, name) != null) {
      throw ConflictException(
        "A project named '$name' already exists in this organization",
        reference: name,
      );
    }
    final now = clock.now();
    final project = Project(
      id: idGenerator.next('proj'),
      organizationId: organizationId,
      name: name,
      displayName: displayName,
      description: description,
      repository: repository,
      website: website,
      createdAt: now,
      updatedAt: now,
      metadata: metadata,
    );
    await repositories.projects.save(project);
    logger.info('Project created', context: {'name': name});
    return project;
  }

  @override
  Future<Project?> project(String id) => repositories.projects.byId(id);

  @override
  Future<Project?> projectByName(String organizationId, String name) =>
      repositories.projects.byName(organizationId, name);

  @override
  Future<List<Project>> listProjects({String? organizationId}) =>
      organizationId == null
      ? repositories.projects.list()
      : repositories.projects.listByOrganization(organizationId);

  @override
  Future<Project> updateProject(
    String id, {
    String? displayName,
    String? description,
    String? repository,
    String? website,
    Map<String, String>? metadata,
  }) async {
    final existing = await _requireProject(id);
    final updated = existing.copyWith(
      displayName: displayName,
      description: description,
      repository: repository,
      website: website,
      metadata: metadata,
      updatedAt: clock.now(),
    );
    await repositories.projects.save(updated);
    return updated;
  }

  @override
  Future<void> deleteProject(String id, {bool force = false}) async {
    final existing = await _requireProject(id);
    final packages = await repositories.packages.listByProject(id);
    if (packages.isNotEmpty && !force) {
      throw ConflictException(
        "Project '${existing.name}' still has ${packages.length} package(s); "
        'pass force to delete them too',
        reference: existing.name,
      );
    }
    for (final package in packages) {
      await deletePackage(package.id, force: true);
    }
    await repositories.projects.delete(id);
    logger.info('Project deleted', context: {'name': existing.name});
  }

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
  }) async {
    Names.require(name, 'package name');
    final project = await _requireProject(projectId);
    if (await repositories.packages.byName(projectId, name) != null) {
      throw ConflictException(
        "A package named '$name' already exists in this project",
        reference: name,
      );
    }
    final now = clock.now();
    final package = Package(
      id: idGenerator.next('pkg'),
      projectId: projectId,
      organizationId: project.organizationId,
      name: name,
      displayName: displayName,
      description: description,
      defaultChannel: defaultChannel,
      platforms: platforms,
      createdAt: now,
      updatedAt: now,
      metadata: metadata,
    );
    await repositories.packages.save(package);
    logger.info('Package created', context: {'name': name});
    return package;
  }

  @override
  Future<Package?> package(String id) => repositories.packages.byId(id);

  @override
  Future<Package?> packageByName(String projectId, String name) =>
      repositories.packages.byName(projectId, name);

  @override
  Future<Package> resolvePackage(String reference) async {
    final byId = await repositories.packages.byId(reference);
    if (byId != null) return byId;

    final byName = await repositories.packages.findByName(reference);
    if (byName.isEmpty) throw PackageNotFoundException(reference);
    if (byName.length > 1) {
      throw ValidationException(
        "Package name '$reference' is ambiguous: it exists in "
        '${byName.length} projects (${byName.map((p) => p.projectId).join(', ')}). '
        'Use the package id instead.',
        field: 'package',
      );
    }
    return byName.first;
  }

  @override
  Future<List<Package>> listPackages({
    String? projectId,
    String? organizationId,
  }) async {
    if (projectId != null) {
      return repositories.packages.listByProject(projectId);
    }
    if (organizationId != null) {
      return repositories.packages.listByOrganization(organizationId);
    }
    return repositories.packages.list();
  }

  @override
  Future<Package> updatePackage(
    String id, {
    String? displayName,
    String? description,
    ReleaseChannel? defaultChannel,
    List<String>? platforms,
    Map<String, String>? metadata,
  }) async {
    final existing = await _requirePackage(id);
    final updated = existing.copyWith(
      displayName: displayName,
      description: description,
      defaultChannel: defaultChannel,
      platforms: platforms,
      metadata: metadata,
      updatedAt: clock.now(),
    );
    await repositories.packages.save(updated);
    return updated;
  }

  @override
  Future<void> deletePackage(String id, {bool force = false}) async {
    final existing = await _requirePackage(id);
    final releases = await repositories.releases.listByPackage(
      id,
      query: ReleaseQuery.all,
    );
    if (releases.isNotEmpty && !force) {
      throw ConflictException(
        "Package '${existing.name}' still has ${releases.length} release(s); "
        'pass force to delete them too',
        reference: existing.name,
      );
    }
    for (final release in releases) {
      await deleteRelease(release.id);
    }
    await repositories.packages.delete(id);
    logger.info('Package deleted', context: {'name': existing.name});
  }

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
  }) async {
    final package = await resolvePackage(packageReference);
    final existing = await repositories.releases.byVersion(package.id, version);
    if (existing != null) {
      throw ConflictException(
        'Release $version of ${package.name} already exists. Releases are '
        'immutable; publish a new version rather than replacing one clients '
        'may already have downloaded.',
        reference: '${package.name}@$version',
      );
    }

    final now = clock.now();
    final release = Release(
      id: idGenerator.next('rel'),
      packageId: package.id,
      organizationId: package.organizationId,
      version: version,
      title: title,
      notes: notes,
      tag: tag,
      draft: draft,
      createdAt: now,
      publishedAt: draft ? null : now,
      metadata: metadata,
    );
    await repositories.releases.save(release);
    logger.info(
      'Release published',
      context: {
        'package': package.name,
        'version': '$version',
        'channel': release.channel.name,
        'draft': draft,
      },
    );
    return release;
  }

  @override
  Future<Release?> release(String id) => repositories.releases.byId(id);

  @override
  Future<Release?> releaseByVersion(
    String packageReference,
    Version version,
  ) async {
    final package = await resolvePackage(packageReference);
    return repositories.releases.byVersion(package.id, version);
  }

  @override
  Future<List<Release>> listReleases(
    String packageReference, {
    ReleaseQuery query = const ReleaseQuery(),
  }) async {
    final package = await resolvePackage(packageReference);
    return repositories.releases.listByPackage(package.id, query: query);
  }

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
  }) async {
    final existing = await _requireRelease(id);
    // Publishing a draft stamps its publication time; that is the moment it
    // becomes offerable, and `latest*` orders on it.
    final publishedAt = existing.publishedAt == null && draft == false
        ? clock.now()
        : null;
    final updated = existing.copyWith(
      title: title,
      notes: notes,
      tag: tag,
      draft: draft,
      yanked: yanked,
      yankedReason: yankedReason,
      publishedAt: publishedAt,
      metadata: metadata,
    );
    await repositories.releases.save(updated);
    if (yanked == true) {
      logger.warn(
        'Release yanked',
        context: {'version': '${existing.version}', 'reason': yankedReason},
      );
    }
    return updated;
  }

  @override
  Future<void> deleteRelease(String id) async {
    final existing = await _requireRelease(id);
    for (final asset in await repositories.assets.listByRelease(id)) {
      await deleteAsset(asset.id);
    }
    await repositories.releases.delete(id);
    logger.info('Release deleted', context: {'version': '${existing.version}'});
  }

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
  }) async {
    final package = await resolvePackage(packageReference);
    return repositories.releases.latest(
      package.id,
      query: exact
          ? ReleaseQuery(channel: channel)
          : ReleaseQuery(acceptedBy: channel),
    );
  }

  @override
  Future<Release?> latestAny(String packageReference) async {
    final package = await resolvePackage(packageReference);
    return repositories.releases.latest(package.id);
  }

  @override
  Future<Release> promoteRelease(
    String releaseId,
    ReleaseChannel channel, {
    String? notes,
  }) async {
    final source = await _requireRelease(releaseId);
    if (source.channel == channel) {
      throw ValidationException(
        'Release ${source.version} is already on the ${channel.name} channel',
        field: 'channel',
      );
    }
    if (channel.stability < source.channel.stability) {
      throw ValidationException(
        'Cannot promote ${source.version} from ${source.channel.name} down to '
        '${channel.name}; promotion only moves towards stability',
        field: 'channel',
      );
    }

    final package = await _requirePackage(source.packageId);
    final target = Versions.stamp(Versions.baseOf(source.version), channel);
    if (await repositories.releases.byVersion(package.id, target) != null) {
      throw ConflictException(
        'Release $target of ${package.name} already exists, so '
        '${source.version} cannot be promoted onto it',
        reference: '${package.name}@$target',
      );
    }

    final promoted = await publishRelease(
      packageReference: package.id,
      version: target,
      title: source.title == source.version.toString() ? null : source.title,
      notes: notes ?? source.notes,
      tag: source.tag,
      metadata: {
        ...source.metadata,
        'promotedFrom': source.version.toString(),
        'promotedFromReleaseId': source.id,
      },
    );

    // Copy the artifacts across. The storage key embeds the version, so the
    // bytes are genuinely duplicated rather than aliased — which is what makes
    // deleting the pre-release later safe.
    for (final asset in await repositories.assets.listByRelease(source.id)) {
      final read = await openAsset(asset.id);
      await attachAsset(
        releaseId: promoted.id,
        name: asset.name,
        data: read.stream,
        length: asset.sizeBytes,
        contentType: asset.contentType,
        expectedSha256: asset.sha256,
        platform: asset.platform,
        kind: asset.kind,
        metadata: asset.metadata,
      );
    }

    logger.info(
      'Release promoted',
      context: {
        'package': package.name,
        'from': '${source.version}',
        'to': '$target',
      },
    );
    return promoted;
  }

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
    Names.requireFilename(name);
    final release = await _requireRelease(releaseId);
    if (await repositories.assets.byName(releaseId, name) != null) {
      throw ConflictException(
        "An asset named '$name' is already attached to ${release.version}",
        reference: name,
      );
    }

    final package = await _requirePackage(release.packageId);
    final organization = await _requireOrganization(release.organizationId);
    final key = StorageKeys.forAsset(
      organization: organization.name,
      package: package.name,
      version: release.version.toString(),
      filename: name,
    );

    // Storage computes and verifies the digest as the bytes stream past; on
    // mismatch it removes the object and throws, so a corrupt upload never
    // becomes a downloadable artifact and never gets an asset record.
    final stored = await storage.put(
      key,
      data,
      length: length,
      contentType: contentType,
      expectedSha256: expectedSha256,
      metadata: {'assetName': name, 'releaseId': releaseId},
    );

    final now = clock.now();
    final asset = Asset(
      id: idGenerator.next('asset'),
      releaseId: releaseId,
      packageId: release.packageId,
      organizationId: release.organizationId,
      name: name,
      storageKey: key,
      contentType: contentType,
      sizeBytes: stored.sizeBytes,
      sha256: stored.sha256 ?? '',
      platform: platform,
      kind: kind,
      createdAt: now,
      metadata: metadata,
    );
    await repositories.assets.save(asset);

    await repositories.locations.save(
      AssetLocation(
        id: idGenerator.next('loc'),
        assetId: asset.id,
        providerId: providerId,
        organizationId: asset.organizationId,
        storageKey: key,
        state: ReplicaState.available,
        sizeBytes: stored.sizeBytes,
        createdAt: now,
        verifiedAt: now,
      ),
    );

    logger.info(
      'Asset attached',
      context: {
        'name': name,
        'version': '${release.version}',
        'bytes': stored.sizeBytes,
      },
    );
    return asset;
  }

  @override
  Future<Asset?> asset(String id) => repositories.assets.byId(id);

  @override
  Future<Asset?> assetByName(String releaseId, String name) =>
      repositories.assets.byName(releaseId, name);

  @override
  Future<List<Asset>> listAssets(String releaseId) =>
      repositories.assets.listByRelease(releaseId);

  @override
  Future<void> deleteAsset(String id) async {
    final existing = await _requireAsset(id);
    // Bytes first: a metadata record with no bytes behind it produces a
    // confusing 404 on download, while orphaned bytes with no record are
    // invisible and reclaimable by a sweep.
    await storage.delete(existing.storageKey);
    await repositories.locations.deleteByAsset(id);
    await repositories.assets.delete(id);
    logger.info('Asset deleted', context: {'name': existing.name});
  }

  @override
  Future<AssetDownload> openAsset(String id, {ByteRange? range}) async {
    final asset = await _requireAsset(id);
    final reader = await storage.get(asset.storageKey, range: range);
    return AssetDownload(
      asset: asset,
      stream: reader.stream,
      length: reader.length,
      range: reader.range,
      providerId: providerId,
    );
  }

  @override
  Future<DownloadTarget> downloadTarget(
    String id, {
    Duration expiresIn = const Duration(minutes: 15),
  }) async {
    final asset = await _requireAsset(id);
    final url = await storage.presignedUrl(
      asset.storageKey,
      expiresIn: expiresIn,
      filename: asset.name,
      contentType: asset.contentType,
    );
    if (url == null) {
      return StreamedDownload(
        providerId: providerId,
        reason: '${storage.id} cannot issue presigned URLs',
      );
    }
    return RedirectDownload(
      url: url,
      expiresAt: clock.now().add(expiresIn),
      providerId: providerId,
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
  }) async {
    final asset = await _requireAsset(assetId);
    final release = await repositories.releases.byId(asset.releaseId);

    final record = DownloadRecord(
      id: idGenerator.next('dl'),
      assetId: assetId,
      releaseId: asset.releaseId,
      packageId: asset.packageId,
      organizationId: asset.organizationId,
      // Denormalised so per-version counts survive the release being deleted.
      version: release?.version.toString() ?? 'unknown',
      downloadedAt: clock.now(),
      providerId: providerId ?? this.providerId,
      clientAddress: clientAddress,
      userAgent: userAgent,
      principalId: principalId,
      bytesServed: bytesServed,
    );
    await repositories.downloads.save(record);
    await repositories.assets.incrementDownloadCount(assetId);
    return record;
  }

  @override
  Future<List<DownloadRecord>> listDownloads(
    String packageReference, {
    int? limit,
    DateTime? from,
    DateTime? to,
  }) async {
    final package = await resolvePackage(packageReference);
    return repositories.downloads.listByPackage(
      package.id,
      limit: limit,
      from: from,
      to: to,
    );
  }

  @override
  Future<DownloadStats> downloadStats(
    String packageReference, {
    DateTime? from,
    DateTime? to,
  }) async {
    final package = await resolvePackage(packageReference);
    return repositories.downloads.statsByPackage(
      package.id,
      from: from,
      to: to,
    );
  }

  // ------------------------------------------------------------- updates ---

  @override
  Future<UpdateInfo> checkForUpdates({
    required String packageReference,
    required Version currentVersion,
    ReleaseChannel? channel,
    String? platform,
  }) async {
    final package = await resolvePackage(packageReference);
    final effectiveChannel = channel ?? package.defaultChannel;
    final latest = await repositories.releases.latest(
      package.id,
      query: ReleaseQuery(acceptedBy: effectiveChannel),
    );
    return UpdateResolver.resolve(
      packageName: package.name,
      currentVersion: currentVersion,
      channel: effectiveChannel,
      latest: latest,
      assets: latest == null
          ? const []
          : await repositories.assets.listByRelease(latest.id),
      platform: platform,
    );
  }

  // ----------------------------------------------------------- providers ---

  @override
  Future<List<ProviderDescriptor>> listProviders({String? organization}) async {
    final descriptor = await describeProvider();
    if (organization != null && !descriptor.serves(organization)) {
      return const [];
    }
    return [descriptor];
  }

  @override
  Future<void> close() => storage.close();

  // ------------------------------------------------------------- lookups ---

  Future<Organization> _requireOrganization(String id) async {
    final found = await repositories.organizations.byId(id);
    if (found != null) return found;
    // Accept a name as well as an id: everything user-facing does, and failing
    // here with "not found" for a name that plainly exists is a bad experience.
    final byName = await repositories.organizations.byName(id);
    if (byName != null) return byName;
    throw OrganizationNotFoundException(id);
  }

  Future<Project> _requireProject(String id) async {
    final found = await repositories.projects.byId(id);
    if (found == null) throw ProjectNotFoundException(id);
    return found;
  }

  Future<Package> _requirePackage(String id) async {
    final found = await repositories.packages.byId(id);
    if (found == null) throw PackageNotFoundException(id);
    return found;
  }

  Future<Release> _requireRelease(String id) async {
    final found = await repositories.releases.byId(id);
    if (found == null) throw ReleaseNotFoundException(id);
    return found;
  }

  Future<Asset> _requireAsset(String id) async {
    final found = await repositories.assets.byId(id);
    if (found == null) throw AssetNotFoundException(id);
    return found;
  }
}
