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
#                                                       between
#                                                       lila + lila-ws)
#
# The five long-running services (Caddy, mongod, redis-server,
# lila-ws, lila) are supervised by the base image's supervisord;
# we add the auth_proxy as a sixth program.  The pre-existing
# /seeded MongoDB data dir is copied on first boot to the
# persistent volume; subsequent boots run mongod from the
# persistent path so user state survives.
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
FROM ghcr.io/lichess-org/lila-fishnet:latest AS lila-fishnet

FROM ghcr.io/lichess-org/lila-docker:latest

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
# deps.  Pinned to a specific version for reproducibility.  In
# lila's offline_mode (base.conf: fishnet.offline_mode = true) any
# client may serve moves without a registered key.
ARG FISHNET_VERSION=v2.14.0
ARG FISHNET_SHA256=""
RUN curl -fsSL -o /usr/local/bin/fishnet \
      "https://github.com/lichess-org/fishnet/releases/download/${FISHNET_VERSION}/fishnet-x86_64-unknown-linux-musl" \
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
#  6. Runs the auth-proxy on 0.0.0.0:8080.
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Our scripts.  All committed mode-0755 in the git index so we
# don't need RUN chmod here; defense-in-depth chmod anyway in
# case some buildkit pulls them mode-0644.
COPY auth_proxy.py /opt/openhost-lila/auth_proxy.py
COPY openhost-init.sh /opt/openhost-lila/openhost-init.sh
RUN chmod 0755 /opt/openhost-lila/openhost-init.sh \
 && mkdir -p /opt/openhost-lila

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
