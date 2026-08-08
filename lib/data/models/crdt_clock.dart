import 'package:equatable/equatable.dart';

class CrdtClock extends Equatable implements Comparable<CrdtClock> {
  final DateTime timestamp;
  final String deviceId;

  const CrdtClock({required this.timestamp, required this.deviceId});

  factory CrdtClock.fromJson(Map<String, dynamic> json) => CrdtClock(
    timestamp: DateTime.parse(json['timestamp'] as String).toUtc(),
    deviceId: json['device_id'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'device_id': deviceId,
  };

  @override
  int compareTo(CrdtClock other) {
    final byTime = timestamp.compareTo(other.timestamp);
    return byTime != 0 ? byTime : deviceId.compareTo(other.deviceId);
  }

  @override
  List<Object?> get props => [timestamp, deviceId];
}

Map<String, CrdtClock> parseCrdtClocks(Object? raw) {
  if (raw is! Map) return const {};
  final result = <String, CrdtClock>{};
  for (final entry in raw.entries) {
    if (entry.key is! String || entry.value is! Map) continue;
    try {
      result[entry.key as String] = CrdtClock.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
    } on Object {
      // Invalid clocks fall back to the entity's legacy updated_at stamp.
    }
  }
  return Map.unmodifiable(result);
}

Map<String, CrdtClock> stampCrdtFields(
  Map<String, CrdtClock> existing,
  Set<String> fields,
  DateTime timestamp,
  String deviceId,
) {
  final clocks = <String, CrdtClock>{...existing};
  for (final field in fields) {
    clocks[field] = CrdtClock(timestamp: timestamp.toUtc(), deviceId: deviceId);
  }
  return Map.unmodifiable(clocks);
}
