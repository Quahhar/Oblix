# Oblix

Self-hosted, Evernote-style notes backend. FastAPI + async SQLAlchemy 2.0 +
PostgreSQL, packaged with Docker. This repo is the **API only** — the client is
a separate Flutter mobile app.

## Features

- **Notes** with plain/rich content, pin/archive, soft-delete trash + restore,
  and coalesced version history (rapid autosaves fold into one snapshot).
- **Notebooks** as a nested tree (parent validation: ownership, no cycles).
- **Tags** (per-user, tombstoned on delete so devices converge).
- **Offline-first sync**: batched `POST /api/sync/push` with a savepoint per
  change, last-write-wins by *edit* time, per-change conflict reporting, and
  cursor-paginated `GET /api/sync/pull`.
- **File attachments** with MIME/extension allow-listing, size caps, and
  ownership-scoped downloads.
- **Real-time collaboration**: share a note or notebook as `viewer` or
  `editor`; authenticated WebSockets provide live presence/cursors, while a
  persisted, UTF-16-aware operational-transform journal merges concurrent
  title/body edits. Baseline epochs safely reconcile whole-document offline
  sync. Full OT deltas have a 24-hour retention target (expired rows are
  drained in bounded batches every five minutes) and a strict 10,000-operation
  per-note ceiling, with baseline rotation when either limit is reached.
  Compact operation-ID receipts survive epoch rotation and whole-document
  baselines for seven days, so realistic uncertain retries remain idempotent
  without retaining old document contents. Clients more than 256 revisions
  behind resync instead of replaying unbounded history. Per-room dispatch
  queues preserve frame order and do not send on sockets until the database
  transaction has released its note lock. A room admits at most 64 sockets
  (eight per account), and live note bodies are capped at 2,000,000 UTF-16
  units.
- **Tasks**: todos with due dates, optionally attached to a note, synced like
  every other entity.
- **AI**: `POST /api/ai/summarize` — a metered pass-through to the Anthropic
  Messages API. Disabled until `ANTHROPIC_API_KEY` is set.
- **Auth**: JWT access tokens bound to a server-side session, rotating refresh
  tokens with reuse detection (plus a small grace window for flaky-network
  retries), Google Sign-In (verified emails only), change-password that revokes
  every session, and in-process rate limiting on the auth endpoints.

## Quick start (development)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# Point DATABASE_URL at a local Postgres, then:
alembic upgrade head
uvicorn app.main:app --reload
```

Interactive API docs at `http://127.0.0.1:8000/docs`.

Run the regression and correctness checks with:

```bash
pip install -r requirements-dev.txt
pytest
ruff check app tests alembic
```

## Production

See **[DEPLOY.md](DEPLOY.md)**. Two supported shapes:

- `docker-compose.prod.yml` — bundled Caddy terminates TLS (needs a DNS record
  and ports 80/443).
- `docker-compose.prod.yml` + `docker-compose.behind-nginx.yml` — for servers
  where nginx already owns 80/443; the API binds `127.0.0.1:8001` and nginx
  proxies a path (e.g. `/oblix/`) to it.

Both run Alembic migrations in a gate container before the API starts, never
`create_all`. Copy `.env.example` to `.env` and fill in real values —
**`.env` is never committed**.

The bundled API intentionally runs one Uvicorn worker because live room
presence/fan-out is in process. Add shared Redis/Postgres pub-sub before
scaling the API horizontally; PostgreSQL already serializes and persists the
operations themselves.

```bash
docker compose -f docker-compose.prod.yml -f docker-compose.behind-nginx.yml up -d --build
```

Backups: `scripts/backup.sh` / `scripts/restore.sh` (database + uploads).

## API sketch

| Area | Endpoints |
|------|-----------|
| Auth | `POST /api/auth/register` · `login` · `google` · `refresh` · `logout` · `logout-all` · `change-password` · `GET/PUT /api/auth/me` |
| Notes | `GET/POST /api/notes` · `GET/PUT/DELETE /api/notes/{id}` · `POST /api/notes/{id}/restore` (versions ride along in note responses) |
| Notebooks | `GET/POST /api/notebooks` · `PUT/DELETE /api/notebooks/{id}` (tree in `GET`) |
| Tags | `GET/POST /api/tags` · `DELETE /api/tags/{id}` |
| Sync | `POST /api/sync/push` · `GET /api/sync/pull` |
| Files | `POST /api/files/upload` · `GET /api/files/{id}/download` · `DELETE /api/files/{id}` |
| Shares | `GET/POST /api/shares` · `PUT/DELETE /api/shares/{id}` · `GET /api/shares/with-me` · `GET /api/shares/notebook/{id}/notes` |
| Live collaboration | `WS /api/collaboration/notes/{id}/ws` (Bearer token in the upgrade request) |
| Tasks | `GET/POST /api/tasks` · `GET/PUT/DELETE /api/tasks/{id}` · `POST /api/tasks/{id}/restore` |
| AI | `GET /api/ai/status` · `POST /api/ai/summarize` |

Import/export (`.enex`, `.oblix`) is **not** a backend concern — the Flutter
client parses and writes those files locally and lets the results flow out
through normal sync.

Conventions: bearer access token on every request; UUID ids and ISO-8601
timestamps on the wire; snake_case JSON; note edits via `PUT` (omitted field =
unchanged, explicit `null` on `notebook_id`/`parent_id` = detach).

## Layout

```
app/
  main.py          # FastAPI app, CORS, lifespan
  config.py        # pydantic-settings; refuses insecure prod config
  models/          # SQLAlchemy models (users, sessions, notes, notebooks, tags, files, shares, tasks, sync log)
  routers/         # HTTP layer
  services/        # business logic (auth, notes, sync, files, shares, tasks, ai)
  utils/           # security, rate limiting, storage, upload policy
alembic/           # migrations (own the schema in production)
scripts/           # backup.sh / restore.sh
```
