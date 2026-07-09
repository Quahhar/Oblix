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
  static const _dbVersion = 2;

  final DatabaseFactory? _dbFactory;
  final String? _pathOverride;

  Database? _db;

  /// Broadcasts after any local data mutation so listeners (e.g. the UI, later)
  /// can refresh. Emits are coarse — "something changed" — which is enough to
  /// re-query.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changes.stream;
  void notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<Database> get database async {
    return _db ??= await _open();
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
    if (factory != null) {
      return factory.openDatabase(path, options: options);
    }
    return openDatabase(
      path,
      version: _dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onConfigure(Database db) async {
    // Enforce foreign keys (off by default in SQLite).
    await db.execute('PRAGMA foreign_keys = ON');
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
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createOutbox(Database db) async {
    // Durable queue of local mutations awaiting push. `seq` gives a stable FIFO
    // order and an ack cursor.
    await db.execute('''
      CREATE TABLE outbox (
        seq          INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type  TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        action       TEXT NOT NULL,
        data         TEXT NOT NULL,
        timestamp    TEXT NOT NULL,
        device_id    TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_outbox_entity ON outbox(entity_id)');
  }

  Future<void> _createMeta(Database db) async {
    // Key/value metadata: sync cursor, device id, cached user id.
    await db.execute('''
      CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  /// Test/util hook.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
