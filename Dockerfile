# openhost-lila
#
# Lichess's Lila chess server, packaged as an OpenHost app with
# one-click SSO via Pattern B (auto-login auth-proxy sidecar).
#
# Architecture:
#
#   browser ──HTTPS──▶ OpenHost router (app is public, so anon
#                                       visitors pass through; stamps
#                                       X-OpenHost-Is-Owner on the
#                                       owner's requests)
#                  ──▶ container :8080  (auth_proxy.py)
#                          │
#                          │ owner (X-OpenHost-Is-Owner: true) without
#                          │ an authenticated lila2 session (no
#                          │ sessionId — covers missing, logged-out,
#                          │ and anonymous-guest cookies)?
#                          │  → POST /login as `admin`,
#                          │    capture Set-Cookie: lila2=...,
#                          │    302 with cookie → original URL
#                          │
#                          ▼ for everyone else, transparent forward
#                            (anon guests fall through to Lila)
#                       127.0.0.1:8081  (Caddy)
#                          │
#                          ├──▶ /socket/v6 (WebSocket Upgrade)
#                          │       → 127.0.0.1:9664  (lila-ws JVM)
#                          │
#                          └──▶ everything else
#                                 → 127.0.0.1:9663  (Lila JVM)
#                                      ↕
#                                   MongoDB :27017     (loopback)
#                                   Redis   :6379      (loopback,
#                                                       pub/sub
#                                                       between lila
#                                                       + lila-ws, and
#                                                       lila ↔
#                                                       lila-fishnet
#                                                       for AI moves)
#                                   lila-fishnet :9665 (loopback; AI
#                                                       move broker)
#                                      ↑ HTTP
#                                   fishnet worker (Stockfish; polls
#                                                   lila-fishnet)
#
# supervisord runs the openhost-init oneshot plus these
# long-running programs: mongod, redis-server, Caddy, lila-ws,
# lila, lila-fishnet, the fishnet (Stockfish) worker, and our
# auth_proxy.  The pre-existing /seeded MongoDB data dir is copied
# on first boot to the persistent volume; subsequent boots run
# mongod from the persistent path so user state survives.
#
# We extend the upstream "mono" image
# (ghcr.io/lichess-org/lila-docker:latest) — that's the SAME
# image lila-docker's `mono` profile uses for "give me a quick
# Lichess in one container."  It bundles a pre-built lila JAR,
# a pre-built lila-ws JAR, MongoDB, Redis, Caddy, and supervisord.
# Reusing it means we don't have to compile Scala (a 30+ minute
# sbt step) inside our build context.

# lila-fishnet — the Scala move-broker that lets AI/"play with the
# computer" games work.  Lila does NOT compute AI opponent moves
# itself: on an AI game it publishes a move request to Redis
# (channel "fishnet-out") and expects a fishnet client to answer.
# Its own /fishnet HTTP endpoint deliberately REFUSES move work
# ("Can't acquire a move directly on lichess!") — move work must go
# through the separate lila-fishnet service, which bridges Redis
# (fishnet-in/out) to an HTTP queue on :9665 that Stockfish workers
# poll.  We copy the pre-built app + its bundled JDK from the
# official image rather than run a 20-minute sbt build.
#
# Version pinning is load-bearing here.  The fishnet worker and
# lila-fishnet must agree on the /fishnet HTTP protocol.  fishnet
# v2.14.0 (PR #298, "remove auth from body") switched the worker to
# send its key only in an Authorization: Bearer header with no
# {"fishnet":{"version","apikey"}} body, and lila-fishnet v3.0.19
# (#625, #628) reads the key from the bearer header and stopped
# parsing it from the body.  If the two disagree, every
# /fishnet/acquire is rejected (422) and the AI opponent never moves.
# So we pin BOTH to a matching bearer-protocol pair: lila-fishnet
# v3.0.19 + fishnet worker v2.15.0.  (The previous old-protocol pair
# was lila-fishnet v3.0.18 + fishnet v2.8.1.)
FROM ghcr.io/lichess-org/lila-fishnet:3.0.19@sha256:4d646c29f5246405411aa1bfaf884b136dd1677fdcd06ccab8c88a17f9f9ec5b AS lila-fishnet

# lila-docker publishes no release tags, only branch builds (:latest is the
# main branch). Pinned by digest to the :latest build of lila-docker commit
# f1e918c9745972ddef9606c07a9d4d101f34c46d (built 2026-10-11, lila-master),
# so a new push upstream can't change what we ship. To bump, take the
# current :latest digest and update the commit here.
FROM ghcr.io/lichess-org/lila-docker:latest@sha256:df4a41084f1c71af8d7f364447819705caeefd9ff0dfd8c04c814b8781ff2fb4

# Bring in the pre-built lila-fishnet app and the JDK it ships with.
# sbt-native-packager lays the app out under /opt/docker (launcher
# at /opt/docker/bin/lila-fishnet) and the JRE under
# /opt/java/openjdk.  We install the JDK at a distinct path
# (/opt/lila-fishnet-java) so it can't collide with anything the
# mono image already has, and point the launcher at it via
# JAVA_HOME in supervisord.
COPY --from=lila-fishnet /opt/docker /opt/lila-fishnet
COPY --from=lila-fishnet /opt/java/openjdk /opt/lila-fishnet-java

# fishnet — the Stockfish worker that actually computes the moves.
# Static x86_64 musl binary from the upstream release; no runtime
# deps.  Pinned to v2.15.0, which speaks the bearer-header
# /fishnet protocol that the lila-fishnet v3.0.19 image above expects
# (see the version-pinning note on the lila-fishnet stage).  In lila's
# offline_mode (base.conf: fishnet.offline_mode = true) any client may
# serve moves without a registered key.
# Upstream publishes no checksums file; the sha256 is of the GitHub
# release asset, which is identical to the S3 mirror linked from the
# release notes. Bump it with the version.
ARG FISHNET_VERSION=v2.15.0
ARG FISHNET_SHA256=9e17dbeb2e146b30be8d801864c265af419477fdabf8ea4d983e4aa498afbde4
RUN curl -fsSL -o /usr/local/bin/fishnet \
      "https://github.com/lichess-org/fishnet/releases/download/${FISHNET_VERSION}/fishnet-x86_64-unknown-linux-musl" \
 && echo "${FISHNET_SHA256}  /usr/local/bin/fishnet" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/fishnet \
 && /usr/local/bin/fishnet --version

# Override the upstream mono.Caddyfile with one that listens on
# loopback :8081 instead of :8080, so our auth_proxy can sit in
# front on :8080 (which is what OpenHost routes the public URL
# to).
COPY mono.Caddyfile /mono.Caddyfile

# Replace the upstream supervisord config with one that:
#  1. Runs the openhost-init oneshot first (copies /seeded →
#     persistent dir, generates admin credentials).
#  2. Runs MongoDB pointed at the persistent dir.
#  3. Runs Redis with appendonly persistence to the persistent dir.
#  4. Runs Caddy on loopback 8081.
#  5. Runs lila-ws and lila as before.
#  6. Runs lila-fishnet on loopback 9665 and the fishnet (Stockfish)
#     worker that polls it, so AI / "play with the computer" games
#     get opponent moves.
#  7. Runs the auth-proxy on 0.0.0.0:8080.
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Our scripts.  All committed mode-0755 in the git index so we
# don't need RUN chmod here; defense-in-depth chmod anyway in
# case some buildkit pulls them mode-0644.
COPY auth_proxy.py /opt/openhost-lila/auth_proxy.py
COPY openhost-init.sh /opt/openhost-lila/openhost-init.sh
# source-env.sh is sourced by every long-running supervisord child
# (mongo, redis, caddy, lila-ws, lila, lila-fishnet, auth-proxy).  It
# waits for openhost-init to write /etc/environment-openhost-lila
# before continuing, so a child never starts with the image's
# baked-in placeholder env (e.g. LILA_URL=http://localhost:8080),
# which would poison lila-ws's Origin/CSRF check and hang the client
# on "Reconnecting…".
COPY source-env.sh /opt/openhost-lila/source-env.sh
RUN mkdir -p /opt/openhost-lila \
 && chmod 0755 /opt/openhost-lila/openhost-init.sh \
 && chmod 0644 /opt/openhost-lila/source-env.sh

# OpenHost env contract: $OPENHOST_APP_DATA_DIR is the persistent
# dir, $OPENHOST_APP_NAME is "lila", $OPENHOST_ZONE_DOMAIN is the
# parent zone hostname.  We don't bake any of these into ENV
# because they're set at container start by OpenHost.
#
# But: Lila reads LILA_DOMAIN / LILA_URL at startup (used to
# build absolute URLs and check Origin headers).  We compute
# them in openhost-init.sh from the OpenHost env vars and write
# them to /etc/environment-openhost-lila so supervisord's child
# programs pick them up.

EXPOSE 8080
