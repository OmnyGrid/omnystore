// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'asset_location.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AssetLocation _$AssetLocationFromJson(Map<String, dynamic> json) =>
    AssetLocation(
      id: json['id'] as String,
      assetId: json['assetId'] as String,
      providerId: json['providerId'] as String,
      organizationId: json['organizationId'] as String,
      storageKey: json['storageKey'] as String,
      state:
          $enumDecodeNullable(_$ReplicaStateEnumMap, json['state']) ??
          ReplicaState.pending,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      verifiedAt: json['verifiedAt'] == null
          ? null
          : DateTime.parse(json['verifiedAt'] as String),
      error: json['error'] as String?,
    );

Map<String, dynamic> _$AssetLocationToJson(AssetLocation instance) =>
    <String, dynamic>{
      'id': instance.id,
      'assetId': instance.assetId,
      'providerId': instance.providerId,
      'organizationId': instance.organizationId,
      'storageKey': instance.storageKey,
      'state': _$ReplicaStateEnumMap[instance.state]!,
      'sizeBytes': instance.sizeBytes,
      'createdAt': instance.createdAt.toIso8601String(),
      'verifiedAt': instance.verifiedAt?.toIso8601String(),
      'error': instance.error,
    };

const _$ReplicaStateEnumMap = {
  ReplicaState.pending: 'pending',
  ReplicaState.available: 'available',
  ReplicaState.failed: 'failed',
};
