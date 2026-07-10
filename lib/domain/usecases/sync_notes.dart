import '../../core/config/api_config.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/network/api_exceptions.dart';
import '../../data/datasources/local/note_local_datasource.dart';
import '../../data/datasources/local/notebook_local_datasource.dart';
import '../../data/datasources/local/outbox_dao.dart';
import '../../data/datasources/local/tag_local_datasource.dart';
import '../../data/datasources/remote/sync_remote_datasource.dart';
import '../../data/models/sync_payload.dart';
import '../../data/repositories/sync_repository.dart';

/// Drives a sync cycle end-to-end. Per round:
///  1. drain a batch from the outbox,
///  2. push it (also returns everything changed on the server since our cursor),
///  3. in a single local transaction: LWW-merge server entities, settle the
///     pushed batch against the server's acks, and advance the cursor.
/// Rounds repeat until the outbox is drained (large backlogs don't wait for
/// the next timer tick), then synced tombstones past retention are purged.
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
  final int _batchSize;
  final int _maxPushAttempts;

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
    int batchSize = ApiConfig.maxSyncBatchSize,
    int maxPushAttempts = ApiConfig.maxPushAttempts,
  })  : _appDb = appDb ?? AppDatabase.instance,
        _remote = remote ?? SyncRemoteDataSource(),
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _notes = notes ?? NoteLocalDataSource(appDb ?? AppDatabase.instance),
        _notebooks = notebooks ??
            NotebookLocalDataSource(appDb ?? AppDatabase.instance),
        _tags = tags ?? TagLocalDataSource(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
        _batchSize = batchSize,
        _maxPushAttempts = maxPushAttempts;

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
        // ignore: unawaited_futures
        syncOnce();
      }
    }
  }

  /// Safety valve so retried-but-unacked entries at the head of the queue
  /// can't spin the drain loop against the server within one cycle.
  static const _maxRoundsPerCycle = 20;

  Future<SyncResult> _run() async {
    var pushed = 0;
    var pulled = 0;
    var rejected = 0;
    final conflicts = <SyncConflict>[];
    var anythingChanged = false;

    for (var round = 0; round < _maxRoundsPerCycle; round++) {
      final cursor = await _meta.getCursor();
      final batch = await _outbox.fetchBatch(limit: _batchSize);
      final changes = batch.map((e) => e.change).toList();

      final requestedAt = DateTime.now().toUtc();
      final SyncPushResponse resp;
      try {
        resp = await _remote.pushChanges(changes: changes, lastSyncAt: cursor);
      } on UnauthorizedException catch (e) {
        // Session is dead; the scheduler reacts by stopping and signing out.
        return SyncResult.failure(e.toString(), unauthorized: true);
      } catch (e) {
        // Transport failure: leave the outbox and cursor untouched to retry
        // later. Server merges already committed in earlier rounds are kept.
        return SyncResult.failure(e.toString());
      }

      // Observed skew between server and device clocks; local mutation
      // timestamps are corrected by this (see SyncClock).
      final serverTime = DateTime.tryParse(resp.serverTime);
      final skew = serverTime?.toUtc().difference(requestedAt);

      final serverNotes = SyncRepository.parseNoteChanges(resp.serverChanges);
      final serverNotebooks =
          SyncRepository.parseNotebookChanges(resp.serverChanges);
      final serverTags = SyncRepository.parseTagChanges(resp.serverChanges);

      // Entities the server explicitly decided on — applied or conflict-
      // resolved (LWW favoured the server; its copy arrives in
      // server_changes). Batch entries it never mentioned were not processed
      // and stay queued for a bounded number of retries. A server that
      // doesn't fill `applied` at all acks the whole batch (legacy behavior).
      final decided = <String>{
        ...resp.applied,
        ...resp.conflicts.map((c) => c.entityId),
      };
      final ackAll = batch.isNotEmpty && decided.isEmpty;
      final ackedSeqs = <int>[];
      final retrySeqs = <int>[];
      for (final entry in batch) {
        if (ackAll || decided.contains(entry.change.entityId)) {
          ackedSeqs.add(entry.seq);
        } else {
          retrySeqs.add(entry.seq);
        }
      }

      var droppedThisRound = 0;
      final db = await _appDb.database;
      await db.transaction((txn) async {
        await _notes.applyServerNotes(txn, serverNotes);
        await _notebooks.applyServerNotebooks(txn, serverNotebooks);
        await _tags.applyServerTags(txn, serverTags);
        droppedThisRound = await _outbox.settleBatch(
          txn,
          ackedSeqs: ackedSeqs,
          retrySeqs: retrySeqs,
          maxAttempts: _maxPushAttempts,
        );
        if (resp.serverTime.isNotEmpty) {
          await _meta.setCursor(txn, resp.serverTime);
        }
        if (skew != null) {
          await _meta.setClockSkew(txn, skew);
        }
      });

      pushed += ackedSeqs.length;
      rejected += droppedThisRound;
      conflicts.addAll(resp.conflicts);
      final pulledThisRound =
          serverNotes.length + serverNotebooks.length + serverTags.length;
      pulled += pulledThisRound;
      anythingChanged = anythingChanged ||
          pulledThisRound > 0 ||
          ackedSeqs.isNotEmpty ||
          droppedThisRound > 0;

      // Another round only if this one was full AND fully acked — otherwise
      // the unacked head would just be re-pushed in a tight loop.
      final drainedMore = batch.length >= _batchSize && retrySeqs.isEmpty;
      if (!drainedMore) break;
    }

    await _purgeTombstones();
    if (anythingChanged) _appDb.notifyChanged();

    return SyncResult(
      pushed: pushed,
      pulled: pulled,
      conflicts: conflicts,
      rejected: rejected,
      success: true,
    );
  }

  /// Hard-delete soft-deleted rows that synced long ago; keeps trash bounded.
  Future<void> _purgeTombstones() async {
    final cutoff =
        DateTime.now().toUtc().subtract(ApiConfig.tombstoneRetention);
    final db = await _appDb.database;
    await db.transaction((txn) async {
      await _notes.purgeDeletedBefore(txn, cutoff);
      await _notebooks.purgeDeletedBefore(txn, cutoff);
      await _tags.purgeDeletedBefore(txn, cutoff);
    });
  }
}

/// Outcome of a sync cycle. [success] means the round-trips completed;
/// [conflicts] can be non-empty even on success (LWW already resolved them in
/// favour of the server, which is reflected in the pulled entities).
/// [rejected] counts outbox entries dropped after exhausting their retries.
class SyncResult {
  final int pushed;
  final int pulled;
  final List<SyncConflict> conflicts;
  final int rejected;
  final bool success;
  final String? error;
  final bool skipped;
  final bool unauthorized;

  const SyncResult({
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    this.rejected = 0,
    required this.success,
    this.error,
  })  : skipped = false,
        unauthorized = false;

  const SyncResult.failure(String message, {this.unauthorized = false})
      : pushed = 0,
        pulled = 0,
        conflicts = const [],
        rejected = 0,
        success = false,
        error = message,
        skipped = false;

  const SyncResult.skipped()
      : pushed = 0,
        pulled = 0,
        conflicts = const [],
        rejected = 0,
        success = true,
        error = null,
        skipped = true,
        unauthorized = false;

  bool get hasConflicts => conflicts.isNotEmpty;
}
