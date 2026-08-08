# Oblix local load testing

This harness starts a **separate** Postgres/API Compose project named
`oblix-loadtest`. It never connects to the development or production database.
By default, `run.ps1` tears the project down with `--volumes` even when a test
fails, permanently removing all generated users, sessions, notes, and sync
records.

## Prerequisite

Install and start Docker Desktop. From `backend`, run PowerShell:

```powershell
.\loadtest\run.ps1 -Scenario api -Vus 10 -Duration 30s
```

Increase gradually, allowing the prior test to pass before moving up:

```powershell
.\loadtest\run.ps1 -Scenario api -Vus 50 -Duration 2m
.\loadtest\run.ps1 -Scenario api -Vus 100 -Duration 2m
.\loadtest\run.ps1 -Scenario websockets -Vus 100 -Duration 45s
```

`-Vus` is the number of simultaneous virtual users. Each virtual user gets an
isolated generated account by default (`-Users` can raise that count). The API
scenario reads notes, pulls sync, and performs a small sync write on 20% of
cycles. The WebSocket scenario creates one note per user and holds authenticated
live-collaboration connections open.

The k6 thresholds flag more than 1% request/application failures or an API p95
over one second. Treat the first failing level as a capacity signal, then check
Docker CPU/RAM and Postgres logs before drawing conclusions.

To retain the stack briefly for diagnosis, add `-KeepEnvironment`. Clean it
afterward (this deletes all generated accounts/data):

```powershell
docker compose -p oblix-loadtest -f .\docker-compose.loadtest.yml down --volumes --remove-orphans
```

Local results are a Python baseline and bottleneck finder; repeat the exact
scenarios on the real server class before publishing a user-capacity claim.
