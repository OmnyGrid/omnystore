// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'asset.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Asset _$AssetFromJson(Map<String, dynamic> json) => Asset(
  id: json['id'] as String,
  releaseId: json['releaseId'] as String,
  packageId: json['packageId'] as String,
  organizationId: json['organizationId'] as String,
  name: json['name'] as String,
  storageKey: json['storageKey'] as String,
  contentType: json['contentType'] as String? ?? 'application/octet-stream',
  sizeBytes: (json['sizeBytes'] as num).toInt(),
  sha256: json['sha256'] as String,
  platform: json['platform'] as String?,
  kind: json['kind'] as String?,
  downloadCount: (json['downloadCount'] as num?)?.toInt() ?? 0,
  createdAt: DateTime.parse(json['createdAt'] as String),
  metadata:
      (json['metadata'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, e as String),
      ) ??
      const {},
);

Map<String, dynamic> _$AssetToJson(Asset instance) => <String, dynamic>{
  'id': instance.id,
  'releaseId': instance.releaseId,
  'packageId': instance.packageId,
  'organizationId': instance.organizationId,
  'name': instance.name,
  'storageKey': instance.storageKey,
  'contentType': instance.contentType,
  'sizeBytes': instance.sizeBytes,
  'sha256': instance.sha256,
  'platform': instance.platform,
  'kind': instance.kind,
  'downloadCount': instance.downloadCount,
  'createdAt': instance.createdAt.toIso8601String(),
  'metadata': instance.metadata,
};
