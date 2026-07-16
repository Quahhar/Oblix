# Oblix — project guide for Claude Code

Self-hosted, Evernote-style notes app. **This is the `backend/` half of a
monorepo**: the repo root is the Flutter client (`lib/`, `test/`), and this
directory is the FastAPI backend it talks to.

## Stack & runtime
- **FastAPI + async SQLAlchemy 2.0 + Postgres**, packaged with Docker.
- Prod is served at **`https://quahhar.com/oblix/`** (nginx reverse-proxies
  `/oblix/` → `127.0.0.1:8001` → the `api` container on port 8000).
- Compose files in use: `docker-compose.prod.yml` + `docker-compose.behind-nginx.yml`.
- Rebuild + redeploy after a change:
  `docker compose -f docker-compose.prod.yml -f docker-compose.behind-nginx.yml up -d --build api`
- Schema is owned by **Alembic migrations** in production (never `create_all`).

## API conventions (the frontend depends on these — do not break them)
- Auth: **Bearer access token** on every request; `POST /api/auth/refresh`
  rotates refresh tokens (reuse of a rotated token revokes the whole family).
  Access tokens carry the session `jti`; logout/logout-all revoke immediately.
- **All ids are UUID strings** on the wire; **all timestamps are ISO-8601**.
  Response schemas MUST type these as `uuid.UUID` / `datetime` (NOT `str`) or
  Pydantic v2 raises `ResponseValidationError` → 500.
- JSON fields are **snake_case** (`display_name`, `notebook_id`, `tag_ids`, …).
- Editing a note uses **PUT** `/api/notes/{id}` (not PATCH). Logout needs a
  `{"refresh_token": ...}` body.
- **PUT partial-update semantics**: a field *omitted* from the body is left
  unchanged; `notebook_id` / `parent_id` sent as explicit `null` (or `""`)
  **detaches** (unfiles the note / moves the notebook to top level) — this uses
  `model_fields_set`, so don't collapse it back to `is not None` checks.
  `tag_ids: []` clears a note's tags; omitted/`null` leaves them unchanged.
- `POST /api/auth/change-password` verifies the current password, **revokes
  every session**, and returns a fresh token pair (so the calling device stays
  signed in). `PUT /api/auth/me` updates `display_name`.
- Emails are stored/matched **lower-cased**.
- Auth endpoints are **rate-limited** (in-process sliding window; login is
  keyed per client-IP+email — see `app/utils/rate_limit.py`). Single-worker
  only by design; `RATE_LIMIT_ENABLED=false` disables it (e.g. load tests).
  Client IP comes from `X-Forwarded-For`, so nginx must set it (DEPLOY.md).

## Sync model
- Client is **local-first**: save to on-device storage on every keystroke;
  push to the server on a **~30s debounce** (and on note-close / app-background).
- Batch multiple offline changes in one `POST /api/sync/push` (savepoint per
  change; last-write-wins with server-newer conflicts reported; deletes are
  tombstoned so other devices learn about them via `/api/sync/pull`).

## Invariants learned the hard way (keep these true)
- Note→tag goes through the `NoteTag` association object; `NoteResponse.tags`
  unwraps to the real `Tag` and only links tags **owned by the caller**.
- Notebook `parent_id` is validated (exists, owned, not self, no cycle);
  `list_notebooks` builds the tree in Python and treats orphans as roots so a
  notebook never vanishes when its parent is deleted.
- Never serialize a lazy relationship in an async response (build the response
  explicitly instead) — it triggers `MissingGreenlet` → 500.
- Note version history is **coalesced** (autosaves within
  `NoteService._VERSION_COALESCE_WINDOW` fold into the latest snapshot) and
  **capped** at `NoteService._MAX_VERSIONS` per note.

## Frontend (Flutter) — keep backend changes compatible with this
- **Repo location**: the monorepo root (`../lib`, `../test`); this backend dir
  sits alongside it.
- **Local store**: raw **sqflite** (no Drift/Hive) — schema v4 in
  `lib/core/db/app_database.dart` (notes/notebooks/tags/outbox/meta/attachments
  + FTS5 index with LIKE fallback). Local DB is the source of truth; every
  mutation writes the row + an outbox entry in one transaction.
- **State management**: none of the big frameworks — plain StatefulWidgets +
  repository classes + a coarse `AppDatabase.onChanged` broadcast stream the
  screens re-query on. Session state is `AuthState` (a ValueNotifier).
- **Tokens**: flutter_secure_storage; `AuthInterceptor` injects the Bearer
  token and on 401 does a single-flight `POST /auth/refresh` + one retry;
  a failed refresh clears tokens and flips `AuthState` to signedOut.
- **Autosave**: 600 ms debounce in `lib/ui/screens/note_editor_screen.dart`;
  the sync scheduler pushes ~30 s after local edits (outbox-gated debounce in
  `lib/domain/services/sync_scheduler.dart`), plus timer/connectivity/foreground
  triggers with exponential failure backoff.
- **Endpoints used**: `/auth/register|login|refresh|logout|me`, `/sync/push`
  (the only sync call — its `server_changes` doubles as the pull),
  `/files` + `/files/upload|{id}/download|{id}` for attachments, and the
  import/export transfer endpoints.
- **Field expectations**: note `data` includes `tags` as a list of names
  (strings or `{"name": …}` both parse); clients merge notes by
  **`edited_at`** (fallback `updated_at`) — keep emitting it in
  `_note_to_dict`; `applied`/`conflicts` entity ids drive outbox acks
  (an id never mentioned = retried, bounded); `server_time` is the next
  cursor; file sync changes carry no binary — bytes go through multipart
  upload only after the owning note has synced.
