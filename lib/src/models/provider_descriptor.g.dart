// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'provider_descriptor.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ProviderDescriptor _$ProviderDescriptorFromJson(Map<String, dynamic> json) =>
    ProviderDescriptor(
      id: json['id'] as String,
      kind:
          $enumDecodeNullable(_$ProviderKindEnumMap, json['kind']) ??
          ProviderKind.node,
      organizations:
          (json['organizations'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toSet() ??
          const {},
      servesAll: json['servesAll'] as bool? ?? false,
      dataPlane:
          $enumDecodeNullable(_$DataPlaneModeEnumMap, json['dataPlane']) ??
          DataPlaneMode.relay,
      baseUrl: json['baseUrl'] as String?,
      labels:
          (json['labels'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as String),
          ) ??
          const {},
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      capacityBytes: (json['capacityBytes'] as num?)?.toInt(),
      usedBytes: (json['usedBytes'] as num?)?.toInt(),
      agentVersion: json['agentVersion'] as String? ?? 'unknown',
      status:
          $enumDecodeNullable(_$ProviderStatusEnumMap, json['status']) ??
          ProviderStatus.online,
      lastSeenAt: json['lastSeenAt'] == null
          ? null
          : DateTime.parse(json['lastSeenAt'] as String),
      metadata:
          (json['metadata'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as String),
          ) ??
          const {},
    );

Map<String, dynamic> _$ProviderDescriptorToJson(ProviderDescriptor instance) =>
    <String, dynamic>{
      'id': instance.id,
      'kind': _$ProviderKindEnumMap[instance.kind]!,
      'organizations': instance.organizations.toList(),
      'servesAll': instance.servesAll,
      'dataPlane': _$DataPlaneModeEnumMap[instance.dataPlane]!,
      'baseUrl': instance.baseUrl,
      'labels': instance.labels,
      'priority': instance.priority,
      'capacityBytes': instance.capacityBytes,
      'usedBytes': instance.usedBytes,
      'agentVersion': instance.agentVersion,
      'status': _$ProviderStatusEnumMap[instance.status]!,
      'lastSeenAt': instance.lastSeenAt?.toIso8601String(),
      'metadata': instance.metadata,
    };

const _$ProviderKindEnumMap = {
  ProviderKind.hub: 'hub',
  ProviderKind.node: 'node',
};

const _$DataPlaneModeEnumMap = {
  DataPlaneMode.presigned: 'presigned',
  DataPlaneMode.direct: 'direct',
  DataPlaneMode.relay: 'relay',
};

const _$ProviderStatusEnumMap = {
  ProviderStatus.online: 'online',
  ProviderStatus.offline: 'offline',
  ProviderStatus.draining: 'draining',
};
