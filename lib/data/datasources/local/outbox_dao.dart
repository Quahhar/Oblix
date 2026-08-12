import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../../core/native/oblix_core.dart';
import '../../models/sync_payload.dart';

/// A queued local mutation plus its stable sequence number (the ack cursor)
/// and how many pushes the server has not acknowledged it for.
class OutboxEntry {
  final int seq;
  final int attempts;
  final SyncChangeItem change;
  const OutboxEntry(this.seq, this.change, {this.attempts = 0});
}

class PendingOutboxData {
  final Set<String> fields;
  final Map<String, Set<int>> updateSeqsByField;

  const PendingOutboxData(this.fields, this.updateSeqsByField);

  Set<int> updateSeqsFor(String field) =>
      Set<int>.of(updateSeqsByField[field] ?? const <int>{});
}

/// Durable queue of local changes waiting to be pushed. FIFO by `seq`.
class OutboxDao {
  final AppDatabase _appDb;
  OutboxDao(this._appDb);

  /// Enqueue a change. Accepts a [DatabaseExecutor] so the enqueue commits in
  /// the SAME transaction as the local write it mirrors — a row and its outbox
  /// entry are never out of step.
  Future<void> enqueue(DatabaseExecutor db, SyncChangeItem change) async {
    await db.insert('outbox', {
      'entity_type': change.entityType,
      'entity_id': change.entityId,
      'action': change.action,
      'data': jsonEncode(change.data),
      'timestamp': change.timestamp,
      'device_id': change.deviceId,
    });
  }

  /// Oldest [limit] pending changes, in FIFO order.
  Future<List<OutboxEntry>> fetchBatch({
    int limit = 100,
    Set<String> excludedNoteIds = const <String>{},
  }) async {
    final db = await _appDb.database;
    final excluded = excludedNoteIds.toList(growable: false);
    final marks = List.filled(excluded.length, '?').join(',');
    final rows = await db.query(
      'outbox',
      where: excluded.isEmpty
          ? null
          : '(entity_type != ? OR entity_id NOT IN ($marks))',
      whereArgs: excluded.isEmpty ? null : ['note', ...excluded],
      orderBy: 'seq ASC',
      limit: limit,
    );
    return rows.map((r) {
      return OutboxEntry(
        r['seq'] as int,
        SyncChangeItem(
          entityType: r['entity_type'] as String,
          entityId: r['entity_id'] as String,
          action: r['action'] as String,
          data: (jsonDecode(r['data'] as String) as Map)
              .cast<String, dynamic>(),
          deviceId: r['device_id'] as String?,
          timestamp: r['timestamp'] as String,
        ),
        attempts: r['attempts'] as int? ?? 0,
      );
    }).toList();
  }

  /// Settle a pushed batch. [ackedSeqs] were acknowledged by the server
  /// (applied or conflict-resolved) and are removed. [retrySeqs] were never
  /// mentioned in the response: their attempt count is bumped and, once it
  /// reaches [maxAttempts], they are dropped as poison entries rather than
  /// blocking the queue forever. Returns how many entries were dropped.
  /// Runs inside the sync transaction.
  Future<int> settleBatch(
    DatabaseExecutor db, {
    required List<int> ackedSeqs,
    required List<int> retrySeqs,
    required int maxAttempts,
  }) async {
    if (ackedSeqs.isNotEmpty) {
      await db.delete(
        'outbox',
        where: 'seq IN (${List.filled(ackedSeqs.length, '?').join(',')})',
        whereArgs: ackedSeqs,
      );
    }
    var dropped = 0;
    if (retrySeqs.isNotEmpty) {
      final marks = List.filled(retrySeqs.length, '?').join(',');
      await db.rawUpdate(
        'UPDATE outbox SET attempts = attempts + 1 WHERE seq IN ($marks)',
        retrySeqs,
      );
      dropped = await db.delete(
        'outbox',
        where: 'seq IN ($marks) AND attempts >= ?',
        whereArgs: [...retrySeqs, maxAttempts],
      );
    }
    return dropped;
  }

  Future<int> pendingCount() async {
    final db = await _appDb.database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Whether an entity still has to be created on the server.
  ///
  /// A note cannot open its collaboration socket while this row exists: live
  /// protection would exclude the create from sync, and the server would
  /// correctly reject the socket because the note does not exist there yet.
  Future<bool> hasPendingCreate(String entityType, String entityId) async {
    final db = await _appDb.database;
    final rows = await db.query(
      'outbox',
      columns: const ['seq'],
      where: 'entity_type = ? AND entity_id = ? AND action = ?',
      whereArgs: [entityType, entityId, 'create'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The union of payload fields waiting to sync for one entity.
  ///
  /// Collaboration uses this to preserve only locally changed document fields
  /// when its first server snapshot arrives. A pin/tag/move entry must not make
  /// a stale cached title or body win over newer server content.
  ///
  /// A malformed row is treated conservatively as containing every field. It
  /// should not normally be possible (all writes use [enqueue]), but preserving
  /// local text is safer than silently discarding it if the database is corrupt.
  Future<Set<String>> pendingDataFieldsForEntity(
    String entityType,
    String entityId,
  ) async {
    return (await pendingDataForEntity(entityType, entityId)).fields;
  }

  /// Pending fields plus the exact update rows that supplied each field.
  ///
  /// Sequence scoping matters for collaboration: an acknowledgement may retire
  /// the document values that existed when the live session started, but must
  /// not remove a newer offline fallback queued after that session began.
  Future<PendingOutboxData> pendingDataForEntity(
    String entityType,
    String entityId,
  ) async {
    final db = await _appDb.database;
    final rows = await db.query(
      'outbox',
      columns: const ['seq', 'action', 'data'],
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [entityType, entityId],
      orderBy: 'seq ASC',
    );
    final summary = summarizePendingOutbox([
      for (final row in rows)
        (
          seq: row['seq'] as int,
          action: row['action'] as String,
          dataJson: row['data'] as String,
        ),
    ]);
    return PendingOutboxData(summary.fields, summary.updateSeqsByField);
  }

  /// Remove one server-acknowledged document field from pre-session update
  /// rows, retaining every other payload key and every create/delete row.
  /// Runs in the same transaction as the canonical collaboration cache write.
  Future<void> retireAcknowledgedUpdateField(
    DatabaseExecutor db, {
    required String entityType,
    required String entityId,
    required String field,
    required Set<int> scopedSeqs,
  }) async {
    if (scopedSeqs.isEmpty) return;
    // SQLite builds commonly cap a statement at 999 bound variables. Keep
    // enough headroom for the entity predicates even after a long offline run.
    final seqs = scopedSeqs.toList(growable: false);
    const chunkSize = 400;
    for (var offset = 0; offset < seqs.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, seqs.length);
      final chunk = seqs.sublist(offset, end);
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'outbox',
        columns: const ['seq', 'action', 'data'],
        where: 'entity_type = ? AND entity_id = ? AND seq IN ($marks)',
        whereArgs: [entityType, entityId, ...chunk],
      );
      for (final row in rows) {
        if (row['action'] != 'update') continue;
        final retirement = retireAcknowledgedOutboxField(
          dataJson: row['data'] as String,
          field: field,
        );
        if (!retirement.changed) continue;
        final seq = row['seq'] as int;
        if (retirement.deleteRow) {
          await db.delete('outbox', where: 'seq = ?', whereArgs: [seq]);
        } else {
          await db.update(
            'outbox',
            {'data': retirement.dataJson},
            where: 'seq = ?',
            whereArgs: [seq],
          );
        }
      }
    }
  }
}
