import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/native/oblix_core.dart';
import 'package:oblix/core/native/oblix_core_fallback.dart' as dart_oracle;
import 'package:oblix/data/models/crdt_clock.dart';
import 'package:oblix/data/models/note.dart';
import 'package:oblix/data/models/task.dart';

CrdtClockValue _clock(int micros, String deviceId) =>
    (timestampMicrosUtc: micros, deviceId: deviceId);

void main() {
  setUpAll(() async {
    await initializeOblixCore();
  });

  group('Rust CRDT core', () {
    test('native bridge initializes', () {
      expect(isRustCoreReady, isTrue);
    });

    test('matches the Dart oracle across clock edge cases', () {
      final localFallback = _clock(100, '');
      final remoteFallback = _clock(101, '');
      final localClocks = <String, CrdtClockValue>{
        'older_remote': _clock(20, 'z'),
        'exact_tie': _clock(30, 'same'),
        'device_remote': _clock(40, 'device-a'),
        'device_local': _clock(40, 'device-b'),
        // Dart compares UTF-16 code units. This pair has the opposite UTF-8
        // ordering and catches an accidental Rust `str::cmp` implementation.
        'unicode': _clock(50, '\u{10000}'),
        'protected': _clock(1, 'a'),
      };
      final remoteClocks = <String, CrdtClockValue>{
        'older_remote': _clock(19, 'zz'),
        'exact_tie': _clock(30, 'same'),
        'device_remote': _clock(40, 'device-b'),
        'device_local': _clock(40, 'device-a'),
        'unicode': _clock(50, '\ue000'),
        'protected': _clock(999, 'z'),
        // Unknown clocks must not leak into the returned known fields.
        'future_server_field': _clock(9999, 'server'),
      };
      const fields = [
        'fallback',
        'older_remote',
        'exact_tie',
        'device_remote',
        'device_local',
        'unicode',
        'protected',
      ];
      const excluded = {'protected'};

      final expected = dart_oracle.remoteWinningFields(
        fields: fields,
        localClocks: localClocks,
        localFallback: localFallback,
        remoteClocks: remoteClocks,
        remoteFallback: remoteFallback,
        excludedFields: excluded,
      );
      final actual = remoteWinningFields(
        fields: fields,
        localClocks: localClocks,
        localFallback: localFallback,
        remoteClocks: remoteClocks,
        remoteFallback: remoteFallback,
        excludedFields: excluded,
      );

      expect(actual, expected);
      expect(actual.toList(), ['fallback', 'device_remote', 'unicode']);
    });

    test('Note merge uses Rust winners but keeps Dart model semantics', () {
      final created = DateTime.utc(2026, 8, 9);
      final local = Note(
        id: 'note-1',
        userId: 'local-user',
        title: 'Local title',
        content: 'Local content',
        isPinned: true,
        createdAt: created,
        updatedAt: created.add(const Duration(seconds: 2)),
        versions: [
          NoteVersion(
            id: 'local-version',
            title: 'Local title',
            content: 'Local content',
            contentType: 'plain',
            versionNumber: 1,
            createdAt: created,
          ),
        ],
        fieldClocks: {
          'title': CrdtClock(timestamp: created, deviceId: 'phone'),
          'content': CrdtClock(
            timestamp: created.add(const Duration(seconds: 2)),
            deviceId: 'phone',
          ),
          'is_pinned': CrdtClock(
            timestamp: created.add(const Duration(seconds: 2)),
            deviceId: 'phone',
          ),
        },
      );
      final remote = Note(
        id: 'note-1',
        userId: 'server-user',
        title: 'Remote title',
        content: 'Remote content',
        createdAt: created.subtract(const Duration(days: 1)),
        updatedAt: created.add(const Duration(seconds: 3)),
        versions: [
          NoteVersion(
            id: 'server-version',
            title: 'Remote title',
            content: 'Remote content',
            contentType: 'plain',
            versionNumber: 2,
            createdAt: created.add(const Duration(seconds: 3)),
          ),
        ],
        fieldClocks: {
          'title': CrdtClock(
            timestamp: created.add(const Duration(seconds: 3)),
            deviceId: 'laptop',
          ),
          'content': CrdtClock(
            timestamp: created.add(const Duration(seconds: 3)),
            deviceId: 'laptop',
          ),
          'is_pinned': CrdtClock(timestamp: created, deviceId: 'laptop'),
        },
      );

      final merged = local.mergeCrdt(remote, excludedFields: {'content'});

      expect(merged.title, 'Remote title');
      expect(merged.content, 'Local content');
      expect(merged.isPinned, isTrue);
      expect(merged.userId, 'server-user');
      expect(merged.createdAt, remote.createdAt);
      expect(merged.updatedAt, remote.updatedAt);
      expect(merged.versions.single.id, 'server-version');
      expect(merged.fieldClocks['content'], local.fieldClocks['content']);
    });

    test('Task completion timestamp follows the completion register', () {
      final created = DateTime.utc(2026, 8, 9);
      final local = Task(
        id: 'task-1',
        userId: 'user',
        title: 'Keep title',
        isCompleted: true,
        completedAt: created.add(const Duration(seconds: 2)),
        createdAt: created,
        updatedAt: created.add(const Duration(seconds: 2)),
        fieldClocks: {
          'title': TaskCrdtClock(timestamp: created, deviceId: 'phone'),
          'is_completed': TaskCrdtClock(
            timestamp: created.add(const Duration(seconds: 2)),
            deviceId: 'phone',
          ),
        },
      );
      final remote = Task(
        id: 'task-1',
        userId: 'user',
        title: 'Remote title',
        createdAt: created,
        updatedAt: created.add(const Duration(seconds: 3)),
        fieldClocks: {
          'title': TaskCrdtClock(
            timestamp: created.add(const Duration(seconds: 3)),
            deviceId: 'laptop',
          ),
          'is_completed': TaskCrdtClock(timestamp: created, deviceId: 'laptop'),
        },
      );

      final merged = local.mergeCrdt(remote);

      expect(merged.title, 'Remote title');
      expect(merged.isCompleted, isTrue);
      expect(merged.completedAt, local.completedAt);
    });
  });
}
