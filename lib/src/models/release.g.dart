// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'release.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Release _$ReleaseFromJson(Map<String, dynamic> json) => Release(
  id: json['id'] as String,
  packageId: json['packageId'] as String,
  organizationId: json['organizationId'] as String,
  version: const VersionConverter().fromJson(json['version'] as String),
  channel: $enumDecodeNullable(_$ReleaseChannelEnumMap, json['channel']),
  title: json['title'] as String?,
  notes: json['notes'] as String?,
  tag: json['tag'] as String?,
  draft: json['draft'] as bool? ?? false,
  yanked: json['yanked'] as bool? ?? false,
  yankedReason: json['yankedReason'] as String?,
  createdAt: DateTime.parse(json['createdAt'] as String),
  publishedAt: json['publishedAt'] == null
      ? null
      : DateTime.parse(json['publishedAt'] as String),
  metadata:
      (json['metadata'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, e as String),
      ) ??
      const {},
);

Map<String, dynamic> _$ReleaseToJson(Release instance) => <String, dynamic>{
  'id': instance.id,
  'packageId': instance.packageId,
  'organizationId': instance.organizationId,
  'version': const VersionConverter().toJson(instance.version),
  'channel': _$ReleaseChannelEnumMap[instance.channel]!,
  'title': instance.title,
  'notes': instance.notes,
  'tag': instance.tag,
  'draft': instance.draft,
  'yanked': instance.yanked,
  'yankedReason': instance.yankedReason,
  'createdAt': instance.createdAt.toIso8601String(),
  'publishedAt': instance.publishedAt?.toIso8601String(),
  'metadata': instance.metadata,
};

const _$ReleaseChannelEnumMap = {
  ReleaseChannel.dev: 'dev',
  ReleaseChannel.beta: 'beta',
  ReleaseChannel.release: 'release',
};
