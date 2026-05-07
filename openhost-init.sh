#!/bin/bash
# openhost-lila init oneshot.
#
# Runs once per container start, before any other supervisord
# program.  Three jobs:
#
#   1. Compute LILA_URL / LILA_DOMAIN from the OpenHost env vars
#      and write them to /etc/environment-openhost-lila (a
#      KEY=VALUE file sourced by every other supervisord-child's
#      command).
#
#   2. On first boot only: copy the image's pre-baked /seeded
#      MongoDB data dir → $OPENHOST_APP_DATA_DIR/mongodb so the
#      lila tournaments / users / openings collections are
#      pre-populated.  Subsequent boots use the persistent dir
#      verbatim.
#
#   3. Generate (or read) an admin password and write it to
#      $OPENHOST_APP_DATA_DIR/admin-credentials.txt for the
#      auth_proxy to consume.  The seeded DB ships with the
#      admin user's bpass already set to a known value (the hash
#      of "password"), and the seeded user IDs are deterministic.
#
# We're explicit about every path because supervisord's
# ${ENV_FOO} substitution doesn't support defaults; the env-file
# we write here is the source of truth for every downstream
# program.

set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/lila}"
APP_NAME="${OPENHOST_APP_NAME:-lila}"
ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-localhost}"

MONGO_DBPATH="$PERSIST/mongodb"
REDIS_DIR="$PERSIST/redis"
CRED_FILE="$PERSIST/admin-credentials.txt"
ENV_FILE=/etc/environment-openhost-lila

mkdir -p "$PERSIST" "$REDIS_DIR"

# ----------------------------------------------------------------------
# LILA_URL / LILA_DOMAIN
# ----------------------------------------------------------------------
# Lila uses these for absolute-URL rendering (in HTML pages, in
# emails, in mobile-app share-links) and for Origin enforcement
# on /login and /api endpoints.  Pin them to the public subdomain
# so the OpenHost router's forwarded Host header matches what
# Lila expects.

LILA_DOMAIN="${APP_NAME}.${ZONE_DOMAIN}"
LILA_URL="https://${LILA_DOMAIN}"

# ----------------------------------------------------------------------
# Seed migration on first boot
# ----------------------------------------------------------------------
# The /seeded dir is what the upstream image bakes (lila-docker's
# `dbbuilder` stage runs spamdb to populate ~300 sample users
# plus admin, lichess, ai, etc.  See
# https://github.com/lichess-org/lila-db-seed for details).  We
# copy it into the persistent volume on first boot so the
# tournaments and lobby aren't empty for the operator.
#
# Detection: presence of mongo's WiredTiger storage file marks
# "already migrated".  WiredTiger creates `WiredTiger.wt` in the
# data dir on every successful mongod startup, so its absence
# is a reliable "this is a fresh dir" signal.
#
# Idempotency: if the persistent dir is missing or empty we
# always re-seed; if it already has WiredTiger data we leave it
# alone.  reset-db.sh runs unconditionally on every boot too —
# it's a separate seeding pass that re-applies user and content
# fixtures on top of whatever's there, but it's idempotent and
# skips users that already exist.

if [[ ! -f "$MONGO_DBPATH/WiredTiger.wt" ]]; then
    echo "[openhost-init] No prior MongoDB data at $MONGO_DBPATH; copying /seeded"
    mkdir -p "$MONGO_DBPATH"
    cp -a /seeded/. "$MONGO_DBPATH/"
    # Make the dir owned by whoever mongod runs as.  In the
    # upstream image mongod runs as root (no USER directive), so
    # this is a no-op; left explicit for any future image where
    # mongod drops privileges.
    chown -R "$(id -u)":"$(id -g)" "$MONGO_DBPATH" 2>/dev/null || true
else
    echo "[openhost-init] MongoDB data already present at $MONGO_DBPATH; not copying"
fi

# Also flag /seeded as "already used" so reset-db.sh can be run
# safely against the persistent dir without it re-seeding from
# scratch (which would wipe operator state).  We do this by
# touching a sentinel file inside the persistent dir; the lila
# program in supervisord conditionally runs reset-db.sh based on
# the absence of this file.
SEED_SENTINEL="$PERSIST/.seeded-once"
FRESHLY_SEEDED=0
if [[ ! -f "$SEED_SENTINEL" ]]; then
    FRESHLY_SEEDED=1
    touch "$SEED_SENTINEL"
fi

# ----------------------------------------------------------------------
# Admin credentials
# ----------------------------------------------------------------------
# The seeded DB has the admin user's bpass set to the hash of
# "password" by default (lila-db-seed/spamdb.py defaults
# --su-password to "password" when LILA_USER_PASSWORD is unset).
# We persist that information here for the auth_proxy.  We also
# set LILA_USER_PASSWORD ahead of supervisord starting reset-db.sh
# so the seeded password doesn't drift between the two scripts.
#
# Why "password" rather than something stronger?  Inside the
# container only the auth_proxy talks to /login, and the
# OpenHost router gates anonymous access at the public-URL
# boundary.  An attacker who can reach loopback /login has
# already broken the container.  This is a defense-in-depth
# secret, not a real one.  Operators who care about the secret
# anyway can override LILA_ADMIN_PASSWORD via the OpenHost env
# customization mechanism — both the seeding step and the
# auth_proxy will pick it up.

ADMIN_USER="${LILA_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${LILA_ADMIN_PASSWORD:-password}"

# Persist for the auth_proxy to read.  Written defensively:
# rebuild on every boot in case the operator rotated
# LILA_ADMIN_PASSWORD between restarts.
umask 077
cat > "$CRED_FILE" <<EOF
# auth_proxy reads this file to auto-login on owner requests.
# Format: shell-style export lines.
export LILA_ADMIN_USER='$ADMIN_USER'
export LILA_ADMIN_PASSWORD='$ADMIN_PASSWORD'
EOF
umask 022

# ----------------------------------------------------------------------
# Write the env-file every other supervisord program sources.
# ----------------------------------------------------------------------

cat > "$ENV_FILE" <<EOF
# Generated by /opt/openhost-lila/openhost-init.sh.
# Sourced by every supervisord program's bash command.  Do not
# edit by hand; restart the app to regenerate.
export LILA_DOMAIN='$LILA_DOMAIN'
export LILA_URL='$LILA_URL'
export LILA_SITE_NAME='lichess (openhost)'
export LILA_ADMIN_USER='$ADMIN_USER'
export LILA_ADMIN_PASSWORD='$ADMIN_PASSWORD'
export LILA_USER_PASSWORD='$ADMIN_PASSWORD'
export OPENHOST_LILA_MONGO_DBPATH='$MONGO_DBPATH'
export OPENHOST_LILA_REDIS_DIR='$REDIS_DIR'
export OPENHOST_LILA_FRESHLY_SEEDED='$FRESHLY_SEEDED'
export OPENHOST_LILA_CRED_FILE='$CRED_FILE'
EOF
chmod 0644 "$ENV_FILE"

echo "[openhost-init] LILA_DOMAIN=$LILA_DOMAIN"
echo "[openhost-init] LILA_URL=$LILA_URL"
echo "[openhost-init] mongodb dbpath=$MONGO_DBPATH"
echo "[openhost-init] redis dir=$REDIS_DIR"
echo "[openhost-init] freshly seeded=$FRESHLY_SEEDED"
echo "[openhost-init] cred file=$CRED_FILE"
echo "[openhost-init] done"
