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
- **Redis** — pub/sub between lila and lila-ws (and lila ↔
  lila-fishnet for AI moves), plus session cache
- **Caddy** — internal reverse-proxy that splits HTTP and WS
  traffic between lila and lila-ws
- **lila-fishnet** — the Scala move-broker for AI games
  (pre-built, copied from `ghcr.io/lichess-org/lila-fishnet`)
- **fishnet** — the Stockfish worker that computes AI opponent
  moves, so "Play with the computer" actually works
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
                                       app is public so anon
                                       visitors pass through;
                                       stamps X-OpenHost-Is-Owner
                                       on the owner's requests)
                  ──▶ container :8080  (auth_proxy.py)
                          │
                          │ owner (X-OpenHost-Is-Owner: true)
                          │ without an authenticated lila2
                          │ session (no sessionId)?
                          │  → POST /login as `admin`,
                          │    capture Set-Cookie: lila2=...,
                          │    302 with cookie → original URL
                          │
                          ▼ otherwise transparent forward
                            (anon guests fall through to Lila)
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

The app is **public** (`public_paths = ["/"]`) so that shareable
Lichess links — open-challenge links, live game URLs, studies,
tournaments — work for people who do not have an OpenHost account.
Access control is then split between two layers: the OpenHost router
handles the *owner*, and Lila's own auth handles *everyone else*.

- **Anonymous visitor** — reaches Lila directly and is served as an
  ordinary anonymous Lichess guest: they can view games, open a
  shared challenge link and accept it, and play as a guest (via
  Lila's `AnonCookie`). They are **never** auto-logged-in as the
  owner (the auth_proxy's trigger is the router-stamped owner header,
  which anonymous requests don't carry). Admin/moderation surfaces
  stay protected by Lila's own `ROLE_ADMIN` authorization.
- **Owner with an authenticated `lila2` session** — forwarded
  transparently.  "Authenticated" means the `lila2` cookie
  carries a `sessionId` key (Lila's logged-in-*user* session id).
  Note this is distinct from `sid`, an anonymous CSRF/socket id
  that every visitor — including anonymous guests — carries.
- **Owner without an authenticated `lila2` session** — auth_proxy
  POSTs admin credentials to Lila's `/login`, captures
  `Set-Cookie: lila2=...; HttpOnly`, issues a 302 to the same
  path with the cookie set.  The user lands logged in as `admin`
  (a seeded ROLE_ADMIN user).  This case covers three states: a
  *missing* `lila2` cookie; a *logged-out* one (on "Log out" Lila
  re-bakes `lila2` to an empty session rather than deleting it);
  and — because the app is public — an *anonymous guest* `lila2`
  (Lila mints one on the first page view; it carries `sid` but no
  `sessionId`).  Keying on `sessionId` rather than `sid` is what
  makes all three re-trigger auto-login, so the next top-level
  navigation transparently (re-)establishes the admin session and
  the owner is never stranded as a guest or logged-out.

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

8 GiB RAM (4 GiB heap for lila JVM, plus lila-ws / mongo / redis /
Caddy / system, plus lila-fishnet — a third small JVM — and a
Stockfish worker that runs native search during AI games), 4 CPUs.
Lila is JVM-heavy so the `-Xmx4g` baked into the upstream mono
image is non-negotiable; the extra headroom over the original
6 GiB / 3 CPU sizing is for lila-fishnet and the Stockfish worker
(pinned to 2 cores) so AI games don't starve the lila JVMs.

## Known limitations / scope cuts

- **No Elasticsearch.**  Lila's search ("find player by name",
  game search) won't work.  Lila gracefully degrades to "no
  results" rather than crashing.
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
- `Dockerfile` — extends `ghcr.io/lichess-org/lila-docker:latest`;
  also copies pre-built lila-fishnet from
  `ghcr.io/lichess-org/lila-fishnet` and downloads the Stockfish
  fishnet worker binary.
- `mono.Caddyfile` — Caddy on loopback 8081 (auth_proxy occupies
  public 8080).
- `supervisord.conf` — replaces upstream's; adds openhost-init,
  lila-fishnet, fishnet-worker, and auth-proxy programs, points
  mongo at persistent dir.
- `openhost-init.sh` — first-boot init: seed copy, env file
  generation, credentials.
- `auth_proxy.py` — owner auto-login auth-proxy sidecar.
