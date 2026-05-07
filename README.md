# openhost-lila

[Lichess (Lila)](https://github.com/lichess-org/lila) chess server,
packaged for OpenHost with one-click SSO.

## What this is

A self-hosted single-container Lichess instance with one-click
SSO via Pattern B (auth-proxy auto-login).  Bundled:

- **lila** — the Scala / Play Framework chess server itself
- **lila-ws** — the Scala WebSocket sidecar (live game streams)
- **MongoDB** — game/user/tournament store, pre-seeded with
  ~300 sample users so the lobby isn't empty
- **Redis** — pub/sub between lila and lila-ws, plus session
  cache
- **Caddy** — internal reverse-proxy that splits HTTP and WS
  traffic between lila and lila-ws
- **auth_proxy.py** — owner auto-login sidecar (Pattern B)

We extend `ghcr.io/lichess-org/lila-docker:latest`, which is
the same image the upstream `lila-docker` repo's `mono` profile
uses for "give me Lichess in one container."  Reusing it means
we don't have to compile Lila from source (a 30+ minute sbt
build).

## Architecture

```
  browser ──HTTPS──▶ OpenHost outer Caddy
                  ──▶ OpenHost router (subdomain lila.<zone>;
                                       JWT-verifies; stamps
                                       X-OpenHost-Is-Owner)
                  ──▶ container :8080  (auth_proxy.py)
                          │
                          │ owner without lila2 cookie?
                          │  → POST /login as `admin`,
                          │    capture Set-Cookie: lila2=...,
                          │    302 with cookie → original URL
                          │
                          ▼ otherwise transparent forward
                       127.0.0.1:8081  (Caddy)
                          ├──▶ /socket/v6 (WS Upgrade)
                          │       → 127.0.0.1:9664  (lila-ws)
                          └──▶ everything else
                                 → 127.0.0.1:9663  (Lila)
                                      ↕
                                   MongoDB :27017     (loopback)
                                   Redis   :6379      (loopback)
```

## Auth model

- **Anonymous on a gated path** — OpenHost router 302's to the
  zone's SSO before the request reaches us.
- **Owner with `lila2` cookie** — forwarded transparently.
- **Owner without `lila2` cookie** — auth_proxy POSTs admin
  credentials to Lila's `/login`, captures `Set-Cookie:
  lila2=...; HttpOnly`, issues a 302 to the same path with the
  cookie set.  The user lands logged in as `admin` (a seeded
  ROLE_ADMIN user).

Auto-login fires on top-level HTML navigations only (so XHR /
asset fetches don't get caught in a redirect loop while the
session is establishing).

## First-boot bootstrap

`openhost-init.sh` runs as the first supervisord program.  On
fresh install:

1. Copies `/seeded` (the image's pre-baked MongoDB data) into
   `$OPENHOST_APP_DATA_DIR/mongodb/` so subsequent boots run
   mongod from the persistent path.
2. Generates the admin credentials file at
   `$OPENHOST_APP_DATA_DIR/admin-credentials.txt` (mode 0600).
   Default admin is username=`admin`; password is randomly
   generated on first boot (32 alphanumeric chars, ~190 bits of
   entropy) and persisted to the credentials file for the
   auth_proxy to read.  Override with the `LILA_ADMIN_PASSWORD`
   env var if you want a known password (e.g. for manual login
   debugging).  On subsequent boots the password is recovered
   from the credentials file so it survives container restarts
   (the seeded MongoDB user has the same password baked in via
   `reset-db.sh`).
3. Sources `$OPENHOST_ZONE_DOMAIN` / `$OPENHOST_APP_NAME` to
   compute `LILA_DOMAIN` (`lila.<zone>`) and `LILA_URL`
   (`https://lila.<zone>`), writing them to
   `/etc/environment-openhost-lila` for every supervisord
   child to source.

On subsequent boots:

- The init script sees `WiredTiger.wt` already in
  `$OPENHOST_APP_DATA_DIR/mongodb/` and skips the seed copy.
- The `/scripts/reset-db.sh` step is gated on a sentinel file
  (`.seeded-once`) so it only runs on the very first boot.
  Without this, every container restart would wipe operator
  user state — `reset-db.sh` passes `--drop-db` to the seeder.

## Persistence

`$OPENHOST_APP_DATA_DIR` (typically `/data/app_data/lila/` —
the OpenHost-managed bind mount) holds:

- `mongodb/` — MongoDB data dir (game / user / tournament
  state).  Copied from `/seeded` on first boot only.
- `redis/` — Redis appendonly file (session cache; survivable
  to loss but speeds re-warm).
- `admin-credentials.txt` — auto-login creds (mode 0600).

The presence of `mongodb/WiredTiger.wt` is the authoritative
"this dir is initialised" sentinel.  reset-db.sh runs (with
its destructive `--drop-db`) only on the very first boot, when
that file is absent.

Backup target: the entire `$OPENHOST_APP_DATA_DIR` dir.

## Resources

6 GiB RAM (4 GiB heap for lila JVM, 1 GiB for lila-ws / mongo /
redis / Caddy / system, 1 GiB slack), 3 CPUs.  Lila is JVM-heavy
so the `-Xmx4g` baked into the upstream mono image is non-
negotiable.

## Known limitations / scope cuts

- **No Elasticsearch.**  Lila's search ("find player by name",
  game search) won't work.  Lila gracefully degrades to "no
  results" rather than crashing.
- **No lila-fishnet.**  Computer-analysis requests against the
  built-in `Stockfish` engine queue forever.  This is fine for
  human-only play.
- **No lila-search.**  Same as Elasticsearch — search returns
  empty results.
- **No SMTP.**  Password resets, email confirmations, etc., go
  nowhere.  The admin user's password is what auth_proxy uses;
  operators who want to add new users have to do it via the
  `/account/email` flow with `MOCK_EMAIL=true` (the upstream
  mono image already sets this).
- **No Firebase / push notifications.**  Mobile push is a no-op.
- **The seed DB is a stylized dataset.**  Sample tournaments
  are dated 2020-ish, leaderboards are seeded with fake users.
  This is by design — the upstream mono image is built for
  "look like Lichess at a glance" UX.

## Files

- `openhost.toml` — OpenHost manifest.
- `Dockerfile` — extends `ghcr.io/lichess-org/lila-docker:latest`.
- `mono.Caddyfile` — Caddy on loopback 8081 (auth_proxy occupies
  public 8080).
- `supervisord.conf` — replaces upstream's; adds openhost-init
  and auth-proxy programs, points mongo at persistent dir.
- `openhost-init.sh` — first-boot init: seed copy, env file
  generation, credentials.
- `auth_proxy.py` — owner auto-login auth-proxy sidecar.
