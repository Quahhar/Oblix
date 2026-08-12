import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class SyncRoundLease {
  SyncRoundLease._(this.protectedNoteIds, this._completion, this._release);

  final Set<String> protectedNoteIds;
  final Completer<void> _completion;
  final void Function(Completer<void>) _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release(_completion);
  }
}

class CollaborativeNoteLease {
  CollaborativeNoteLease._(this.noteId, this._release);

  final String noteId;
  final void Function(String) _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release(noteId);
  }
}

/// Owns the on-device SQLite database — the source of truth in this
/// offline-first app. The UI reads/writes here; sync reconciles with the server
/// in the background.
class AppDatabase {
  AppDatabase._({DatabaseFactory? dbFactory, String? path})
    : _dbFactory = dbFactory,
      _pathOverride = path;

  /// App-wide singleton used in production.
  static final AppDatabase instance = AppDatabase._();

  /// Build a throwaway instance backed by an injected factory/path — used by
  /// tests to run against an in-memory database (sqflite_common_ffi) without
  /// touching the real device store.
  factory AppDatabase.ephemeral({DatabaseFactory? dbFactory, String? path}) =>
      AppDatabase._(dbFactory: dbFactory, path: path);

  static const _dbName = 'oblix.db';
  static const _dbVersion = 8;

  final DatabaseFactory? _dbFactory;
  final String? _pathOverride;

  /// Shared collaboration cache ordering for every repository backed by this
  /// database. Keeping it on the database instance prevents two editor screens
  /// from using independent revision guards, while ephemeral test/account
  /// databases remain isolated from one another.
  final Map<String, Future<void>> collaborativeWriteTurns = {};
  final Map<String, ({String epoch, int revision})> collaborativeRevisions = {};
  final Map<String, int> _collaborativeNoteRefs = <String, int>{};
  final Set<Completer<void>> _syncRounds = <Completer<void>>{};

  void clearCollaborativeWriteState() {
    collaborativeWriteTurns.clear();
    collaborativeRevisions.clear();
    _collaborativeNoteRefs.clear();
  }

  /// Protect a note's durable fallback before opening its live socket. The
  /// marker is installed synchronously, then any sync round which started
  /// first is allowed to finish before the caller receives the lease.
  Future<CollaborativeNoteLease> protectNoteForCollaboration(
    String noteId,
  ) async {
    _collaborativeNoteRefs.update(
      noteId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    final earlierRounds = _syncRounds.map((round) => round.future).toList();
    if (earlierRounds.isNotEmpty) await Future.wait(earlierRounds);
    return CollaborativeNoteLease._(noteId, _releaseCollaborativeNote);
  }

  /// Freeze the currently protected notes before a sync round performs its
  /// first await. Collaboration that starts later waits for this round; a
  /// round that starts later excludes these notes for its entire response.
  SyncRoundLease beginSyncRound() {
    final completion = Completer<void>();
    _syncRounds.add(completion);
    return SyncRoundLease._(
      Set<String>.unmodifiable(_collaborativeNoteRefs.keys),
      completion,
      _releaseSyncRound,
    );
  }

  void _releaseCollaborativeNote(String noteId) {
    final count = _collaborativeNoteRefs[noteId];
    if (count == null || count <= 1) {
      _collaborativeNoteRefs.remove(noteId);
    } else {
      _collaborativeNoteRefs[noteId] = count - 1;
    }
  }

  void _releaseSyncRound(Completer<void> completion) {
    if (!_syncRounds.remove(completion)) return;
    if (!completion.isCompleted) completion.complete();
  }

  /// The open is cached as a Future so concurrent first callers share one
  /// open instead of racing (`_db ??= await _open()` would let both through).
  Future<Database>? _dbFuture;

  /// Whether the FTS5 index is available on this device (older Android builds
  /// ship SQLite without FTS5). Search falls back to LIKE when false.
  bool _ftsAvailable = false;
  bool get ftsAvailable => _ftsAvailable;

  /// Broadcasts after any local data mutation so listeners (e.g. the UI, later)
  /// can refresh. Emits are coarse — "something changed" — which is enough to
  /// re-query.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changes.stream;
  void notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<Database> get database async {
    final cached = _dbFuture;
    if (cached != null) return cached;
    final opening = _open();
    _dbFuture = opening;
    try {
      return await opening;
    } catch (_) {
      _dbFuture = null; // allow a retry after a failed open
      rethrow;
    }
  }

  Future<Database> _open() async {
    final path =
        _pathOverride ??
        p.join((await getApplicationDocumentsDirectory()).path, _dbName);
    final options = OpenDatabaseOptions(
      version: _dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    final factory = _dbFactory;
    final db = factory != null
        ? await factory.openDatabase(path, options: options)
        : await openDatabase(
            path,
            version: _dbVersion,
            onConfigure: _onConfigure,
            onCreate: _onCreate,
            onUpgrade: _onUpgrade,
          );
    _ftsAvailable = await _ensureFts(db);
    return db;
  }

  Future<void> _onConfigure(Database db) async {
    // Enforce foreign keys (off by default in SQLite).
    await db.execute('PRAGMA foreign_keys = ON');
    // INSERT OR REPLACE (our upsert strategy) must fire DELETE triggers so the
    // FTS index drops the replaced row; that only happens with this pragma on.
    await db.execute('PRAGMA recursive_triggers = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createNotes(db);
    await _createNotebooks(db);
    await _createTags(db);
    await _createOutbox(db);
    await _createMeta(db);
    await _createAttachments(db);
    await _createTasks(db);
    await _createTextLayers(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v1 -> v2: notebooks & tags gained local mirrors.
    if (oldVersion < 2) {
      await _createNotebooks(db);
      await _createTags(db);
    }
    // v2 -> v3: bounded push retries + tag tombstones. (The FTS index is
    // created outside version callbacks — see _ensureFts.)
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE outbox ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE tags ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v3 -> v4: local attachments mirror + upload state.
    if (oldVersion < 4) {
      await _createAttachments(db);
    }
    // v4 -> v5: tasks (synced like notes, entity_type 'task').
    if (oldVersion < 5) {
      await _createTasks(db);
    }
    // Any older version -> v6: existing entity tables gain field-level CRDT
    // clocks. Tables created earlier in this same upgrade already use the
    // current schema, so only ALTER tables that predated the upgrade.
    if (oldVersion < 6) {
      await db.execute(
        "ALTER TABLE notes ADD COLUMN field_clocks TEXT NOT NULL DEFAULT '{}'",
      );
      if (oldVersion >= 2) {
        await db.execute(
          "ALTER TABLE notebooks ADD COLUMN field_clocks TEXT NOT NULL DEFAULT '{}'",
        );
      }
      if (oldVersion >= 5) {
        await db.execute(
          "ALTER TABLE tasks ADD COLUMN field_clocks TEXT NOT NULL DEFAULT '{}'",
        );
      }
      await _backfillCrdtClocks(db, 'notes', const [
        'title',
        'content',
        'content_type',
        'notebook_id',
        'is_pinned',
        'is_archived',
        'tags',
        'is_deleted',
      ]);
      await _backfillCrdtClocks(db, 'notebooks', const [
        'name',
        'parent_id',
        'sort_order',
        'is_deleted',
      ]);
      await _backfillCrdtClocks(db, 'tasks', const [
        'title',
        'description',
        'note_id',
        'due_date',
        'sort_order',
        'is_completed',
        'is_deleted',
      ]);
    }
    // v6 -> v7: recognized text kept beside the image it came from, so a scan
    // stays searchable and can be re-read without the original photograph.
    if (oldVersion < 7) {
      await _createTextLayers(db);
    }
    // v7 -> v8: tasks gain priority, lists, labels, repetition, reminders and
    // subtasks. Every existing task survives with these at their defaults, so
    // nothing a user already wrote down is lost or reinterpreted.
    //
    // No field_clocks backfill: a register a row has never carried falls back
    // to that row's updated_at, which is the right basis for a column that did
    // not exist until this upgrade ran.
    if (oldVersion < 8) {
      if (oldVersion >= 5) {
        for (final column in const [
          'notebook_id TEXT',
          'parent_id TEXT',
          'due_has_time INTEGER NOT NULL DEFAULT 0',
          'priority INTEGER NOT NULL DEFAULT 0',
          "labels TEXT NOT NULL DEFAULT '[]'",
          'recurrence TEXT',
          'reminder_at TEXT',
          'reminder_lead_minutes INTEGER',
        ]) {
          await db.execute('ALTER TABLE tasks ADD COLUMN $column');
        }
        await db.execute('CREATE INDEX idx_tasks_parent ON tasks(parent_id)');
        await db.execute(
          'CREATE INDEX idx_tasks_notebook ON tasks(notebook_id)',
        );
        await db.execute(
          'CREATE INDEX idx_tasks_reminder ON tasks(reminder_at) '
          'WHERE reminder_at IS NOT NULL',
        );
      }
    }
  }

  /// What the recognizer saw, kept per note.
  ///
  /// Local-only and deliberately outside the CRDT tables: a text layer is
  /// derived from an attachment this device already holds, so syncing it would
  /// be paying to move something every device can regenerate. It carries no
  /// field clocks and never reaches the outbox.
  ///
  /// [search_text] is the flattened prose, denormalized out of [encoded] so
  /// FTS has a column to index — the encoded layer is JSON and matching
  /// against it would hit coordinates as readily as words.
  Future<void> _createTextLayers(Database db) async {
    await db.execute('''
      CREATE TABLE text_layers (
        id            TEXT PRIMARY KEY,
        note_id       TEXT NOT NULL,
        attachment_id TEXT,
        source        TEXT NOT NULL DEFAULT '',
        fingerprint   TEXT NOT NULL DEFAULT '',
        search_text   TEXT NOT NULL DEFAULT '',
        encoded       TEXT NOT NULL,
        created_at    TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_text_layers_note ON text_layers(note_id)',
    );
    await db.execute(
      'CREATE INDEX idx_text_layers_fingerprint ON text_layers(fingerprint)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_text_layers_attachment '
      'ON text_layers(attachment_id) WHERE attachment_id IS NOT NULL',
    );
  }

  Future<void> _backfillCrdtClocks(
    Database db,
    String table,
    List<String> fields,
  ) async {
    final rows = await db.query(table, columns: ['id', 'updated_at']);
    for (final row in rows) {
      final stamp = {
        'timestamp': row['updated_at'] as String,
        'device_id': 'legacy',
      };
      await db.update(
        table,
        {
          'field_clocks': jsonEncode({
            for (final field in fields) field: stamp,
          }),
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  // Booleans are stored as 0/1; timestamps as ISO-8601 UTC strings so lexical
  // ordering matches chronological ordering.

  Future<void> _createNotes(Database db) async {
    await db.execute('''
      CREATE TABLE notes (
        id            TEXT PRIMARY KEY,
        user_id       TEXT NOT NULL,
        notebook_id   TEXT,
        title         TEXT NOT NULL DEFAULT 'Untitled',
        content       TEXT NOT NULL DEFAULT '',
        content_type  TEXT NOT NULL DEFAULT 'plain',
        is_pinned     INTEGER NOT NULL DEFAULT 0,
        is_archived   INTEGER NOT NULL DEFAULT 0,
        is_deleted    INTEGER NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL,
        tags          TEXT NOT NULL DEFAULT '[]',
        field_clocks  TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute('CREATE INDEX idx_notes_updated ON notes(updated_at)');
    await db.execute('CREATE INDEX idx_notes_notebook ON notes(notebook_id)');
    await db.execute(
      'CREATE INDEX idx_notes_active ON notes(is_deleted, is_archived)',
    );
  }

  Future<void> _createNotebooks(Database db) async {
    await db.execute('''
      CREATE TABLE notebooks (
        id          TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL,
        name        TEXT NOT NULL,
        parent_id   TEXT,
        sort_order  INTEGER NOT NULL DEFAULT 0,
        is_deleted  INTEGER NOT NULL DEFAULT 0,
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL,
        field_clocks TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_notebooks_parent ON notebooks(parent_id)',
    );
  }

  Future<void> _createTags(Database db) async {
    await db.execute('''
      CREATE TABLE tags (
        id          TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL,
        name        TEXT NOT NULL,
        is_deleted  INTEGER NOT NULL DEFAULT 0,
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createOutbox(Database db) async {
    // Durable queue of local mutations awaiting push. `seq` gives a stable FIFO
    // order and an ack cursor. `attempts` counts pushes the server did not
    // acknowledge, so a poison entry is eventually dropped instead of blocking
    // the queue forever.
    await db.execute('''
      CREATE TABLE outbox (
        seq          INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type  TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        action       TEXT NOT NULL,
        data         TEXT NOT NULL,
        timestamp    TEXT NOT NULL,
        device_id    TEXT,
        attempts     INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX idx_outbox_entity ON outbox(entity_id)');
  }

  Future<void> _createMeta(Database db) async {
    // Key/value metadata: sync cursor, device id, cached user id, clock skew.
    await db.execute('''
      CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  Future<void> _createAttachments(Database db) async {
    // Local mirror of a note's files plus their upload state. `id` is a
    // client-minted local id; `remote_id` is the server's file id, set once
    // the bytes are uploaded (the server mints file ids, unlike notes).
    // `local_path` points at the cached bytes on disk (null for a server file
    // not yet downloaded). Binaries never travel in the JSON outbox — uploads
    // go through the multipart /files endpoint after the owning note has synced.
    await db.execute('''
      CREATE TABLE attachments (
        id            TEXT PRIMARY KEY,
        remote_id     TEXT,
        note_id       TEXT NOT NULL,
        user_id       TEXT NOT NULL,
        filename      TEXT NOT NULL DEFAULT '',
        original_name TEXT NOT NULL DEFAULT '',
        mime_type     TEXT NOT NULL DEFAULT 'application/octet-stream',
        size_bytes    INTEGER NOT NULL DEFAULT 0,
        local_path    TEXT,
        is_uploaded   INTEGER NOT NULL DEFAULT 0,
        is_deleted    INTEGER NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_attachments_note ON attachments(note_id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_attachments_remote ON attachments(remote_id) '
      'WHERE remote_id IS NOT NULL',
    );
  }

  /// The local task mirror.
  ///
  /// `notebook_id` files a task under a notebook — notes and tasks share one
  /// organizing tree rather than the app growing a second. `parent_id` is the
  /// self-reference that makes subtasks possible. Neither carries a SQLite
  /// foreign key: rows arrive from sync in whatever order the server sends
  /// them, so a child can legitimately land before its parent, and the tree is
  /// resolved in the engine instead.
  ///
  /// `due_has_time` distinguishes "Tuesday" from "Tuesday at 5pm". It is not
  /// its own CRDT register — it travels with `due_date`.
  Future<void> _createTasks(Database db) async {
    await db.execute('''
      CREATE TABLE tasks (
        id                    TEXT PRIMARY KEY,
        user_id               TEXT NOT NULL,
        note_id               TEXT,
        notebook_id           TEXT,
        parent_id             TEXT,
        title                 TEXT NOT NULL DEFAULT 'Untitled task',
        description           TEXT NOT NULL DEFAULT '',
        is_completed          INTEGER NOT NULL DEFAULT 0,
        completed_at          TEXT,
        due_date              TEXT,
        due_has_time          INTEGER NOT NULL DEFAULT 0,
        priority              INTEGER NOT NULL DEFAULT 0,
        labels                TEXT NOT NULL DEFAULT '[]',
        recurrence            TEXT,
        reminder_at           TEXT,
        reminder_lead_minutes INTEGER,
        sort_order            INTEGER NOT NULL DEFAULT 0,
        is_deleted            INTEGER NOT NULL DEFAULT 0,
        created_at            TEXT NOT NULL,
        updated_at            TEXT NOT NULL,
        field_clocks          TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await _createTaskIndexes(db);
  }

  Future<void> _createTaskIndexes(Database db) async {
    await db.execute('CREATE INDEX idx_tasks_due ON tasks(due_date)');
    await db.execute(
      'CREATE INDEX idx_tasks_state ON tasks(is_deleted, is_completed)',
    );
    await db.execute('CREATE INDEX idx_tasks_parent ON tasks(parent_id)');
    await db.execute('CREATE INDEX idx_tasks_notebook ON tasks(notebook_id)');
    // The reminder scheduler asks for every pending alarm on launch.
    await db.execute(
      'CREATE INDEX idx_tasks_reminder ON tasks(reminder_at) '
      'WHERE reminder_at IS NOT NULL',
    );
  }

  /// Create the FTS5 full-text index over notes if this SQLite build supports
  /// it. Runs after every open (not in version callbacks) so it also self-heals
  /// databases that were opened on an FTS-less build before. Returns whether
  /// FTS search can be used.
  Future<bool> _ensureFts(Database db) async {
    try {
      final existing = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'notes_fts'",
      );
      if (existing.isNotEmpty) return await _ensureTextLayerFts(db);
      await db.execute('''
        CREATE VIRTUAL TABLE notes_fts USING fts5(
          title, content,
          content='notes', content_rowid='rowid'
        )
      ''');
      await db.execute('''
        CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, content)
          VALUES (new.rowid, new.title, new.content);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, content)
          VALUES ('delete', old.rowid, old.title, old.content);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, content)
          VALUES ('delete', old.rowid, old.title, old.content);
          INSERT INTO notes_fts(rowid, title, content)
          VALUES (new.rowid, new.title, new.content);
        END
      ''');
      // Index whatever already exists (relevant on upgrade from v2).
      await db.execute("INSERT INTO notes_fts(notes_fts) VALUES ('rebuild')");
      return await _ensureTextLayerFts(db);
    } catch (_) {
      // FTS5 unavailable on this SQLite build — search falls back to LIKE.
      return false;
    }
  }

  /// The index that makes the words inside a photograph findable.
  ///
  /// Created outside the version callbacks for the same reason `notes_fts` is:
  /// FTS5 is a compile-time option, so its absence is a property of the SQLite
  /// build rather than of the schema version, and it has to be re-checked on
  /// every open. Returning false here degrades search to LIKE over note text —
  /// scanned pages simply stop being searchable, rather than the app failing
  /// to start.
  Future<bool> _ensureTextLayerFts(Database db) async {
    try {
      final existing = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'text_layers_fts'",
      );
      if (existing.isNotEmpty) return true;
      await db.execute('''
        CREATE VIRTUAL TABLE text_layers_fts USING fts5(
          search_text,
          content='text_layers', content_rowid='rowid'
        )
      ''');
      await db.execute('''
        CREATE TRIGGER text_layers_fts_ai AFTER INSERT ON text_layers BEGIN
          INSERT INTO text_layers_fts(rowid, search_text)
          VALUES (new.rowid, new.search_text);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER text_layers_fts_ad AFTER DELETE ON text_layers BEGIN
          INSERT INTO text_layers_fts(text_layers_fts, rowid, search_text)
          VALUES ('delete', old.rowid, old.search_text);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER text_layers_fts_au AFTER UPDATE ON text_layers BEGIN
          INSERT INTO text_layers_fts(text_layers_fts, rowid, search_text)
          VALUES ('delete', old.rowid, old.search_text);
          INSERT INTO text_layers_fts(rowid, search_text)
          VALUES (new.rowid, new.search_text);
        END
      ''');
      await db.execute(
        "INSERT INTO text_layers_fts(text_layers_fts) VALUES ('rebuild')",
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Test/util hook.
  Future<void> close() async {
    final cached = _dbFuture;
    _dbFuture = null;
    if (cached != null) {
      final db = await cached;
      await db.close();
    }
  }
}
