class SyncChangeItem {
  final String entityType; // note, notebook, tag, file
  final String entityId;
  final String action; // create, update, delete
  final Map<String, dynamic> data;
  final String? deviceId;
  final String timestamp; // ISO 8601

  const SyncChangeItem({
    required this.entityType,
    required this.entityId,
    required this.action,
    required this.data,
    this.deviceId,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'entity_type': entityType,
    'entity_id': entityId,
    'action': action,
    'data': data,
    'device_id': deviceId,
    'timestamp': timestamp,
  };

  factory SyncChangeItem.fromJson(Map<String, dynamic> json) {
    return SyncChangeItem(
      entityType: json['entity_type'] as String,
      entityId: json['entity_id'] as String,
      action: json['action'] as String,
      data: json['data'] as Map<String, dynamic>? ?? {},
      deviceId: json['device_id'] as String?,
      timestamp: json['timestamp'] as String,
    );
  }
}

class SyncPushResponse {
  final List<String> applied;
  final List<SyncConflict> conflicts;
  final List<Map<String, dynamic>> serverChanges;
  final String serverTime; // cursor to adopt for the next sync

  const SyncPushResponse({
    required this.applied,
    required this.conflicts,
    required this.serverChanges,
    required this.serverTime,
  });

  factory SyncPushResponse.fromJson(Map<String, dynamic> json) {
    return SyncPushResponse(
      applied: List<String>.from(json['applied'] as List? ?? []),
      conflicts:
          (json['conflicts'] as List<dynamic>?)
              ?.map((c) => SyncConflict.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
      serverChanges: List<Map<String, dynamic>>.from(
        json['server_changes'] as List? ?? [],
      ),
      serverTime: json['server_time'] as String? ?? '',
    );
  }
}

class SyncConflict {
  final String entityType;
  final String entityId;
  final Map<String, dynamic> serverData;
  final Map<String, dynamic> clientData;
  final String reason;

  const SyncConflict({
    required this.entityType,
    required this.entityId,
    required this.serverData,
    required this.clientData,
    required this.reason,
  });

  factory SyncConflict.fromJson(Map<String, dynamic> json) {
    return SyncConflict(
      entityType: json['entity_type'] as String,
      entityId: json['entity_id'] as String,
      serverData: json['server_data'] as Map<String, dynamic>? ?? {},
      clientData: json['client_data'] as Map<String, dynamic>? ?? {},
      reason: json['reason'] as String? ?? 'Conflict',
    );
  }
}

class SyncPullResponse {
  final List<Map<String, dynamic>> changes;
  final String serverTime;

  const SyncPullResponse({required this.changes, required this.serverTime});

  factory SyncPullResponse.fromJson(Map<String, dynamic> json) {
    return SyncPullResponse(
      changes: List<Map<String, dynamic>>.from(json['changes'] as List? ?? []),
      serverTime: json['server_time'] as String,
    );
  }
}
