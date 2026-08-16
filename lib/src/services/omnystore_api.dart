import 'package:pub_semver/pub_semver.dart';

import '../channels/release_channel.dart';
import '../models/asset.dart';
import '../models/download_record.dart';
import '../models/organization.dart';
import '../models/package.dart';
import '../models/project.dart';
import '../models/provider_descriptor.dart';
import '../models/release.dart';
import '../models/update_info.dart';
import '../repositories/release_query.dart';
import '../storage/object_storage.dart';
import 'asset_download.dart';

/// The registry's complete operation surface, implemented three times over.
///
/// | Implementation | Where the data is | Typical use |
/// |---|---|---|
/// | `OmnyStore` | local repositories + object storage | embedded, or a node |
/// | `OmnyStoreHub` | federated across providers | the discovery point |
/// | `OmnyStoreClient` | a remote server, over REST | apps, CI, the CLI |
///
/// One interface for all three is the point. A CI script that publishes a
/// release, an updater that checks a channel, a test that exercises the whole
/// lifecycle — each is written once against this contract and then runs
/// embedded, against a hub, or over the network, by changing the construction
/// and nothing else.
///
/// **Errors** are the typed hierarchy in `OmnyStoreException`, and they are the
/// same whichever implementation raised them: `OmnyStoreClient` reconstructs
/// the server's exception type from the error envelope, so `on
/// ReleaseNotFoundException` works over HTTP exactly as it does in-process.
abstract interface class OmnyStoreApi {
  // ---------------------------------------------------------------- orgs ---

  /// Creates an organization named [name].
  ///
  /// Throws [ValidationException] if [name] is not a valid name, or
  /// [ConflictException] if one already exists.
  Future<Organization> createOrganization({
    required String name,
    String? displayName,
    String? description,
    String? website,
    Map<String, String> metadata = const {},
  });

  /// The organization with [id], or `null`.
  Future<Organization?> organization(String id);

  /// The organization named [name], or `null`.
  Future<Organization?> organizationByName(String name);

  /// Every organization, ordered by name.
  Future<List<Organization>> listOrganizations();

  /// Updates the mutable fields of the organization with [id].
  ///
  /// Throws [OrganizationNotFoundException] if it does not exist. [name] cannot
  /// be changed — it is a routing key; see [Organization].
  Future<Organization> updateOrganization(
    String id, {
    String? displayName,
    String? description,
    String? website,
    Map<String, String>? metadata,
  });

  /// Deletes the organization with [id] and everything under it.
  ///
  /// [force] must be `true` to delete one that still has projects; without it
  /// a populated organization raises [ConflictException] rather than silently
  /// destroying every release it owns.
  Future<void> deleteOrganization(String id, {bool force = false});

  // ------------------------------------------------------------ projects ---

  /// Creates a project named [name] under [organizationId].
  Future<Project> createProject({
    required String organizationId,
    required String name,
    String? displayName,
    String? description,
    String? repository,
    String? website,
    Map<String, String> metadata = const {},
  });

  /// The project with [id], or `null`.
  Future<Project?> project(String id);

  /// The project named [name] within [organizationId], or `null`.
  Future<Project?> projectByName(String organizationId, String name);

  /// Projects of [organizationId], or every project when it is `null`.
  Future<List<Project>> listProjects({String? organizationId});

  /// Updates the mutable fields of the project with [id].
  Future<Project> updateProject(
    String id, {
    String? displayName,
    String? description,
    String? repository,
    String? website,
    Map<String, String>? metadata,
  });

  /// Deletes the project with [id]. [force] is required if it has packages.
  Future<void> deleteProject(String id, {bool force = false});

  // ------------------------------------------------------------ packages ---

  /// Creates a package named [name] under [projectId].
  Future<Package> createPackage({
    required String projectId,
    required String name,
    String? displayName,
    String? description,
    ReleaseChannel defaultChannel = ReleaseChannel.release,
    List<String> platforms = const [],
    Map<String, String> metadata = const {},
  });

  /// The package with [id], or `null`.
  Future<Package?> package(String id);

  /// The package named [name] within [projectId], or `null`.
  Future<Package?> packageByName(String projectId, String name);

  /// Resolves a package from an id or a bare name.
  ///
  /// Everything user-facing — the CLI's `--package omnyagent`, the API's
  /// `/packages/{id}` — accepts either, because requiring an opaque id for the
  /// common single-tenant case would make the tool unusable by hand.
  ///
  /// Throws [PackageNotFoundException] if nothing matches, or
  /// [ValidationException] if a bare name is ambiguous across projects — an
  /// ambiguous reference must never be resolved by picking one arbitrarily.
  Future<Package> resolvePackage(String reference);

  /// Packages of [projectId] or [organizationId], or every package when both
  /// are `null`.
  Future<List<Package>> listPackages({
    String? projectId,
    String? organizationId,
  });

  /// Updates the mutable fields of the package with [id].
  Future<Package> updatePackage(
    String id, {
    String? displayName,
    String? description,
    ReleaseChannel? defaultChannel,
    List<String>? platforms,
    Map<String, String>? metadata,
  });

  /// Deletes the package with [id]. [force] is required if it has releases.
  Future<void> deletePackage(String id, {bool force = false});

  // ------------------------------------------------------------ releases ---

  /// Publishes [version] of the package [packageReference] resolves to.
  ///
  /// The channel is derived from the version's pre-release tag, so
  /// `1.2.0-beta.1` publishes to beta and `1.2.0` to release; there is no way
  /// for the two to disagree.
  ///
  /// Throws [ConflictException] if that version already exists — releases are
  /// immutable, so a rebuild gets a new version rather than overwriting one
  /// clients may already have downloaded.
  ///
  /// A [draft] release is stored but never offered by `latest*` queries or the
  /// update service until [publishRelease] is called again with `draft: false`
  /// via [updateRelease].
  Future<Release> publishRelease({
    required String packageReference,
    required Version version,
    String? title,
    String? notes,
    String? tag,
    bool draft = false,
    Map<String, String> metadata = const {},
  });

  /// The release with [id], or `null`.
  Future<Release?> release(String id);

  /// The release of [packageReference] at [version], or `null`.
  Future<Release?> releaseByVersion(String packageReference, Version version);

  /// Releases of [packageReference] matching [query], newest first.
  Future<List<Release>> listReleases(
    String packageReference, {
    ReleaseQuery query = const ReleaseQuery(),
  });

  /// Updates a release's mutable metadata: notes, title, draft state, and
  /// yanking.
  ///
  /// The version and its assets are not editable here; see [Release].
  Future<Release> updateRelease(
    String id, {
    String? title,
    String? notes,
    String? tag,
    bool? draft,
    bool? yanked,
    String? yankedReason,
    Map<String, String>? metadata,
  });

  /// Deletes the release with [id], its assets and their stored bytes.
  ///
  /// Prefer yanking (`updateRelease(id, yanked: true)`): deleting breaks every
  /// client that pinned the version, while yanking stops it being *offered*
  /// without breaking anyone.
  Future<void> deleteRelease(String id);

  /// The newest offerable stable release of [packageReference], or `null`.
  Future<Release?> latestRelease(String packageReference);

  /// The newest offerable beta release of [packageReference], or `null`.
  Future<Release?> latestBeta(String packageReference);

  /// The newest offerable dev release of [packageReference], or `null`.
  Future<Release?> latestDev(String packageReference);

  /// The newest release of [packageReference] a client on [channel] would
  /// accept, or `null`.
  ///
  /// Inclusive downward in stability: a `beta` subscriber is offered a newer
  /// *stable* release when one exists, which is what makes promotion work
  /// without re-publishing. Pass `exact: true` for the strict single-channel
  /// reading.
  Future<Release?> latestChannel(
    String packageReference,
    ReleaseChannel channel, {
    bool exact = false,
  });

  /// The newest offerable release of [packageReference] on any channel.
  Future<Release?> latestAny(String packageReference);

  /// Promotes [releaseId] to [channel] by publishing its artifacts under a new
  /// version carrying that channel's tag.
  ///
  /// Promotion cannot mutate the existing release — its version *is* its
  /// channel — so this creates `1.2.0` from `1.2.0-beta.3` and copies the
  /// asset records across, leaving the original in place. Returns the new
  /// release.
  Future<Release> promoteRelease(
    String releaseId,
    ReleaseChannel channel, {
    String? notes,
  });

  // -------------------------------------------------------------- assets ---

  /// Attaches an asset named [name] to [releaseId], streaming [data] into
  /// storage.
  ///
  /// The SHA-256 and size are computed as the bytes stream past; when
  /// [expectedSha256] is given they are verified against it and nothing is
  /// stored on mismatch. Passing [length] lets backends that need the size up
  /// front stream instead of buffering.
  ///
  /// [platform] (`linux-x64`) is what lets the update service answer "is there
  /// an update *for me*", so publishers should always set it on
  /// platform-specific artifacts.
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
  });

  /// The asset with [id], or `null`.
  Future<Asset?> asset(String id);

  /// The asset named [name] within [releaseId], or `null`.
  Future<Asset?> assetByName(String releaseId, String name);

  /// Assets of [releaseId], ordered by name.
  Future<List<Asset>> listAssets(String releaseId);

  /// Deletes the asset with [id] and its stored bytes on every provider.
  Future<void> deleteAsset(String id);

  /// Opens the bytes of the asset with [id], optionally restricted to [range].
  ///
  /// Always works, whatever the provider topology: a bucket read, a local file,
  /// or a relay across a node's control channel. Prefer [downloadTarget] when
  /// the caller can follow a redirect — that path costs the hub no bandwidth.
  Future<AssetDownload> openAsset(String id, {ByteRange? range});

  /// Where a client should fetch the asset with [id] from.
  ///
  /// Returns a [RedirectDownload] when the holding provider can issue a
  /// time-limited URL, and a [StreamedDownload] when it cannot.
  Future<DownloadTarget> downloadTarget(
    String id, {
    Duration expiresIn = const Duration(minutes: 15),
  });

  // ----------------------------------------------------------- downloads ---

  /// Records that the asset with [assetId] was downloaded, and increments its
  /// counter.
  Future<DownloadRecord> recordDownload({
    required String assetId,
    String? clientAddress,
    String? userAgent,
    String? principalId,
    String? providerId,
    int? bytesServed,
  });

  /// Download records for [packageReference], newest first.
  Future<List<DownloadRecord>> listDownloads(
    String packageReference, {
    int? limit,
    DateTime? from,
    DateTime? to,
  });

  /// Aggregated download statistics for [packageReference].
  Future<DownloadStats> downloadStats(
    String packageReference, {
    DateTime? from,
    DateTime? to,
  });

  // ------------------------------------------------------------- updates ---

  /// Answers "is there a newer version of [packageReference] than
  /// [currentVersion], on [channel], for [platform]?".
  ///
  /// [channel] defaults to the package's own `defaultChannel`, so a client that
  /// does not opt in to pre-releases is never offered one. A client already
  /// current — or ahead, as a developer running a local build is — gets
  /// `updateAvailable: false` rather than an error.
  Future<UpdateInfo> checkForUpdates({
    required String packageReference,
    required Version currentVersion,
    ReleaseChannel? channel,
    String? platform,
  });

  // ----------------------------------------------------------- providers ---

  /// The storage providers this store knows about.
  ///
  /// A single-process `OmnyStore` reports exactly one — itself. A hub reports
  /// its own provider plus every connected node, which is what makes the
  /// federation observable.
  Future<List<ProviderDescriptor>> listProviders({String? organization});

  /// Releases any resources held (HTTP clients, storage handles).
  Future<void> close();
}
