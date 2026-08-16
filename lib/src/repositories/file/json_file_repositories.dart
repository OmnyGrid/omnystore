import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../exceptions/omnystore_exception.dart';
import '../../models/asset.dart';
import '../../models/asset_location.dart';
import '../../models/download_record.dart';
import '../../models/organization.dart';
import '../../models/package.dart';
import '../../models/project.dart';
import '../../models/release.dart';
import '../memory/memory_repositories.dart';
import '../repositories.dart';

/// Metadata repositories persisted as JSON files in a directory.
///
/// The second repository adapter, and the one that makes `omnystore server`
/// worth running: a registry whose catalogue vanished on restart would be a
/// demo, not a self-hosted release platform.
///
/// ```text
/// /var/lib/omnystore/metadata/
///   organizations.json
///   projects.json
///   packages.json
///   releases.json
///   assets.json
///   downloads.json
///   locations.json
/// ```
///
/// **It is a full-file, write-through store.** Every mutation rewrites the
/// affected collection and does not return until the bytes are on disk, so a
/// caller that saw `publishRelease` succeed can lose power immediately after
/// and still find the release there. Writes go to a temporary file and are
/// renamed into place, so a crash mid-write leaves the previous version intact
/// rather than a truncated one.
///
/// **Know its limits before choosing it.** Rewriting a whole collection per
/// mutation is `O(n)` in that collection's size, which is fine for the
/// thousands of releases a self-hosted registry holds and wrong for millions of
/// download records — cap those with [maxDownloadRecords], or point a real
/// database adapter at [StoreRepositories] instead. It also assumes a **single
/// writer**: two processes sharing one directory will clobber each other, so
/// run one server per directory.
///
/// ```dart
/// final repositories = await JsonFileRepositories.open('/var/lib/omnystore/metadata');
/// final store = OmnyStore(
///   repositories: repositories,
///   storage: LocalObjectStorage('/var/lib/omnystore/objects'),
/// );
/// ```
class JsonFileRepositories extends StoreRepositories {
  /// The directory holding the JSON files.
  final Directory directory;

  final _JsonCollection<Organization> _organizations;
  final _JsonCollection<Project> _projects;
  final _JsonCollection<Package> _packages;
  final _JsonCollection<Release> _releases;
  final _JsonCollection<Asset> _assets;
  final _JsonCollection<DownloadRecord> _downloads;
  final _JsonCollection<AssetLocation> _locations;

  JsonFileRepositories._({
    required this.directory,
    required MemoryOrganizationRepository organizations,
    required MemoryProjectRepository projects,
    required MemoryPackageRepository packages,
    required MemoryReleaseRepository releases,
    required MemoryAssetRepository assets,
    required MemoryDownloadRepository downloads,
    required MemoryAssetLocationRepository locations,
    required _JsonCollection<Organization> organizationFile,
    required _JsonCollection<Project> projectFile,
    required _JsonCollection<Package> packageFile,
    required _JsonCollection<Release> releaseFile,
    required _JsonCollection<Asset> assetFile,
    required _JsonCollection<DownloadRecord> downloadFile,
    required _JsonCollection<AssetLocation> locationFile,
  }) : _organizations = organizationFile,
       _projects = projectFile,
       _packages = packageFile,
       _releases = releaseFile,
       _assets = assetFile,
       _downloads = downloadFile,
       _locations = locationFile,
       super(
         organizations: organizations,
         projects: projects,
         packages: packages,
         releases: releases,
         assets: assets,
         downloads: downloads,
         locations: locations,
       );

  /// Opens (and creates if absent) the repositories rooted at [path], loading
  /// whatever is already there.
  ///
  /// A corrupt or unreadable file raises [StorageException] rather than
  /// starting with an empty catalogue: silently serving an empty registry
  /// because a JSON file was truncated would look to every client exactly like
  /// every release having been deleted.
  static Future<JsonFileRepositories> open(
    String path, {
    int? maxDownloadRecords = 100000,
  }) async {
    final directory = Directory(p.normalize(p.absolute(path)));
    await directory.create(recursive: true);

    final organizations = MemoryOrganizationRepository();
    final projects = MemoryProjectRepository();
    final packages = MemoryPackageRepository();
    final releases = MemoryReleaseRepository();
    final assets = MemoryAssetRepository();
    final downloads = MemoryDownloadRepository(maxRecords: maxDownloadRecords);
    final locations = MemoryAssetLocationRepository();

    final organizationFile = _JsonCollection<Organization>(
      directory,
      'organizations',
      Organization.fromJson,
      (o) => o.toJson(),
    );
    final projectFile = _JsonCollection<Project>(
      directory,
      'projects',
      Project.fromJson,
      (o) => o.toJson(),
    );
    final packageFile = _JsonCollection<Package>(
      directory,
      'packages',
      Package.fromJson,
      (o) => o.toJson(),
    );
    final releaseFile = _JsonCollection<Release>(
      directory,
      'releases',
      Release.fromJson,
      (o) => o.toJson(),
    );
    final assetFile = _JsonCollection<Asset>(
      directory,
      'assets',
      Asset.fromJson,
      (o) => o.toJson(),
    );
    final downloadFile = _JsonCollection<DownloadRecord>(
      directory,
      'downloads',
      DownloadRecord.fromJson,
      (o) => o.toJson(),
    );
    final locationFile = _JsonCollection<AssetLocation>(
      directory,
      'locations',
      AssetLocation.fromJson,
      (o) => o.toJson(),
    );

    organizations.restore(await organizationFile.read());
    projects.restore(await projectFile.read());
    packages.restore(await packageFile.read());
    releases.restore(await releaseFile.read());
    assets.restore(await assetFile.read());
    downloads.restore(await downloadFile.read());
    locations.restore(await locationFile.read());

    organizations.onChanged = () =>
        organizationFile.write(organizations.snapshot());
    projects.onChanged = () => projectFile.write(projects.snapshot());
    packages.onChanged = () => packageFile.write(packages.snapshot());
    releases.onChanged = () => releaseFile.write(releases.snapshot());
    assets.onChanged = () => assetFile.write(assets.snapshot());
    downloads.onChanged = () => downloadFile.write(downloads.snapshot());
    locations.onChanged = () => locationFile.write(locations.snapshot());

    return JsonFileRepositories._(
      directory: directory,
      organizations: organizations,
      projects: projects,
      packages: packages,
      releases: releases,
      assets: assets,
      downloads: downloads,
      locations: locations,
      organizationFile: organizationFile,
      projectFile: projectFile,
      packageFile: packageFile,
      releaseFile: releaseFile,
      assetFile: assetFile,
      downloadFile: downloadFile,
      locationFile: locationFile,
    );
  }

  /// Waits for every pending write to reach disk.
  ///
  /// Mutations already flush before their future completes, so this only
  /// matters on shutdown, where a caller wants one place to await rather than
  /// tracking each repository.
  Future<void> flush() => Future.wait([
    _organizations.settled,
    _projects.settled,
    _packages.settled,
    _releases.settled,
    _assets.settled,
    _downloads.settled,
    _locations.settled,
  ]);
}

/// One JSON file holding a list of records.
class _JsonCollection<T> {
  final Directory directory;
  final String name;
  final T Function(Map<String, dynamic>) fromJson;
  final Map<String, dynamic> Function(T) toJson;

  /// The in-flight write, so [settled] can await it and so two writes never
  /// interleave on the same file.
  Future<void> _pending = Future.value();

  _JsonCollection(this.directory, this.name, this.fromJson, this.toJson);

  File get _file => File(p.join(directory.path, '$name.json'));

  Future<void> get settled => _pending;

  /// Reads the collection, returning empty if the file does not exist.
  Future<List<T>> read() async {
    final file = _file;
    if (!await file.exists()) return const [];

    final String contents;
    try {
      contents = await file.readAsString();
    } on FileSystemException catch (e) {
      throw StorageException('Cannot read ${file.path}: ${e.message}');
    }
    if (contents.trim().isEmpty) return const [];

    try {
      final decoded = jsonDecode(contents);
      if (decoded is! List) {
        throw StorageException(
          '${file.path} does not contain a JSON array of $name',
        );
      }
      return [
        for (final item in decoded)
          fromJson((item as Map).cast<String, dynamic>()),
      ];
    } on OmnyStoreException {
      rethrow;
    } on Object catch (e) {
      // Refusing to start beats starting with an empty catalogue: to every
      // client the latter is indistinguishable from every release having been
      // deleted, and they would act on it.
      throw StorageException(
        'Cannot parse ${file.path}: $e. Restore it from a backup, or move it '
        'aside to start with an empty $name collection.',
      );
    }
  }

  /// Serialises [records] and writes them atomically.
  ///
  /// Chained onto the previous write rather than run concurrently: two writes
  /// racing on one path could rename in the wrong order and persist the older
  /// snapshot.
  Future<void> write(List<T> records) {
    return _pending = _pending.then((_) => _writeNow(records));
  }

  Future<void> _writeNow(List<T> records) async {
    final file = _file;
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsString(
        // Indented so the files are readable and diffable by an operator, which
        // is most of the point of a JSON-on-disk store.
        const JsonEncoder.withIndent(
          '  ',
        ).convert([for (final record in records) toJson(record)]),
        flush: true,
      );
      // Atomic within one filesystem: readers see either the old file or the
      // new one, never a partial write.
      await temp.rename(file.path);
    } on FileSystemException catch (e) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort; the stale temp file is harmless.
        }
      }
      throw StorageException('Cannot write ${file.path}: ${e.message}');
    }
  }
}
