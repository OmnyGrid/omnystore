/// Persistence ports for the registry's metadata.
///
/// Every method is asynchronous even though the bundled in-memory adapter
/// answers synchronously: the contract has to fit a SQL, Firestore or
/// object-store backend without any caller changing, and a synchronous
/// signature would make that impossible to add later.
///
/// Repositories are **stores, not validators**. They do not enforce that a
/// project's organization exists or that a version has not already been
/// published — those are business rules and they live in `OmnyStore`, so they
/// apply identically no matter which adapter is plugged in. Repositories
/// enforce only their own uniqueness invariants, and return `null` rather than
/// throwing when a lookup misses.
library;

import 'package:pub_semver/pub_semver.dart';

import '../models/asset.dart';
import '../models/asset_location.dart';
import '../models/download_record.dart';
import '../models/organization.dart';
import '../models/package.dart';
import '../models/project.dart';
import '../models/release.dart';
import 'release_query.dart';

/// Stores [Organization] records, keyed by id and by unique name.
abstract interface class OrganizationRepository {
  /// Inserts or replaces [organization], keyed by its id.
  Future<void> save(Organization organization);

  /// The organization with [id], or `null`.
  Future<Organization?> byId(String id);

  /// The organization named [name], or `null`. Names are globally unique.
  Future<Organization?> byName(String name);

  /// Every organization, ordered by name.
  Future<List<Organization>> list();

  /// Deletes the organization with [id]. Returns whether one was removed.
  ///
  /// Deleting an organization does **not** cascade here; `OmnyStore` removes
  /// the dependent records, so an adapter with real foreign keys and one
  /// without behave the same way.
  Future<bool> delete(String id);
}

/// Stores [Project] records, keyed by id and by (organization, name).
abstract interface class ProjectRepository {
  /// Inserts or replaces [project], keyed by its id.
  Future<void> save(Project project);

  /// The project with [id], or `null`.
  Future<Project?> byId(String id);

  /// The project named [name] within [organizationId], or `null`.
  Future<Project?> byName(String organizationId, String name);

  /// Every project of [organizationId], ordered by name.
  Future<List<Project>> listByOrganization(String organizationId);

  /// Every project, ordered by organization then name.
  Future<List<Project>> list();

  /// Deletes the project with [id]. Returns whether one was removed.
  Future<bool> delete(String id);
}

/// Stores [Package] records, keyed by id and by (project, name).
abstract interface class PackageRepository {
  /// Inserts or replaces [package], keyed by its id.
  Future<void> save(Package package);

  /// The package with [id], or `null`.
  Future<Package?> byId(String id);

  /// The package named [name] within [projectId], or `null`.
  Future<Package?> byName(String projectId, String name);

  /// Every package named [name] across the whole store, ordered by id.
  ///
  /// Package names are unique per *project*, so a bare name may be ambiguous.
  /// The CLI and the update endpoint accept one anyway — `--package omnyagent`
  /// is what people type — and `OmnyStore` resolves it, raising a
  /// `ValidationException` when it matches more than one. This is the lookup
  /// that lets it detect that instead of silently picking the first.
  Future<List<Package>> findByName(String name);

  /// Every package of [projectId], ordered by name.
  Future<List<Package>> listByProject(String projectId);

  /// Every package of [organizationId], ordered by name.
  Future<List<Package>> listByOrganization(String organizationId);

  /// Every package, ordered by name.
  Future<List<Package>> list();

  /// Deletes the package with [id]. Returns whether one was removed.
  Future<bool> delete(String id);
}

/// Stores [Release] records, keyed by id and by (package, version).
abstract interface class ReleaseRepository {
  /// Inserts or replaces [release], keyed by its id.
  Future<void> save(Release release);

  /// The release with [id], or `null`.
  Future<Release?> byId(String id);

  /// The release of [packageId] at [version], or `null`.
  ///
  /// Matching is exact, including build metadata: `1.0.0+build1` and
  /// `1.0.0+build2` are different releases.
  Future<Release?> byVersion(String packageId, Version version);

  /// The releases of [packageId] matching [query], newest first.
  Future<List<Release>> listByPackage(
    String packageId, {
    ReleaseQuery query = const ReleaseQuery(),
  });

  /// The releases of [organizationId] matching [query], newest first.
  Future<List<Release>> listByOrganization(
    String organizationId, {
    ReleaseQuery query = const ReleaseQuery(),
  });

  /// The newest release of [packageId] matching [query], or `null`.
  ///
  /// Separate from [listByPackage] so an adapter can answer it with an indexed
  /// `ORDER BY ... LIMIT 1` instead of materialising every release — this is
  /// the hottest query in the system, since every running client calls it.
  Future<Release?> latest(
    String packageId, {
    ReleaseQuery query = const ReleaseQuery(),
  });

  /// Deletes the release with [id]. Returns whether one was removed.
  Future<bool> delete(String id);
}

/// Stores [Asset] records, keyed by id and by (release, name).
abstract interface class AssetRepository {
  /// Inserts or replaces [asset], keyed by its id.
  Future<void> save(Asset asset);

  /// The asset with [id], or `null`.
  Future<Asset?> byId(String id);

  /// The asset named [name] within [releaseId], or `null`.
  Future<Asset?> byName(String releaseId, String name);

  /// Every asset of [releaseId], ordered by name.
  Future<List<Asset>> listByRelease(String releaseId);

  /// Every asset of [packageId], ordered by release then name.
  Future<List<Asset>> listByPackage(String packageId);

  /// Increments [id]'s download counter by [by] and returns the updated asset,
  /// or `null` if it does not exist.
  ///
  /// Its own method rather than a read-modify-write by the caller because two
  /// concurrent downloads of one asset would otherwise lose a count; an adapter
  /// with atomic increments can implement it without a transaction.
  Future<Asset?> incrementDownloadCount(String id, {int by = 1});

  /// Deletes the asset with [id]. Returns whether one was removed.
  Future<bool> delete(String id);
}

/// Stores [DownloadRecord]s — append-only, and the highest-volume table in the
/// system by a wide margin.
abstract interface class DownloadRepository {
  /// Appends [record].
  Future<void> save(DownloadRecord record);

  /// The record with [id], or `null`.
  Future<DownloadRecord?> byId(String id);

  /// Records for [assetId], newest first, at most [limit].
  Future<List<DownloadRecord>> listByAsset(String assetId, {int? limit});

  /// Records for [packageId], newest first, at most [limit], optionally
  /// restricted to the `[from, to)` window.
  Future<List<DownloadRecord>> listByPackage(
    String packageId, {
    int? limit,
    DateTime? from,
    DateTime? to,
  });

  /// Aggregated statistics for [packageId] over the `[from, to)` window.
  Future<DownloadStats> statsByPackage(
    String packageId, {
    DateTime? from,
    DateTime? to,
  });

  /// Deletes every record for [assetId], returning how many were removed.
  /// Used when an asset is deleted and its history should go with it.
  Future<int> deleteByAsset(String assetId);
}

/// Stores [AssetLocation] placement records — which provider holds which
/// asset's bytes.
///
/// This is the index the hub consults on every download to pick a provider, and
/// the one a replication pass reconciles against.
abstract interface class AssetLocationRepository {
  /// Inserts or replaces [location], keyed by its id.
  Future<void> save(AssetLocation location);

  /// Every placement of [assetId], best-first is *not* implied — the caller
  /// selects among them.
  Future<List<AssetLocation>> byAsset(String assetId);

  /// The placement of [assetId] on [providerId], or `null`.
  Future<AssetLocation?> byAssetAndProvider(String assetId, String providerId);

  /// Every placement held by [providerId].
  Future<List<AssetLocation>> byProvider(String providerId);

  /// Every placement belonging to [organizationId].
  Future<List<AssetLocation>> byOrganization(String organizationId);

  /// Deletes the placement with [id]. Returns whether one was removed.
  Future<bool> delete(String id);

  /// Deletes every placement of [assetId], returning how many were removed.
  Future<int> deleteByAsset(String assetId);
}

/// The full set of metadata repositories, injected into `OmnyStore` as one
/// unit.
///
/// A bundle rather than seven constructor parameters because they are always
/// swapped together — an adapter implements all of them against one backend,
/// and a caller that mixed a SQL release repository with an in-memory package
/// repository would get a store that half-survives a restart.
class StoreRepositories {
  /// Organization storage.
  final OrganizationRepository organizations;

  /// Project storage.
  final ProjectRepository projects;

  /// Package storage.
  final PackageRepository packages;

  /// Release storage.
  final ReleaseRepository releases;

  /// Asset metadata storage.
  final AssetRepository assets;

  /// Download history storage.
  final DownloadRepository downloads;

  /// Asset placement storage.
  final AssetLocationRepository locations;

  /// Bundles the repositories.
  const StoreRepositories({
    required this.organizations,
    required this.projects,
    required this.packages,
    required this.releases,
    required this.assets,
    required this.downloads,
    required this.locations,
  });
}
