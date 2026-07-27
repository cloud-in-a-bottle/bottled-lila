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

FROM ghcr.io/lichess-org/lila-docker:latest

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
