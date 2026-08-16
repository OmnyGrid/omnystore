import 'package:omnyhub/omnyhub.dart'
    show Clock, Logger, NoopLogger, SystemClock;
import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../exceptions/omnystore_exception.dart';
import '../models/asset.dart';
import '../models/download_record.dart';
import '../models/organization.dart';
import '../models/package.dart';
import '../models/project.dart';
import '../models/provider_descriptor.dart';
import '../models/release.dart';
import '../models/update_info.dart';
import '../nodes/provider_registry.dart';
import '../nodes/store_provider.dart';
import '../repositories/release_query.dart';
import '../services/asset_download.dart';
import '../services/omnystore_api.dart';
import '../storage/object_storage.dart';
import '../updates/update_resolver.dart';

/// The discovery point: one [OmnyStoreApi] federated across many providers.
///
/// A hub owns no artifacts of its own unless you give it a local provider. What
/// it owns is the **routing table** — which nodes serve which organizations —
/// and the aggregation logic that makes a fleet of independent stores look like
/// one registry to every client.
///
/// ```text
///                        ┌──────────── OmnyStoreHub ────────────┐
///   client ──REST──►     │  ProviderRegistry: org → providers   │
///                        │                                      │
///                        │   acme     ─► node-eu, node-us       │
///                        │   globex   ─► node-eu                │
///                        │   *        ─► hub-local (catch-all)  │
///                        └──────────┬───────────────────────────┘
///                                   │ node control channel (OmnyHub)
///                        ┌──────────┴─────────┬──────────────────┐
///                     node-eu              node-us            hub-local
///                  (S3, eu-west-1)     (local directory)      (in-process)
/// ```
///
/// **Routing rules**, in one place because getting them consistent is the whole
/// job:
///
/// * **Writes follow ownership.** Creating a project goes to whichever provider
///   holds its organization; publishing a release goes to whichever holds its
///   package. Only `createOrganization` has no parent to follow, and it goes to
///   [ProviderRegistry.primaryFor]. A write never fans out, so ids stay unique.
/// * **Reads by id fan out**, first hit wins, and the answer is cached so the
///   next lookup of that id goes straight to its owner.
/// * **Listings aggregate** across every provider serving the organization,
///   deduplicated by id — which is what makes sharding (different packages on
///   different nodes) and replication (the same package on several) both work
///   without the client knowing which it is looking at.
/// * **Downloads prefer a redirect.** If the holding provider can issue a URL,
///   the client is sent straight there and no artifact bytes cross the hub.
///
/// The hub is itself an [OmnyStoreApi], so the REST server, the CLI and the
/// client SDK mount over a hub and a single embedded store identically.
class OmnyStoreHub implements OmnyStoreApi {
  /// The providers this hub federates, and the organization routing table.
  final ProviderRegistry providers;

  /// The time source, used for redirect expiry.
  final Clock clock;

  /// Structured logging.
  final Logger logger;

  /// A cache of which provider owns which entity id.
  ///
  /// Purely an optimisation over the fan-out: a miss costs one extra round of
  /// lookups, and a stale entry is corrected the moment its provider answers
  /// `null`. It is bounded so a long-running hub serving millions of ids does
  /// not grow without limit.
  final Map<String, String> _owners = {};

  /// How many id→provider mappings to remember.
  final int ownerCacheSize;

  /// Creates a hub over [providers].
  OmnyStoreHub({
    ProviderRegistry? providers,
    this.clock = const SystemClock(),
    this.logger = const NoopLogger(),
    this.ownerCacheSize = 10000,
  }) : providers = providers ?? ProviderRegistry();

  /// Registers [provider] and returns it, for chaining at construction.
  StoreProvider addProvider(StoreProvider provider) {
    providers.register(provider);
    logger.info(
      'Storage provider registered',
      context: {
        'provider': provider.id,
        'kind': provider.descriptor.kind.name,
        'organizations': provider.descriptor.servesAll
            ? '*'
            : provider.descriptor.organizations.join(','),
      },
    );
    return provider;
  }

  /// Removes the provider with [id] and forgets everything it owned.
  bool removeProvider(String id) {
    _owners.removeWhere((_, owner) => owner == id);
    final removed = providers.remove(id);
    if (removed) {
      logger.info('Storage provider removed', context: {'provider': id});
    }
    return removed;
  }

  // ---------------------------------------------------------------- orgs ---

  @override
  Future<Organization> createOrganization({
    required String name,
    String? displayName,
    String? description,
    String? website,
    Map<String, String> metadata = const {},
  }) async {
    // An organization that already exists anywhere in the federation is a
    // conflict, even though the hub itself stores nothing: two nodes both
    // holding `acme` would make every subsequent lookup ambiguous.
    if (await organizationByName(name) != null) {
      throw ConflictException(
        "An organization named '$name' already exists in this federation",
        reference: name,
      );
    }
    final provider = providers.primaryFor(name);
    final organization = await provider.store.createOrganization(
      name: name,
      displayName: displayName,
      description: description,
      website: website,
      metadata: metadata,
    );
    _remember(organization.id, provider.id);
    return organization;
  }

  @override
  Future<Organization?> organization(String id) async =>
      (await _locate<Organization>(id, (store) => store.organization(id)))?.$2;

  @override
  Future<Organization?> organizationByName(String name) async {
    for (final provider in providers.providersFor(name)) {
      final found = await _guard(() => provider.store.organizationByName(name));
      if (found != null) {
        _remember(found.id, provider.id);
        return found;
      }
    }
    // Fall back to a full scan: a provider may hold an organization it never
    // declared, which is exactly the state right after `createOrganization` on
    // a catch-all provider.
    for (final provider in providers.readable) {
      final found = await _guard(() => provider.store.organizationByName(name));
      if (found != null) {
        _remember(found.id, provider.id);
        return found;
      }
    }
    return null;
  }

  @override
  Future<List<Organization>> listOrganizations() => _aggregate(
    (store) => store.listOrganizations(),
    // Deduplicated by *name*, the organization's real uniqueness constraint,
    // not by id. Two providers holding the same organization are replicas and
    // must collapse to one row; two distinct organizations must never collapse
    // because their ids happened to coincide.
    (o) => o.name,
    (o) => o.id,
    (a, b) => a.name.compareTo(b.name),
  );

  @override
  Future<Organization> updateOrganization(
    String id, {
    String? displayName,
    String? description,
    String? website,
    Map<String, String>? metadata,
  }) async {
    final owner = await _requireOwnerOf<Organization>(
      id,
      (store) => store.organization(id),
      () => OrganizationNotFoundException(id),
    );
    return owner.$1.store.updateOrganization(
      id,
      displayName: displayName,
      description: description,
      website: website,
      metadata: metadata,
    );
  }

  @override
  Future<void> deleteOrganization(String id, {bool force = false}) async {
    final owner = await _requireOwnerOf<Organization>(
      id,
      (store) => store.organization(id),
      () => OrganizationNotFoundException(id),
    );
    await owner.$1.store.deleteOrganization(id, force: force);
    _owners.remove(id);
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
    final owner = await _requireOwnerOf<Organization>(
      organizationId,
      (store) => store.organization(organizationId),
      () => OrganizationNotFoundException(organizationId),
    );
    final project = await owner.$1.store.createProject(
      organizationId: organizationId,
      name: name,
      displayName: displayName,
      description: description,
      repository: repository,
      website: website,
      metadata: metadata,
    );
    _remember(project.id, owner.$1.id);
    return project;
  }

  @override
  Future<Project?> project(String id) async =>
      (await _locate<Project>(id, (store) => store.project(id)))?.$2;

  @override
  Future<Project?> projectByName(String organizationId, String name) async {
    for (final provider in providers.readable) {
      final found = await _guard(
        () => provider.store.projectByName(organizationId, name),
      );
      if (found != null) {
        _remember(found.id, provider.id);
        return found;
      }
    }
    return null;
  }

  @override
  Future<List<Project>> listProjects({String? organizationId}) async {
    // The caller's [organizationId] belongs to whichever provider owns that
    // organization; a provider holding a *replica* of it minted a different
    // id. Filtering is therefore done by name, resolved once here and matched
    // locally on each provider.
    final organizationName = organizationId == null
        ? null
        : (await organization(organizationId))?.name;
    if (organizationId != null && organizationName == null) return const [];

    final byKey = <String, Project>{};
    for (final provider in providers.readable) {
      final index = await _indexOf(provider);
      final localOrganizationId = organizationName == null
          ? null
          : index.organizationIdOf(organizationName);
      if (organizationName != null && localOrganizationId == null) continue;

      final projects =
          await _guard(
            () => provider.store.listProjects(
              organizationId: localOrganizationId,
            ),
          ) ??
          const [];
      for (final project in projects) {
        final key =
            '${index.organizationName(project.organizationId)}/${project.name}';
        if (byKey.putIfAbsent(key, () => project) == project) {
          _remember(project.id, provider.id);
        }
      }
    }
    return byKey.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<Project> updateProject(
    String id, {
    String? displayName,
    String? description,
    String? repository,
    String? website,
    Map<String, String>? metadata,
  }) async {
    final owner = await _requireOwnerOf<Project>(
      id,
      (store) => store.project(id),
      () => ProjectNotFoundException(id),
    );
    return owner.$1.store.updateProject(
      id,
      displayName: displayName,
      description: description,
      repository: repository,
      website: website,
      metadata: metadata,
    );
  }

  @override
  Future<void> deleteProject(String id, {bool force = false}) async {
    final owner = await _requireOwnerOf<Project>(
      id,
      (store) => store.project(id),
      () => ProjectNotFoundException(id),
    );
    await owner.$1.store.deleteProject(id, force: force);
    _owners.remove(id);
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
    final owner = await _requireOwnerOf<Project>(
      projectId,
      (store) => store.project(projectId),
      () => ProjectNotFoundException(projectId),
    );
    final package = await owner.$1.store.createPackage(
      projectId: projectId,
      name: name,
      displayName: displayName,
      description: description,
      defaultChannel: defaultChannel,
      platforms: platforms,
      metadata: metadata,
    );
    _remember(package.id, owner.$1.id);
    return package;
  }

  @override
  Future<Package?> package(String id) async =>
      (await _locate<Package>(id, (store) => store.package(id)))?.$2;

  @override
  Future<Package?> packageByName(String projectId, String name) async {
    for (final provider in providers.readable) {
      final found = await _guard(
        () => provider.store.packageByName(projectId, name),
      );
      if (found != null) {
        _remember(found.id, provider.id);
        return found;
      }
    }
    return null;
  }

  @override
  Future<Package> resolvePackage(String reference) async =>
      (await _resolvePackageOwner(reference)).$2;

  @override
  Future<List<Package>> listPackages({
    String? projectId,
    String? organizationId,
  }) async {
    // As in [listProjects], filters are translated to names so they match on a
    // provider holding a replica under different ids.
    final organizationName = organizationId == null
        ? null
        : (await organization(organizationId))?.name;
    if (organizationId != null && organizationName == null) return const [];

    final projectName = projectId == null
        ? null
        : (await project(projectId))?.name;
    if (projectId != null && projectName == null) return const [];

    final byKey = <String, Package>{};
    for (final provider in providers.readable) {
      final index = await _indexOf(provider);

      final localOrganizationId = organizationName == null
          ? null
          : index.organizationIdOf(organizationName);
      if (organizationName != null && localOrganizationId == null) continue;

      final localProjectId = projectName == null
          ? null
          : index.projectIdOf(projectName, organization: localOrganizationId);
      if (projectName != null && localProjectId == null) continue;

      final packages =
          await _guard(
            () => provider.store.listPackages(
              projectId: localProjectId,
              organizationId: localProjectId == null
                  ? localOrganizationId
                  : null,
            ),
          ) ??
          const [];
      for (final package in packages) {
        final key =
            '${index.organizationName(package.organizationId)}/'
            '${index.projectName(package.projectId)}/${package.name}';
        if (byKey.putIfAbsent(key, () => package) == package) {
          _remember(package.id, provider.id);
        }
      }
    }
    return byKey.values.toList()..sort((a, b) => a.name.compareTo(b.name));
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
    final owner = await _requireOwnerOf<Package>(
      id,
      (store) => store.package(id),
      () => PackageNotFoundException(id),
    );
    return owner.$1.store.updatePackage(
      id,
      displayName: displayName,
      description: description,
      defaultChannel: defaultChannel,
      platforms: platforms,
      metadata: metadata,
    );
  }

  @override
  Future<void> deletePackage(String id, {bool force = false}) async {
    final owner = await _requireOwnerOf<Package>(
      id,
      (store) => store.package(id),
      () => PackageNotFoundException(id),
    );
    await owner.$1.store.deletePackage(id, force: force);
    _owners.remove(id);
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
    final (provider, package) = await _resolvePackageOwner(packageReference);
    final release = await provider.store.publishRelease(
      // Always pass the id downstream: the bare name the caller used may be
      // ambiguous *within* the provider even though it was unique across the
      // federation.
      packageReference: package.id,
      version: version,
      title: title,
      notes: notes,
      tag: tag,
      draft: draft,
      metadata: metadata,
    );
    _remember(release.id, provider.id);
    return release;
  }

  @override
  Future<Release?> release(String id) async =>
      (await _locate<Release>(id, (store) => store.release(id)))?.$2;

  @override
  Future<Release?> releaseByVersion(
    String packageReference,
    Version version,
  ) async {
    final (provider, package) = await _resolvePackageOwner(packageReference);
    final found = await provider.store.releaseByVersion(package.id, version);
    if (found != null) _remember(found.id, provider.id);
    return found;
  }

  @override
  Future<List<Release>> listReleases(
    String packageReference, {
    ReleaseQuery query = const ReleaseQuery(),
  }) async {
    final (provider, package) = await _resolvePackageOwner(packageReference);
    return provider.store.listReleases(package.id, query: query);
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
    final owner = await _requireOwnerOf<Release>(
      id,
      (store) => store.release(id),
      () => ReleaseNotFoundException(id),
    );
    return owner.$1.store.updateRelease(
      id,
      title: title,
      notes: notes,
      tag: tag,
      draft: draft,
      yanked: yanked,
      yankedReason: yankedReason,
      metadata: metadata,
    );
  }

  @override
  Future<void> deleteRelease(String id) async {
    final owner = await _requireOwnerOf<Release>(
      id,
      (store) => store.release(id),
      () => ReleaseNotFoundException(id),
    );
    await owner.$1.store.deleteRelease(id);
    _owners.remove(id);
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
    final (provider, package) = await _resolvePackageOwner(packageReference);
    return provider.store.latestChannel(package.id, channel, exact: exact);
  }

  @override
  Future<Release?> latestAny(String packageReference) async {
    final (provider, package) = await _resolvePackageOwner(packageReference);
    return provider.store.latestAny(package.id);
  }

  @override
  Future<Release> promoteRelease(
    String releaseId,
    ReleaseChannel channel, {
    String? notes,
  }) async {
    final owner = await _requireOwnerOf<Release>(
      releaseId,
      (store) => store.release(releaseId),
      () => ReleaseNotFoundException(releaseId),
    );
    final promoted = await owner.$1.store.promoteRelease(
      releaseId,
      channel,
      notes: notes,
    );
    _remember(promoted.id, owner.$1.id);
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
    final owner = await _requireOwnerOf<Release>(
      releaseId,
      (store) => store.release(releaseId),
      () => ReleaseNotFoundException(releaseId),
    );
    final asset = await owner.$1.store.attachAsset(
      releaseId: releaseId,
      name: name,
      data: data,
      length: length,
      contentType: contentType,
      expectedSha256: expectedSha256,
      platform: platform,
      kind: kind,
      metadata: metadata,
    );
    _remember(asset.id, owner.$1.id);
    return asset;
  }

  @override
  Future<Asset?> asset(String id) async =>
      (await _locate<Asset>(id, (store) => store.asset(id)))?.$2;

  @override
  Future<Asset?> assetByName(String releaseId, String name) async {
    final owner = await _locate<Release>(
      releaseId,
      (store) => store.release(releaseId),
    );
    if (owner == null) return null;
    final found = await owner.$1.store.assetByName(releaseId, name);
    if (found != null) _remember(found.id, owner.$1.id);
    return found;
  }

  @override
  Future<List<Asset>> listAssets(String releaseId) async {
    final owner = await _locate<Release>(
      releaseId,
      (store) => store.release(releaseId),
    );
    if (owner == null) throw ReleaseNotFoundException(releaseId);
    return owner.$1.store.listAssets(releaseId);
  }

  @override
  Future<void> deleteAsset(String id) async {
    final owner = await _requireOwnerOf<Asset>(
      id,
      (store) => store.asset(id),
      () => AssetNotFoundException(id),
    );
    await owner.$1.store.deleteAsset(id);
    _owners.remove(id);
  }

  @override
  Future<AssetDownload> openAsset(String id, {ByteRange? range}) async {
    final owner = await _requireOwnerOf<Asset>(
      id,
      (store) => store.asset(id),
      () => AssetNotFoundException(id),
    );
    return owner.$1.store.openAsset(id, range: range);
  }

  @override
  Future<DownloadTarget> downloadTarget(
    String id, {
    Duration expiresIn = const Duration(minutes: 15),
  }) async {
    final owner = await _requireOwnerOf<Asset>(
      id,
      (store) => store.asset(id),
      () => AssetNotFoundException(id),
    );
    return owner.$1.store.downloadTarget(id, expiresIn: expiresIn);
  }

  /// Copies the bytes of the asset with [assetId] onto the provider
  /// [toProviderId], so it can serve that artifact too.
  ///
  /// The explicit half of replication. Metadata writes go to exactly one
  /// provider — the owner — because ids must stay unique; *bytes* have no such
  /// constraint, so an organization spread over several nodes replicates its
  /// artifacts by calling this for each additional holder.
  ///
  /// **Ids do not travel.** Each provider mints its own, so the target's copy
  /// of the organization, project, package and release is located by *natural*
  /// key — name, and version — and created if it is not there yet. That is the
  /// same uniqueness constraint aggregated listings deduplicate on, so the two
  /// copies collapse into one row rather than appearing twice.
  ///
  /// The content is verified against the source's digest on arrival: a replica
  /// that silently differs is worse than no replica, because clients would get
  /// different bytes depending on which node answered.
  ///
  /// Returns the asset record on the target provider.
  Future<Asset> replicateAsset(String assetId, String toProviderId) async {
    final source = await _requireOwnerOf<Asset>(
      assetId,
      (store) => store.asset(assetId),
      () => AssetNotFoundException(assetId),
    );
    final target = providers.requireById(toProviderId);
    if (target.id == source.$1.id) {
      throw ValidationException(
        'Asset $assetId is already held by provider $toProviderId',
        field: 'providerId',
      );
    }
    if (!target.isWritable) {
      throw StorageException(
        'Provider $toProviderId is not accepting writes',
        key: assetId,
      );
    }

    final asset = source.$2;
    final targetReleaseId = await _mirrorReleaseOn(
      target,
      source: source.$1,
      asset: asset,
    );

    // An asset already replicated here is not an error: replication is a
    // reconciliation pass, and re-running it must converge rather than fail.
    final existing = await target.store.assetByName(
      targetReleaseId,
      asset.name,
    );
    if (existing != null && existing.sha256 == asset.sha256) {
      return existing;
    }

    final read = await source.$1.store.openAsset(assetId);
    final replica = await target.store.attachAsset(
      releaseId: targetReleaseId,
      name: asset.name,
      data: read.stream,
      length: asset.sizeBytes,
      contentType: asset.contentType,
      expectedSha256: asset.sha256,
      platform: asset.platform,
      kind: asset.kind,
      metadata: asset.metadata,
    );
    logger.info(
      'Asset replicated',
      context: {'asset': assetId, 'from': source.$1.id, 'to': target.id},
    );
    return replica;
  }

  /// Finds — or creates — the release on [target] corresponding to [asset]'s
  /// release on [source], and returns its id on the target.
  ///
  /// Walks the ownership chain by name so the two providers' independently
  /// minted ids never have to agree.
  Future<String> _mirrorReleaseOn(
    StoreProvider target, {
    required StoreProvider source,
    required Asset asset,
  }) async {
    final release = await source.store.release(asset.releaseId);
    final package = await source.store.package(asset.packageId);
    final organization = await source.store.organization(asset.organizationId);
    if (release == null || package == null || organization == null) {
      throw AssetNotFoundException(
        '${asset.id} (its release, package or organization is missing on '
        '${source.id})',
      );
    }
    final project = await source.store.project(package.projectId);
    if (project == null) throw ProjectNotFoundException(package.projectId);

    final targetOrganization =
        await target.store.organizationByName(organization.name) ??
        await target.store.createOrganization(
          name: organization.name,
          displayName: organization.displayName,
          description: organization.description,
          website: organization.website,
          metadata: organization.metadata,
        );

    final targetProject =
        await target.store.projectByName(targetOrganization.id, project.name) ??
        await target.store.createProject(
          organizationId: targetOrganization.id,
          name: project.name,
          displayName: project.displayName,
          description: project.description,
          repository: project.repository,
          website: project.website,
          metadata: project.metadata,
        );

    final targetPackage =
        await target.store.packageByName(targetProject.id, package.name) ??
        await target.store.createPackage(
          projectId: targetProject.id,
          name: package.name,
          displayName: package.displayName,
          description: package.description,
          defaultChannel: package.defaultChannel,
          platforms: package.platforms,
          metadata: package.metadata,
        );

    final targetRelease =
        await target.store.releaseByVersion(
          targetPackage.id,
          release.version,
        ) ??
        await target.store.publishRelease(
          packageReference: targetPackage.id,
          version: release.version,
          title: release.title,
          notes: release.notes,
          tag: release.tag,
          metadata: release.metadata,
        );

    return targetRelease.id;
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
    final owner = await _requireOwnerOf<Asset>(
      assetId,
      (store) => store.asset(assetId),
      () => AssetNotFoundException(assetId),
    );
    return owner.$1.store.recordDownload(
      assetId: assetId,
      clientAddress: clientAddress,
      userAgent: userAgent,
      principalId: principalId,
      providerId: providerId ?? owner.$1.id,
      bytesServed: bytesServed,
    );
  }

  @override
  Future<List<DownloadRecord>> listDownloads(
    String packageReference, {
    int? limit,
    DateTime? from,
    DateTime? to,
  }) async {
    final (provider, package) = await _resolvePackageOwner(packageReference);
    return provider.store.listDownloads(
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
    final (provider, package) = await _resolvePackageOwner(packageReference);
    return provider.store.downloadStats(package.id, from: from, to: to);
  }

  // ------------------------------------------------------------- updates ---

  @override
  Future<UpdateInfo> checkForUpdates({
    required String packageReference,
    required Version currentVersion,
    ReleaseChannel? channel,
    String? platform,
  }) async {
    final (provider, package) = await _resolvePackageOwner(packageReference);
    final effectiveChannel = channel ?? package.defaultChannel;
    final latest = await provider.store.latestChannel(
      package.id,
      effectiveChannel,
    );
    return UpdateResolver.resolve(
      packageName: package.name,
      currentVersion: currentVersion,
      channel: effectiveChannel,
      latest: latest,
      assets: latest == null
          ? const []
          : await provider.store.listAssets(latest.id),
      platform: platform,
    );
  }

  // ----------------------------------------------------------- providers ---

  @override
  Future<List<ProviderDescriptor>> listProviders({String? organization}) async {
    final selected = organization == null
        ? providers.all
        : providers.providersFor(organization, readable: false);
    return selected.map((p) => p.descriptor).toList();
  }

  @override
  Future<void> close() async {
    for (final provider in providers.all) {
      await provider.close();
    }
    await providers.close();
  }

  // ------------------------------------------------------------- routing ---

  /// Finds the provider owning the entity with [id], trying its cached owner
  /// first and then every readable provider.
  Future<(StoreProvider, T)?> _locate<T>(
    String id,
    Future<T?> Function(OmnyStoreApi store) lookup,
  ) async {
    final cachedId = _owners[id];
    if (cachedId != null) {
      final cached = providers.byId(cachedId);
      if (cached != null && cached.isReadable) {
        final found = await _guard(() => lookup(cached.store));
        if (found != null) return (cached, found);
      }
      // The cache was stale — the provider left, or the record moved. Drop it
      // and fall through to the fan-out rather than reporting a false miss.
      _owners.remove(id);
    }

    for (final provider in providers.readable) {
      if (provider.id == cachedId) continue;
      final found = await _guard(() => lookup(provider.store));
      if (found != null) {
        _remember(id, provider.id);
        return (provider, found);
      }
    }
    return null;
  }

  Future<(StoreProvider, T)> _requireOwnerOf<T>(
    String id,
    Future<T?> Function(OmnyStoreApi store) lookup,
    OmnyStoreException Function() notFound,
  ) async {
    final located = await _locate<T>(id, lookup);
    if (located == null) throw notFound();
    return located;
  }

  /// Resolves a package reference across the federation.
  ///
  /// A bare name matching packages on two different providers is ambiguous and
  /// raises rather than picking one: publishing a release into the wrong
  /// organization because two of them happened to name a package `agent` is
  /// exactly the failure that must never happen silently.
  Future<(StoreProvider, Package)> _resolvePackageOwner(
    String reference,
  ) async {
    final cachedId = _owners[reference];
    if (cachedId != null) {
      final cached = providers.byId(cachedId);
      if (cached != null && cached.isReadable) {
        final found = await _guard(() => cached.store.package(reference));
        if (found != null) return (cached, found);
      }
      _owners.remove(reference);
    }

    final matches = <(StoreProvider, Package)>[];
    for (final provider in providers.readable) {
      // `resolvePackage` throws on a miss; `package`/`findByName` semantics are
      // recovered by catching, so one provider not holding it is not an error.
      try {
        final found = await provider.store.resolvePackage(reference);
        matches.add((provider, found));
      } on PackageNotFoundException {
        continue;
      } on ValidationException {
        // Ambiguous *within* one provider — surface it rather than hiding it
        // behind a federation-level message that would mislead.
        rethrow;
      }
    }

    if (matches.isEmpty) throw PackageNotFoundException(reference);
    if (matches.length > 1) {
      throw ValidationException(
        "Package reference '$reference' is ambiguous across the federation: it "
        'matches on providers ${matches.map((m) => m.$1.id).join(', ')}. '
        'Use the package id instead.',
        field: 'package',
      );
    }
    _remember(reference, matches.first.$1.id);
    _remember(matches.first.$2.id, matches.first.$1.id);
    return matches.first;
  }

  /// Builds a name index for [provider]'s organizations and projects.
  ///
  /// Aggregated listings deduplicate on *natural* keys — `org/project/package`
  /// — because each provider mints its own ids, so an organization replicated
  /// across two nodes has two ids and keying on those would show it twice. The
  /// index is what turns a provider-local id back into the name the key needs.
  ///
  /// Rebuilt per call rather than cached: a stale index would hide a newly
  /// created project, and the two listings it costs are the same ones the
  /// aggregation would perform anyway.
  Future<_NameIndex> _indexOf(StoreProvider provider) async {
    final organizations =
        await _guard(() => provider.store.listOrganizations()) ?? const [];
    final projects =
        await _guard(() => provider.store.listProjects()) ?? const [];
    return _NameIndex(organizations, projects);
  }

  /// Aggregates a listing across every readable provider, deduplicating by
  /// [naturalKeyOf] and sorting with [compare].
  ///
  /// Deduplication is what makes replication invisible: an organization held by
  /// two nodes appears once. It keys on the entity's *natural* uniqueness
  /// constraint — a name, or a parent plus a name — rather than on its id,
  /// because ids are minted independently by each provider. Keying on id would
  /// make two genuinely different records collide if their ids ever coincided,
  /// which is a silent data-loss bug rather than a visible one.
  ///
  /// [idOf] is used only to populate the owner cache, so a later lookup of that
  /// id goes straight to the provider that reported it.
  Future<List<T>> _aggregate<T>(
    Future<List<T>> Function(OmnyStoreApi store) list,
    String Function(T item) naturalKeyOf,
    String Function(T item) idOf,
    int Function(T a, T b) compare,
  ) async {
    final byKey = <String, T>{};
    for (final provider in providers.readable) {
      final items = await _guard(() => list(provider.store)) ?? const [];
      for (final item in items) {
        if (byKey.putIfAbsent(naturalKeyOf(item), () => item) == item) {
          _remember(idOf(item), provider.id);
        }
      }
    }
    return byKey.values.toList()..sort(compare);
  }

  /// Runs [operation], turning a provider-level failure into `null`.
  ///
  /// One unreachable node must not break a federation-wide read: a listing
  /// should return what the healthy providers hold, and a lookup should keep
  /// searching. Failures are logged so a silently degraded hub is still
  /// diagnosable.
  Future<T?> _guard<T>(Future<T?> Function() operation) async {
    try {
      return await operation();
    } on OmnyStoreException catch (e) {
      logger.warn('Provider call failed', context: {'error': e.message});
      return null;
    }
  }

  void _remember(String id, String providerId) {
    if (_owners.length >= ownerCacheSize) {
      // A plain FIFO eviction. The cache is an optimisation over a fan-out that
      // still works, so the eviction policy only affects how often that fan-out
      // happens — not correctness.
      _owners.remove(_owners.keys.first);
    }
    _owners[id] = providerId;
  }
}

/// One provider's organization and project names, keyed by its own ids.
///
/// Exists so [OmnyStoreHub] can build provider-independent natural keys
/// (`acme/agent/omnyagent`) out of records that only carry provider-local ids.
class _NameIndex {
  final Map<String, String> _organizationNames;
  final Map<String, String> _organizationIds;
  final Map<String, String> _projectNames;
  final List<Project> _projects;

  _NameIndex(List<Organization> organizations, List<Project> projects)
    : _organizationNames = {for (final o in organizations) o.id: o.name},
      _organizationIds = {for (final o in organizations) o.name: o.id},
      _projectNames = {for (final p in projects) p.id: p.name},
      _projects = projects;

  /// The name of the organization with [id], falling back to the id itself.
  ///
  /// The fallback keeps a record whose parent is missing — a partially
  /// replicated provider — visible under a stable key rather than colliding
  /// with every other orphan.
  String organizationName(String id) => _organizationNames[id] ?? id;

  /// The name of the project with [id], falling back to the id itself.
  String projectName(String id) => _projectNames[id] ?? id;

  /// This provider's id for the organization named [name], or `null`.
  String? organizationIdOf(String name) => _organizationIds[name];

  /// This provider's id for the project named [name], optionally within
  /// [organization], or `null`.
  String? projectIdOf(String name, {String? organization}) {
    for (final project in _projects) {
      if (project.name != name) continue;
      if (organization != null && project.organizationId != organization) {
        continue;
      }
      return project.id;
    }
    return null;
  }
}
