// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_record.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DownloadRecord _$DownloadRecordFromJson(Map<String, dynamic> json) =>
    DownloadRecord(
      id: json['id'] as String,
      assetId: json['assetId'] as String,
      releaseId: json['releaseId'] as String,
      packageId: json['packageId'] as String,
      organizationId: json['organizationId'] as String,
      version: json['version'] as String,
      downloadedAt: DateTime.parse(json['downloadedAt'] as String),
      providerId: json['providerId'] as String?,
      clientAddress: json['clientAddress'] as String?,
      userAgent: json['userAgent'] as String?,
      principalId: json['principalId'] as String?,
      bytesServed: (json['bytesServed'] as num?)?.toInt(),
      metadata:
          (json['metadata'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as String),
          ) ??
          const {},
    );

Map<String, dynamic> _$DownloadRecordToJson(DownloadRecord instance) =>
    <String, dynamic>{
      'id': instance.id,
      'assetId': instance.assetId,
      'releaseId': instance.releaseId,
      'packageId': instance.packageId,
      'organizationId': instance.organizationId,
      'version': instance.version,
      'downloadedAt': instance.downloadedAt.toIso8601String(),
      'providerId': instance.providerId,
      'clientAddress': instance.clientAddress,
      'userAgent': instance.userAgent,
      'principalId': instance.principalId,
      'bytesServed': instance.bytesServed,
      'metadata': instance.metadata,
    };

DownloadStats _$DownloadStatsFromJson(Map<String, dynamic> json) =>
    DownloadStats(
      total: (json['total'] as num).toInt(),
      byVersion:
          (json['byVersion'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, (e as num).toInt()),
          ) ??
          const {},
      byAsset:
          (json['byAsset'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, (e as num).toInt()),
          ) ??
          const {},
      from: json['from'] == null
          ? null
          : DateTime.parse(json['from'] as String),
      to: json['to'] == null ? null : DateTime.parse(json['to'] as String),
    );

Map<String, dynamic> _$DownloadStatsToJson(DownloadStats instance) =>
    <String, dynamic>{
      'total': instance.total,
      'byVersion': instance.byVersion,
      'byAsset': instance.byAsset,
      'from': instance.from?.toIso8601String(),
      'to': instance.to?.toIso8601String(),
    };
