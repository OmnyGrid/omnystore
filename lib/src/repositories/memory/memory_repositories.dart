/// In-memory implementations of every metadata repository.
///
/// These are not only test doubles. They are the storage backend for the two
/// deployments that do not want a database: an embedded, single-process store
/// whose registry is rebuilt at startup, and a CI job that publishes to a
/// throwaway registry. Because they implement exactly the same contracts as a
/// future SQL adapter, business logic never learns which one it has.
///
/// All state is per-instance; there are no statics, so tests run in parallel
/// without interfering.
library;

import 'package:pub_semver/pub_semver.dart';

import '../../models/asset.dart';
import '../../models/asset_location.dart';
import '../../models/download_record.dart';
import '../../models/organization.dart';
import '../../models/package.dart';
import '../../models/project.dart';
import '../../models/release.dart';
import '../repositories.dart';
import '../release_query.dart';

/// Called after a repository mutates, so a persistence layer can flush.
///
/// The seam that lets `JsonFileRepositories` reuse these implementations
/// verbatim instead of reimplementing every query against a file. The hook is
/// awaited before the mutation's future completes, so a caller that has seen
/// `save` return knows the change is durable.
typedef RepositoryChanged = Future<void> Function();

/// An in-memory [OrganizationRepository].
class MemoryOrganizationRepository implements OrganizationRepository {
  final Map<String, Organization> _byId = {};

  /// Invoked after every mutation. `null` for a purely in-memory repository.
  RepositoryChanged? onChanged;

  /// Creates an empty repository.
  MemoryOrganizationRepository({this.onChanged});

  /// Every record held, for a persistence layer to serialise.
  List<Organization> snapshot() => _byId.values.toList();

  /// Replaces the contents with [records], without triggering [onChanged].
  void restore(Iterable<Organization> records) {
    _byId
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.id, r)));
  }

  @override
  Future<void> save(Organization organization) async {
    _byId[organization.id] = organization;
    await onChanged?.call();
  }

  @override
  Future<Organization?> byId(String id) async => _byId[id];

  @override
  Future<Organization?> byName(String name) async {
    for (final organization in _byId.values) {
      if (organization.name == name) return organization;
    }
    return null;
  }

  @override
  Future<List<Organization>> list() async =>
      _byId.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<bool> delete(String id) async {
    final removed = _byId.remove(id) != null;
    if (removed) await onChanged?.call();
    return removed;
  }
}

/// An in-memory [ProjectRepository].
class MemoryProjectRepository implements ProjectRepository {
  final Map<String, Project> _byId = {};

  /// Invoked after every mutation.
  RepositoryChanged? onChanged;

  /// Creates an empty repository.
  MemoryProjectRepository({this.onChanged});

  /// Every record held, for a persistence layer to serialise.
  List<Project> snapshot() => _byId.values.toList();

  /// Replaces the contents with [records], without triggering [onChanged].
  void restore(Iterable<Project> records) {
    _byId
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.id, r)));
  }

  @override
  Future<void> save(Project project) async {
    _byId[project.id] = project;
    await onChanged?.call();
  }

  @override
  Future<Project?> byId(String id) async => _byId[id];

  @override
  Future<Project?> byName(String organizationId, String name) async {
    for (final project in _byId.values) {
      if (project.organizationId == organizationId && project.name == name) {
        return project;
      }
    }
    return null;
  }

  @override
  Future<List<Project>> listByOrganization(String organizationId) async =>
      _byId.values.where((p) => p.organizationId == organizationId).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<List<Project>> list() async => _byId.values.toList()
    ..sort((a, b) {
      final byOrg = a.organizationId.compareTo(b.organizationId);
      return byOrg != 0 ? byOrg : a.name.compareTo(b.name);
    });

  @override
  Future<bool> delete(String id) async {
    final removed = _byId.remove(id) != null;
    if (removed) await onChanged?.call();
    return removed;
  }
}

/// An in-memory [PackageRepository].
class MemoryPackageRepository implements PackageRepository {
  final Map<String, Package> _byId = {};

  /// Invoked after every mutation.
  RepositoryChanged? onChanged;

  /// Creates an empty repository.
  MemoryPackageRepository({this.onChanged});

  /// Every record held, for a persistence layer to serialise.
  List<Package> snapshot() => _byId.values.toList();

  /// Replaces the contents with [records], without triggering [onChanged].
  void restore(Iterable<Package> records) {
    _byId
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.id, r)));
  }

  @override
  Future<void> save(Package package) async {
    _byId[package.id] = package;
    await onChanged?.call();
  }

  @override
  Future<Package?> byId(String id) async => _byId[id];

  @override
  Future<Package?> byName(String projectId, String name) async {
    for (final package in _byId.values) {
      if (package.projectId == projectId && package.name == name) {
        return package;
      }
    }
    return null;
  }

  @override
  Future<List<Package>> findByName(String name) async =>
      _byId.values.where((p) => p.name == name).toList()
        ..sort((a, b) => a.id.compareTo(b.id));

  @override
  Future<List<Package>> listByProject(String projectId) async =>
      _byId.values.where((p) => p.projectId == projectId).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<List<Package>> listByOrganization(String organizationId) async =>
      _byId.values.where((p) => p.organizationId == organizationId).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<List<Package>> list() async =>
      _byId.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<bool> delete(String id) async {
    final removed = _byId.remove(id) != null;
    if (removed) await onChanged?.call();
    return removed;
  }
}

/// An in-memory [ReleaseRepository].
class MemoryReleaseRepository implements ReleaseRepository {
  final Map<String, Release> _byId = {};

  /// Invoked after every mutation.
  RepositoryChanged? onChanged;

  /// Creates an empty repository.
  MemoryReleaseRepository({this.onChanged});

  /// Every record held, for a persistence layer to serialise.
  List<Release> snapshot() => _byId.values.toList();

  /// Replaces the contents with [records], without triggering [onChanged].
  void restore(Iterable<Release> records) {
    _byId
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.id, r)));
  }

  @override
  Future<void> save(Release release) async {
    _byId[release.id] = release;
    await onChanged?.call();
  }

  @override
  Future<Release?> byId(String id) async => _byId[id];

  @override
  Future<Release?> byVersion(String packageId, Version version) async {
    for (final release in _byId.values) {
      // Compares by `==` rather than by precedence, so `1.0.0+build1` does not
      // collide with `1.0.0+build2` — they are distinct artifacts.
      if (release.packageId == packageId && release.version == version) {
        return release;
      }
    }
    return null;
  }

  @override
  Future<List<Release>> listByPackage(
    String packageId, {
    ReleaseQuery query = const ReleaseQuery(),
  }) async => query.apply(_byId.values.where((r) => r.packageId == packageId));

  @override
  Future<List<Release>> listByOrganization(
    String organizationId, {
    ReleaseQuery query = const ReleaseQuery(),
  }) async => query.apply(
    _byId.values.where((r) => r.organizationId == organizationId),
  );

  @override
  Future<Release?> latest(
    String packageId, {
    ReleaseQuery query = const ReleaseQuery(),
  }) async {
    // Ignores the query's paging: "the latest matching release" means the head
    // of the filtered, sorted sequence, and applying an offset here would
    // silently answer a different question.
    final matches = query
        .copyWith(limit: 1, offset: 0)
        .apply(_byId.values.where((r) => r.packageId == packageId));
    return matches.isEmpty ? null : matches.first;
  }

  @override
  Future<bool> delete(String id) async {
    final removed = _byId.remove(id) != null;
    if (removed) await onChanged?.call();
    return removed;
  }
}

/// An in-memory [AssetRepository].
class MemoryAssetRepository implements AssetRepository {
  final Map<String, Asset> _byId = {};

  /// Invoked after every mutation.
  RepositoryChanged? onChanged;

  /// Creates an empty repository.
  MemoryAssetRepository({this.onChanged});

  /// Every record held, for a persistence layer to serialise.
  List<Asset> snapshot() => _byId.values.toList();

  /// Replaces the contents with [records], without triggering [onChanged].
  void restore(Iterable<Asset> records) {
    _byId
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.id, r)));
  }

  @override
  Future<void> save(Asset asset) async {
    _byId[asset.id] = asset;
    await onChanged?.call();
  }

  @override
  Future<Asset?> byId(String id) async => _byId[id];

  @override
  Future<Asset?> byName(String releaseId, String name) async {
    for (final asset in _byId.values) {
      if (asset.releaseId == releaseId && asset.name == name) return asset;
    }
    return null;
  }

  @override
  Future<List<Asset>> listByRelease(String releaseId) async =>
      _byId.values.where((a) => a.releaseId == releaseId).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<List<Asset>> listByPackage(String packageId) async =>
      _byId.values.where((a) => a.packageId == packageId).toList()
        ..sort((a, b) {
          final byRelease = a.releaseId.compareTo(b.releaseId);
          return byRelease != 0 ? byRelease : a.name.compareTo(b.name);
        });

  @override
  Future<Asset?> incrementDownloadCount(String id, {int by = 1}) async {
    final asset = _byId[id];
    if (asset == null) return null;
    final updated = asset.copyWith(downloadCount: asset.downloadCount + by);
    _byId[id] = updated;
    await onChanged?.call();
    return updated;
  }

  @override
  Future<bool> delete(String id) async {
    final removed = _byId.remove(id) != null;
    if (removed) await onChanged?.call();
    return removed;
  }
}

/// An in-memory [DownloadRepository].
///
/// Download history is unbounded by nature, so this adapter accepts a
/// [maxRecords] cap and discards the oldest records beyond it. Without one, a
/// long-lived embedded store would grow until the process died — a silent leak
/// that only shows up in production. `null` disables the cap for callers who
/// want every record and manage the lifetime themselves.
class MemoryDownloadRepository implements DownloadRepository {
  final List<DownloadRecord> _records = [];

  /// The maximum number of records retained, oldest discarded first. `null`
  /// retains everything.
  final int? maxRecords;

  /// Invoked after every mutation.
  RepositoryChanged? onChanged;

  /// Creates an empty repository retaining at most [maxRecords] records
  /// (default 100000).
  MemoryDownloadRepository({this.maxRecords = 100000, this.onChanged});

  /// Every record held, for a persistence layer to serialise.
  List<DownloadRecord> snapshot() => List.of(_records);

  /// Replaces the contents with [records], without triggering [onChanged].
  void restore(Iterable<DownloadRecord> records) {
    _records
      ..clear()
      ..addAll(records);
  }

  @override
  Future<void> save(DownloadRecord record) async {
    _records.add(record);
    final cap = maxRecords;
    if (cap != null && _records.length > cap) {
      _records.removeRange(0, _records.length - cap);
    }
    await onChanged?.call();
  }

  @override
  Future<DownloadRecord?> byId(String id) async {
    for (final record in _records) {
      if (record.id == id) return record;
    }
    return null;
  }

  @override
  Future<List<DownloadRecord>> listByAsset(
    String assetId, {
    int? limit,
  }) async => _newestFirst(_records.where((r) => r.assetId == assetId), limit);

  @override
  Future<List<DownloadRecord>> listByPackage(
    String packageId, {
    int? limit,
    DateTime? from,
    DateTime? to,
  }) async => _newestFirst(
    _records.where(
      (r) => r.packageId == packageId && _inWindow(r.downloadedAt, from, to),
    ),
    limit,
  );

  @override
  Future<DownloadStats> statsByPackage(
    String packageId, {
    DateTime? from,
    DateTime? to,
  }) async {
    final byVersion = <String, int>{};
    final byAsset = <String, int>{};
    var total = 0;
    for (final record in _records) {
      if (record.packageId != packageId) continue;
      if (!_inWindow(record.downloadedAt, from, to)) continue;
      total++;
      byVersion[record.version] = (byVersion[record.version] ?? 0) + 1;
      byAsset[record.assetId] = (byAsset[record.assetId] ?? 0) + 1;
    }
    return DownloadStats(
      total: total,
      byVersion: byVersion,
      byAsset: byAsset,
      from: from,
      to: to,
    );
  }

  @override
  Future<int> deleteByAsset(String assetId) async {
    final before = _records.length;
    _records.removeWhere((r) => r.assetId == assetId);
    final removed = before - _records.length;
    if (removed > 0) await onChanged?.call();
    return removed;
  }

  static bool _inWindow(DateTime at, DateTime? from, DateTime? to) =>
      (from == null || !at.isBefore(from)) && (to == null || at.isBefore(to));

  static List<DownloadRecord> _newestFirst(
    Iterable<DownloadRecord> records,
    int? limit,
  ) {
    final sorted = records.toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    if (limit == null || limit >= sorted.length) return sorted;
    return sorted.sublist(0, limit < 0 ? 0 : limit);
  }
}

/// An in-memory [AssetLocationRepository].
class MemoryAssetLocationRepository implements AssetLocationRepository {
  final Map<String, AssetLocation> _byId = {};

  /// Invoked after every mutation.
  RepositoryChanged? onChanged;

  /// Creates an empty repository.
  MemoryAssetLocationRepository({this.onChanged});

  /// Every record held, for a persistence layer to serialise.
  List<AssetLocation> snapshot() => _byId.values.toList();

  /// Replaces the contents with [records], without triggering [onChanged].
  void restore(Iterable<AssetLocation> records) {
    _byId
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.id, r)));
  }

  @override
  Future<void> save(AssetLocation location) async {
    _byId[location.id] = location;
    await onChanged?.call();
  }

  @override
  Future<List<AssetLocation>> byAsset(String assetId) async =>
      _byId.values.where((l) => l.assetId == assetId).toList()
        ..sort((a, b) => a.providerId.compareTo(b.providerId));

  @override
  Future<AssetLocation?> byAssetAndProvider(
    String assetId,
    String providerId,
  ) async {
    for (final location in _byId.values) {
      if (location.assetId == assetId && location.providerId == providerId) {
        return location;
      }
    }
    return null;
  }

  @override
  Future<List<AssetLocation>> byProvider(String providerId) async =>
      _byId.values.where((l) => l.providerId == providerId).toList()
        ..sort((a, b) => a.assetId.compareTo(b.assetId));

  @override
  Future<List<AssetLocation>> byOrganization(String organizationId) async =>
      _byId.values.where((l) => l.organizationId == organizationId).toList()
        ..sort((a, b) => a.assetId.compareTo(b.assetId));

  @override
  Future<bool> delete(String id) async {
    final removed = _byId.remove(id) != null;
    if (removed) await onChanged?.call();
    return removed;
  }

  @override
  Future<int> deleteByAsset(String assetId) async {
    final before = _byId.length;
    _byId.removeWhere((_, l) => l.assetId == assetId);
    final removed = before - _byId.length;
    if (removed > 0) await onChanged?.call();
    return removed;
  }
}

/// A complete in-memory [StoreRepositories] bundle.
///
/// ```dart
/// final store = OmnyStore(
///   repositories: MemoryRepositories(),
///   storage: MemoryObjectStorage(),
/// );
/// ```
class MemoryRepositories extends StoreRepositories {
  /// Creates a bundle of fresh, empty in-memory repositories.
  ///
  /// [maxDownloadRecords] caps the retained download history; see
  /// [MemoryDownloadRepository].
  MemoryRepositories({int? maxDownloadRecords = 100000})
    : super(
        organizations: MemoryOrganizationRepository(),
        projects: MemoryProjectRepository(),
        packages: MemoryPackageRepository(),
        releases: MemoryReleaseRepository(),
        assets: MemoryAssetRepository(),
        downloads: MemoryDownloadRepository(maxRecords: maxDownloadRecords),
        locations: MemoryAssetLocationRepository(),
      );
}
