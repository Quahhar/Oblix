import 'dart:async';
import '../../core/config/api_config.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../data/datasources/local/note_local_datasource.dart';
import '../../data/datasources/local/notebook_local_datasource.dart';
import '../../data/datasources/local/tag_local_datasource.dart';
import '../../data/datasources/local/outbox_dao.dart';
import '../../data/datasources/remote/sync_remote_datasource.dart';
import '../../data/models/sync_payload.dart';
import '../../data/repositories/sync_repository.dart';

/// Drives one sync cycle end-to-end:
///  1. drain a batch from the outbox,
///  2. push it (also returns everything changed on the server since our cursor),
///  3. in a single local transaction: LWW-merge server notes, ack the pushed
///     batch, and advance the cursor.
///
/// Steps 2 and 3 are ordered so the cursor only advances after server changes
/// are durably committed — a crash mid-sync safely re-runs the same cycle.
class SyncEngine {
  final AppDatabase _appDb;
  final SyncRemoteDataSource _remote;
  final OutboxDao _outbox;
  final NoteLocalDataSource _notes;
  final NotebookLocalDataSource _notebooks;
  final TagLocalDataSource _tags;
  final MetaDao _meta;

  bool _running = false;
  bool _pending = false;

  SyncEngine({
    AppDatabase? appDb,
    SyncRemoteDataSource? remote,
    OutboxDao? outbox,
    NoteLocalDataSource? notes,
    NotebookLocalDataSource? notebooks,
    TagLocalDataSource? tags,
    MetaDao? meta,
  })  : _appDb = appDb ?? AppDatabase.instance,
        _remote = remote ?? SyncRemoteDataSource(),
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _notes = notes ?? NoteLocalDataSource(appDb ?? AppDatabase.instance),
        _notebooks = notebooks ??
            NotebookLocalDataSource(appDb ?? AppDatabase.instance),
        _tags = tags ?? TagLocalDataSource(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance);

  /// Run a sync cycle. Concurrency-safe: if one is already running, the request
  /// is coalesced into a single follow-up run instead of overlapping.
  Future<SyncResult> syncOnce() async {
    if (_running) {
      _pending = true;
      return const SyncResult.skipped();
    }
    _running = true;
    try {
      return await _run();
    } finally {
      _running = false;
      if (_pending) {
        _pending = false;
        unawaited(syncOnce());
      }
    }
  }

  Future<SyncResult> _run() async {
    final cursor = await _meta.getCursor();
    final batch = await _outbox.fetchBatch(limit: ApiConfig.maxSyncBatchSize);
    final changes = batch.map((e) => e.change).toList();

    final SyncPushResponse resp;
    try {
      resp = await _remote.pushChanges(changes: changes, lastSyncAt: cursor);
    } catch (e) {
      // Transport failure: leave the outbox and cursor untouched to retry later.
      return SyncResult.failure(e.toString());
    }

    final serverNotes = SyncRepository.parseNoteChanges(resp.serverChanges);
    final serverNotebooks =
        SyncRepository.parseNotebookChanges(resp.serverChanges);
    final serverTags = SyncRepository.parseTagChanges(resp.serverChanges);
    final pulled =
        serverNotes.length + serverNotebooks.length + serverTags.length;

    final db = await _appDb.database;
    await db.transaction((txn) async {
      await _notes.applyServerNotes(txn, serverNotes);
      await _notebooks.applyServerNotebooks(txn, serverNotebooks);
      await _tags.applyServerTags(txn, serverTags);
      if (batch.isNotEmpty) {
        await _outbox.deleteThrough(txn, batch.last.seq);
      }
      if (resp.serverTime.isNotEmpty) {
        await _meta.setCursor(txn, resp.serverTime);
      }
    });

    if (pulled > 0) _appDb.notifyChanged();

    return SyncResult(
      pushed: batch.length,
      pulled: pulled,
      conflicts: resp.conflicts,
      success: true,
    );
  }
}

/// Outcome of a sync cycle. [success] means the round-trip completed;
/// [conflicts] can be non-empty even on success (LWW already resolved them in
/// favour of the server, which is reflected in the pulled notes).
class SyncResult {
  final int pushed;
  final int pulled;
  final List<SyncConflict> conflicts;
  final bool success;
  final String? error;
  final bool skipped;

  const SyncResult({
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    required this.success,
    this.error,
  }) : skipped = false;

  const SyncResult.failure(String message)
      : pushed = 0,
        pulled = 0,
        conflicts = const [],
        success = false,
        error = message,
        skipped = false;

  const SyncResult.skipped()
      : pushed = 0,
        pulled = 0,
        conflicts = const [],
        success = true,
        error = null,
        skipped = true;

  bool get hasConflicts => conflicts.isNotEmpty;
}
