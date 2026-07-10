# Cyclux

Offline-first note-taking app (Evernote-style): notes, notebooks, tags, archive
and trash, full-text search, and background sync. Flutter client + FastAPI
backend (in `backend/`).

## Architecture

The device's SQLite database is the source of truth. The UI never talks to the
network:

```
UI  ⇄  repositories  ⇄  local SQLite (sqflite)
                             ⇅ outbox / merge
                        SyncEngine  ⇄  FastAPI /api/sync
```

- **Writes**: every mutation writes the local row AND an outbox entry in one
  transaction, then returns. The outbox is a durable FIFO queue (`seq`).
- **Sync** (`SyncEngine.syncOnce`): pushes outbox batches to `/sync/push`; the
  response carries acks (`applied` + `conflicts`), everything changed on the
  server since our cursor (`server_changes`), and the next cursor
  (`server_time`). Server changes are LWW-merged, the batch is settled, and the
  cursor advances — all in one local transaction, so a crash mid-sync safely
  re-runs the cycle. Rounds repeat until the outbox is drained.
- **Acks**: entries the server never mentions are retried up to
  `ApiConfig.maxPushAttempts` times, then dropped (poison protection). An empty
  `applied`+`conflicts` acks the whole batch (legacy servers).
- **Conflicts**: last-write-wins on `updated_at`, both server-side (client
  pushes with an older timestamp → server keeps its copy and returns it) and
  client-side (older server change never overwrites a newer local row). Client
  timestamps are corrected by the clock skew observed at each sync
  (`SyncClock`), and each edit is stamped strictly after the version it edits.
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

## Running

```sh
# Backend (from backend/): alembic upgrade head && uvicorn app.main:app
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000   # Android emulator
flutter test
```

## Known gaps / roadmap

- **Attachments**: the server has file endpoints and sync relink/delete; the
  client doesn't support files yet.
- **Note versions**: the server keeps versions; the client model parses them
  but no history UI exists.
- **Tag rename fan-out**: notes store tag *names* denormalized; renaming a tag
  doesn't rewrite existing notes' tag lists.
- **Google sign-in**: API support exists (`/auth/google`), no client button.
- Backend changes in this repo (note-tag application, tag tombstones,
  migration `0002_tag_soft_delete`) have not been run against a live server.
