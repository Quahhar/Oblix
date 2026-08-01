# Oblix

Offline-first note-taking app (Evernote-style): notes, notebooks, tags, archive
and trash, full-text search, background sync, and import/export. Flutter client
+ FastAPI backend (in `backend/`).

## Architecture

The device's SQLite database is the source of truth for owned/offline data.
Normal reads and writes stay local; shared-note editing additionally uses an
authenticated WebSocket session for server-ordered live text updates:

```
UI  ⇄  repositories  ⇄  local SQLite (sqflite)
                             ⇅ outbox / merge
                        SyncEngine  ⇄  FastAPI /api/sync

shared note editor  ⇄  CollaborationSession  ⇄  FastAPI WebSocket
```

- **Writes**: private/offline mutations write the local row AND an outbox entry
  in one transaction, then return. The outbox is a durable FIFO queue (`seq`).
  Live title/body edits use operational transform; a scoped SQLite fallback is
  retained until the server confirms the exact field value.
- **Sync** (`SyncEngine.syncOnce`): pushes outbox batches to `/sync/push`; the
  response carries acks (`applied` + `conflicts`), everything changed on the
  server since our cursor (`server_changes`), and the next cursor
  (`server_time`). Server changes are LWW-merged, the batch is settled, and the
  cursor advances — all in one local transaction, so a crash mid-sync safely
  re-runs the cycle. Rounds repeat until the outbox is drained.
- **Acks**: entries the server never mentions are retried up to
  `ApiConfig.maxPushAttempts` times, then dropped (poison protection). An empty
  `applied`+`conflicts` acks the whole batch (legacy servers).
- **Conflicts**: server-side last-write-wins compares the incoming edit time
  with `edited_at` (falling back to `updated_at` for older rows); client-side,
  an older server change never overwrites a newer local row. Client timestamps
  are corrected by the clock skew observed at each sync (`SyncClock`), and each
  edit is stamped strictly after the version it edits.
- **Tombstones**: notes, notebooks and tags are soft-deleted so deletions
  propagate across devices; synced tombstones are purged locally after
  `ApiConfig.tombstoneRetention` (30 days).
- **Triggers**: periodic timer, regained connectivity, app foregrounding, and
  manual (pull-to-refresh / sync button). Consecutive failures back off
  exponentially; a 401 that survives token refresh stops the scheduler, flips
  the app-wide `AuthState`, and lands the user on the login screen **without
  destroying unsynced local data** (explicit logout is what clears data).

### Search

Notes are indexed in an FTS5 table (`notes_fts`, external-content, kept in
sync by triggers; `PRAGMA recursive_triggers` is on so `INSERT OR REPLACE`
upserts fire them correctly). On SQLite builds without FTS5 the search falls
back to escaped `LIKE`.

### Auth

JWT access/refresh tokens in secure storage. `AuthInterceptor` injects the
bearer token, coalesces concurrent 401s into a single refresh, and retries the
failed request once. The JWT `sub` is cached so notes created offline carry a
real owner id; signing into a *different* account on the same install wipes
the previous user's local data first.

### Import / export

- **Import** Evernote `.enex` (title, body, tags, timestamps; ENML is flattened
  to text, embedded media is counted and skipped for now) or a native `.oblix`
  file. Imported notes are created fresh on the current account and sync like
  any other edit.
- **Export** user-selected notes to `.oblix`, EPUB, Markdown, or plain text.
  The portable `.oblix` ZIP preserves the selected notes' text, supported
  metadata, notebook ancestry, tags, and attachment bytes. Export fails instead
  of silently omitting an attachment that is known locally but unavailable.

`.oblix` is a portable note archive, not a complete account backup: import
mints fresh entity ids, and the current format does not carry version history,
tasks, sharing permissions, or deleted items. Notebooks are linked by name
path, so identical sibling notebooks with the same name are merged on import.
Use the backend database/upload backup scripts for a complete server backup.

Parsing/serialization live in `lib/data/io/` and are covered by round-trip
tests; the file-pick/share glue is in Settings and the note editor.

## Running

```sh
# Backend (from backend/): alembic upgrade head && uvicorn app.main:app
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000   # Android emulator
flutter test
```

## Deployment

The backend ships as a Docker stack (Postgres + FastAPI + Caddy auto-HTTPS, or
a behind-nginx variant). See [backend/DEPLOY.md](backend/DEPLOY.md) for the full
procedure. Point a release build at your server with
`--dart-define=API_BASE_URL=https://your-host`.

## Known gaps / roadmap

- **Note versions**: the server keeps versions; the client model parses them
  but no history UI exists.
- **Tag rename fan-out**: notes store tag *names* denormalized; renaming a tag
  doesn't rewrite existing notes' tag lists.
- **Google sign-in**: API support exists (`/auth/google`), no client button.
- **Email verification / OTP**: not implemented — registration is instant.
