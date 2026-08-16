// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Package _$PackageFromJson(Map<String, dynamic> json) => Package(
  id: json['id'] as String,
  projectId: json['projectId'] as String,
  organizationId: json['organizationId'] as String,
  name: json['name'] as String,
  displayName: json['displayName'] as String?,
  description: json['description'] as String?,
  defaultChannel:
      $enumDecodeNullable(_$ReleaseChannelEnumMap, json['defaultChannel']) ??
      ReleaseChannel.release,
  platforms:
      (json['platforms'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  metadata:
      (json['metadata'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, e as String),
      ) ??
      const {},
);

Map<String, dynamic> _$PackageToJson(Package instance) => <String, dynamic>{
  'id': instance.id,
  'projectId': instance.projectId,
  'organizationId': instance.organizationId,
  'name': instance.name,
  'displayName': instance.displayName,
  'description': instance.description,
  'defaultChannel': _$ReleaseChannelEnumMap[instance.defaultChannel]!,
  'platforms': instance.platforms,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
  'metadata': instance.metadata,
};

const _$ReleaseChannelEnumMap = {
  ReleaseChannel.dev: 'dev',
  ReleaseChannel.beta: 'beta',
  ReleaseChannel.release: 'release',
};
