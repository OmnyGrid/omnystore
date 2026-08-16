import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import '../utils/equality.dart';

part 'asset.g.dart';

/// A downloadable file attached to a [Release] — a tarball, an installer, a
/// checksum file, a signature.
///
/// The record is metadata only: the bytes live in an `ObjectStorage` behind
/// whichever provider (the hub itself, or one of the organization's nodes)
/// holds them, addressed by [storageKey]. That separation is what lets one
/// release's assets be served from several nodes, and what lets the storage
/// backend change from a local directory to S3 without touching the registry.
///
/// [sha256] is not optional. An update system that hands a client bytes it
/// cannot verify is an update system that can be turned into a malware
/// delivery channel by anyone who can write to the object store, so the
/// checksum is computed on upload and checked on download.
@immutable
@JsonSerializable(explicitToJson: true)
class Asset {
  /// Stable, opaque identifier assigned at upload.
  final String id;

  /// The owning release's [Release.id].
  final String releaseId;

  /// The owning package's [Package.id], denormalised so a download can be
  /// recorded and routed without loading the release.
  final String packageId;

  /// The owning organization's [Organization.id], denormalised for routing.
  final String organizationId;

  /// The filename clients download it as (`omnyagent-linux-x64.tar.gz`).
  /// Unique within the release; validated by `Names.requireFilename`.
  final String name;

  /// The key the bytes are stored under in the object store.
  final String storageKey;

  /// MIME type (`application/gzip`), used for the download `content-type`.
  final String contentType;

  /// Size in bytes, verified against the uploaded stream.
  final int sizeBytes;

  /// Lower-case hex SHA-256 of the content, computed while uploading.
  final String sha256;

  /// The target platform (`linux-x64`, `macos-arm64`, `windows-x64`), or `null`
  /// for a platform-independent artifact.
  ///
  /// The update service uses this to answer "is there an update *for me*" —
  /// a client on `macos-arm64` should not be told to update to a release that
  /// only shipped a Linux binary.
  final String? platform;

  /// A free-form kind tag (`installer`, `archive`, `checksums`, `signature`)
  /// letting a client pick the right artifact among several for one platform.
  final String? kind;

  /// How many times this asset has been downloaded.
  final int downloadCount;

  /// When the asset was uploaded (UTC).
  final DateTime createdAt;

  /// Arbitrary application-defined key/value pairs.
  final Map<String, String> metadata;

  /// Creates an asset record. [metadata] is copied into an unmodifiable map.
  ///
  /// Prefer `OmnyStore.attachAsset`, which streams the bytes into the object
  /// store, computes [sha256] and [sizeBytes] as it goes, and assigns
  /// [storageKey].
  Asset({
    required this.id,
    required this.releaseId,
    required this.packageId,
    required this.organizationId,
    required this.name,
    required this.storageKey,
    this.contentType = 'application/octet-stream',
    required this.sizeBytes,
    required this.sha256,
    this.platform,
    this.kind,
    this.downloadCount = 0,
    required this.createdAt,
    Map<String, String> metadata = const {},
  }) : metadata = Map.unmodifiable(metadata);

  /// Returns a copy with the mutable fields replaced.
  ///
  /// [sha256], [sizeBytes] and [storageKey] are absent: changing them would
  /// mean the record no longer describes the stored bytes. Replacing an asset's
  /// content means deleting it and attaching a new one.
  Asset copyWith({
    String? contentType,
    String? platform,
    String? kind,
    int? downloadCount,
    Map<String, String>? metadata,
  }) => Asset(
    id: id,
    releaseId: releaseId,
    packageId: packageId,
    organizationId: organizationId,
    name: name,
    storageKey: storageKey,
    contentType: contentType ?? this.contentType,
    sizeBytes: sizeBytes,
    sha256: sha256,
    platform: platform ?? this.platform,
    kind: kind ?? this.kind,
    downloadCount: downloadCount ?? this.downloadCount,
    createdAt: createdAt,
    metadata: metadata ?? this.metadata,
  );

  /// Parses an asset from a JSON map.
  factory Asset.fromJson(Map<String, dynamic> json) => _$AssetFromJson(json);

  /// Serialises the asset to a JSON map.
  Map<String, dynamic> toJson() => _$AssetToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Asset &&
          other.id == id &&
          other.releaseId == releaseId &&
          other.packageId == packageId &&
          other.organizationId == organizationId &&
          other.name == name &&
          other.storageKey == storageKey &&
          other.contentType == contentType &&
          other.sizeBytes == sizeBytes &&
          other.sha256 == sha256 &&
          other.platform == platform &&
          other.kind == kind &&
          other.downloadCount == downloadCount &&
          other.createdAt == createdAt &&
          Eq.maps(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    id,
    releaseId,
    packageId,
    organizationId,
    name,
    storageKey,
    contentType,
    sizeBytes,
    sha256,
    platform,
    kind,
    downloadCount,
    createdAt,
    Eq.mapHash(metadata),
  );

  @override
  String toString() =>
      'Asset($name, $sizeBytes bytes, release: $releaseId'
      '${platform == null ? '' : ', $platform'})';
}
