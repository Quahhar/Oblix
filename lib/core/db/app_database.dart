import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
  factory AppDatabase.ephemeral({
    DatabaseFactory? dbFactory,
    String? path,
  }) =>
      AppDatabase._(dbFactory: dbFactory, path: path);

  static const _dbName = 'cyclux.db';
  static const _dbVersion = 3;

  final DatabaseFactory? _dbFactory;
  final String? _pathOverride;

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
    final path = _pathOverride ??
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
        tags          TEXT NOT NULL DEFAULT '[]'
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
        updated_at  TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_notebooks_parent ON notebooks(parent_id)');
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

  /// Create the FTS5 full-text index over notes if this SQLite build supports
  /// it. Runs after every open (not in version callbacks) so it also self-heals
  /// databases that were opened on an FTS-less build before. Returns whether
  /// FTS search can be used.
  Future<bool> _ensureFts(Database db) async {
    try {
      final existing = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'notes_fts'",
      );
      if (existing.isNotEmpty) return true;
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
      return true;
    } catch (_) {
      // FTS5 unavailable on this SQLite build — search falls back to LIKE.
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
