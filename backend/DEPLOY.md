# Deploying the Oblix backend to a Linux server

Production stack: **Postgres + FastAPI + Caddy** (automatic HTTPS), all in Docker.
The API runs with `ENVIRONMENT=production`, so Alembic migrations — not
`create_all` — own the schema. A one-shot `migrate` service applies them before
the API serves traffic.

## Prerequisites

- A Linux server (Ubuntu/Debian assumed) with a public IP.
- A domain name with a DNS **A record** pointing at that IP
  (e.g. `notes.yourdomain.com`). Caddy needs this to issue a TLS cert.
- Ports **80** and **443** open in the firewall.

## 1. Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # log out and back in afterwards
```

## 2. Get the code

```bash
git clone <your-repo-url> oblix
cd oblix/backend
```

## 3. Configure secrets

```bash
cp .env.example .env
openssl rand -hex 32          # paste into SECRET_KEY
nano .env                     # set DOMAIN, ACME_EMAIL, SECRET_KEY, POSTGRES_PASSWORD
```

Make sure `CORS_ORIGINS` and `DOMAIN` use your real domain. `.env` is
gitignored — it must never be committed.

## 4. Launch

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

This builds the image, starts Postgres, runs migrations, starts the API, and
brings up Caddy (which fetches a TLS certificate on first request — allow a
minute).

## 5. Verify

```bash
docker compose -f docker-compose.prod.yml ps          # all healthy
curl https://notes.yourdomain.com/health              # {"status":"healthy"}
```

Register a test account:

```bash
curl -X POST https://notes.yourdomain.com/api/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"me@example.com","password":"supersecret","display_name":"Me"}'
```

A `201` with `access_token`/`refresh_token` means the DB, migrations, and auth
all work end to end.

## 6. Point the app at the server

Build the Flutter app with your domain baked in:

```bash
flutter build apk --dart-define=API_BASE_URL=https://notes.yourdomain.com
```

## Variant: server already runs nginx on 80/443

Caddy can't bind 80/443 if nginx already owns them. Use the behind-nginx
override instead — it skips Caddy and publishes the API on `127.0.0.1:8001`:

```bash
docker compose -f docker-compose.prod.yml -f docker-compose.behind-nginx.yml up -d --build
```

Then add a location block to your existing nginx vhost (path-based, no new
DNS record needed; the trailing slash on `proxy_pass` strips the `/oblix`
prefix before it reaches the API):

```nginx
location /oblix/ {
    proxy_pass http://127.0.0.1:8001/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 50m;   # match MAX_UPLOAD_SIZE_MB
}
```

`nginx -t && systemctl reload nginx`, and the API is live at
`https://yourdomain.com/oblix`. Build the app with
`--dart-define=API_BASE_URL=https://yourdomain.com/oblix`.
(`DOMAIN`/`ACME_EMAIL` in `.env` are unused in this variant.)

## Day-2 operations

| Task | Command |
|------|---------|
| View logs | `docker compose -f docker-compose.prod.yml logs -f api` |
| Apply new migrations after a pull | `docker compose -f docker-compose.prod.yml up -d --build` (the `migrate` service re-runs) |
| Restart | `docker compose -f docker-compose.prod.yml restart api` |
| Back up the database | `docker compose -f docker-compose.prod.yml exec db pg_dump -U $POSTGRES_USER $POSTGRES_DB > backup.sql` |
| Stop everything | `docker compose -f docker-compose.prod.yml down` (add `-v` to also wipe data) |

## Updating

```bash
git pull
docker compose -f docker-compose.prod.yml up -d --build
```

The `migrate` service applies any new migrations automatically before the new
API container starts.
