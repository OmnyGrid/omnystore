import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../utils/equality.dart';

part 'download_record.g.dart';

/// One recorded download of an [Asset].
///
/// Records are append-only and denormalised across the whole ownership chain
/// (asset → release → package → organization), so download analytics can be
/// aggregated at any level without joining back to records that may live on a
/// different node.
///
/// [clientAddress] is captured for rate-limiting and abuse investigation. It is
/// personal data in most jurisdictions: `DownloadService` can be configured to
/// omit or hash it, and it is never returned by the public API.
@immutable
@JsonSerializable(explicitToJson: true)
class DownloadRecord {
  /// Stable, opaque identifier assigned when the download is recorded.
  final String id;

  /// The downloaded asset's [Asset.id].
  final String assetId;

  /// The asset's release [Release.id].
  final String releaseId;

  /// The asset's package [Package.id].
  final String packageId;

  /// The asset's organization [Organization.id].
  final String organizationId;

  /// The version string downloaded, denormalised so per-version download counts
  /// survive the release record being deleted.
  final String version;

  /// When the download was served (UTC).
  final DateTime downloadedAt;

  /// The id of the provider (hub or node) that served the bytes.
  final String? providerId;

  /// The client's network address, or `null` if not captured.
  final String? clientAddress;

  /// The client's `user-agent` header, or `null` if absent.
  final String? userAgent;

  /// The authenticated principal's id, or `null` for an anonymous download.
  final String? principalId;

  /// How many bytes were served — less than the asset size for a ranged or
  /// resumed request.
  final int? bytesServed;

  /// Arbitrary application-defined key/value pairs.
  final Map<String, String> metadata;

  /// Creates a download record. [metadata] is copied into an unmodifiable map.
  ///
  /// Prefer `OmnyStore.recordDownload`, which fills the ownership chain from
  /// the asset and stamps [downloadedAt] from the injected clock.
  DownloadRecord({
    required this.id,
    required this.assetId,
    required this.releaseId,
    required this.packageId,
    required this.organizationId,
    required this.version,
    required this.downloadedAt,
    this.providerId,
    this.clientAddress,
    this.userAgent,
    this.principalId,
    this.bytesServed,
    Map<String, String> metadata = const {},
  }) : metadata = Map.unmodifiable(metadata);

  /// Parses a download record from a JSON map.
  factory DownloadRecord.fromJson(Map<String, dynamic> json) =>
      _$DownloadRecordFromJson(json);

  /// Serialises the download record to a JSON map.
  Map<String, dynamic> toJson() => _$DownloadRecordToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadRecord &&
          other.id == id &&
          other.assetId == assetId &&
          other.releaseId == releaseId &&
          other.packageId == packageId &&
          other.organizationId == organizationId &&
          other.version == version &&
          other.downloadedAt == downloadedAt &&
          other.providerId == providerId &&
          other.clientAddress == clientAddress &&
          other.userAgent == userAgent &&
          other.principalId == principalId &&
          other.bytesServed == bytesServed &&
          Eq.maps(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    id,
    assetId,
    releaseId,
    packageId,
    organizationId,
    version,
    downloadedAt,
    providerId,
    clientAddress,
    userAgent,
    principalId,
    bytesServed,
    Eq.mapHash(metadata),
  );

  @override
  String toString() =>
      'DownloadRecord($assetId @ ${downloadedAt.toIso8601String()})';
}

/// Aggregated download counts, as returned by the downloads API.
///
/// Computed by `OmnyStore.downloadStats` over [DownloadRecord]s. The breakdowns
/// are what a release dashboard renders: adoption per version tells you whether
/// a rollout is progressing, per platform tells you which builds matter.
@immutable
@JsonSerializable(explicitToJson: true)
class DownloadStats {
  /// Total downloads counted.
  final int total;

  /// Downloads per version string, newest-first ordering left to the caller.
  final Map<String, int> byVersion;

  /// Downloads per asset id.
  final Map<String, int> byAsset;

  /// The window these statistics cover (UTC), or `null` for all time.
  final DateTime? from;

  /// The end of the window (UTC), or `null` for "up to now".
  final DateTime? to;

  /// Creates aggregated statistics. Maps are copied into unmodifiable views.
  DownloadStats({
    required this.total,
    Map<String, int> byVersion = const {},
    Map<String, int> byAsset = const {},
    this.from,
    this.to,
  }) : byVersion = Map.unmodifiable(byVersion),
       byAsset = Map.unmodifiable(byAsset);

  /// Parses statistics from a JSON map.
  factory DownloadStats.fromJson(Map<String, dynamic> json) =>
      _$DownloadStatsFromJson(json);

  /// Serialises the statistics to a JSON map.
  Map<String, dynamic> toJson() => _$DownloadStatsToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadStats &&
          other.total == total &&
          Eq.maps(other.byVersion, byVersion) &&
          Eq.maps(other.byAsset, byAsset) &&
          other.from == from &&
          other.to == to;

  @override
  int get hashCode =>
      Object.hash(total, Eq.mapHash(byVersion), Eq.mapHash(byAsset), from, to);

  @override
  String toString() => 'DownloadStats($total downloads)';
}
