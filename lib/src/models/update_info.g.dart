// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'update_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UpdateInfo _$UpdateInfoFromJson(Map<String, dynamic> json) => UpdateInfo(
  currentVersion: const VersionConverter().fromJson(
    json['currentVersion'] as String,
  ),
  latestVersion: const NullableVersionConverter().fromJson(
    json['latestVersion'] as String?,
  ),
  updateAvailable: json['updateAvailable'] as bool,
  channel: $enumDecode(_$ReleaseChannelEnumMap, json['channel']),
  release: json['release'] == null
      ? null
      : Release.fromJson(json['release'] as Map<String, dynamic>),
  asset: json['asset'] == null
      ? null
      : Asset.fromJson(json['asset'] as Map<String, dynamic>),
  packageName: json['packageName'] as String,
  notes: json['notes'] as String?,
);

Map<String, dynamic> _$UpdateInfoToJson(
  UpdateInfo instance,
) => <String, dynamic>{
  'currentVersion': const VersionConverter().toJson(instance.currentVersion),
  'latestVersion': const NullableVersionConverter().toJson(
    instance.latestVersion,
  ),
  'updateAvailable': instance.updateAvailable,
  'channel': _$ReleaseChannelEnumMap[instance.channel]!,
  'release': instance.release?.toJson(),
  'asset': instance.asset?.toJson(),
  'packageName': instance.packageName,
  'notes': instance.notes,
};

const _$ReleaseChannelEnumMap = {
  ReleaseChannel.dev: 'dev',
  ReleaseChannel.beta: 'beta',
  ReleaseChannel.release: 'release',
};
