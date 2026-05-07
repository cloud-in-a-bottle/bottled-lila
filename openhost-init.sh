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

# A single sentinel — the presence of MongoDB's WiredTiger.wt
# storage file — is the source of truth for "this dir is a
# real, populated MongoDB data dir."  Both decisions ("should I
# copy /seeded?" and "should reset-db.sh be allowed to wipe
# this?") key off the same fact.  Earlier versions used two
# independent sentinel files which could disagree (e.g. if a
# partial restore brought back the WiredTiger files but not the
# .seeded-once flag, reset-db.sh would wipe the restored
# database).
FRESHLY_SEEDED=0
if [[ ! -f "$MONGO_DBPATH/WiredTiger.wt" ]]; then
    echo "[openhost-init] No prior MongoDB data at $MONGO_DBPATH; copying /seeded"
    mkdir -p "$MONGO_DBPATH"
    cp -a /seeded/. "$MONGO_DBPATH/"
    # Make the dir owned by whoever mongod runs as.  In the
    # upstream image mongod runs as root (no USER directive), so
    # this is a no-op; left explicit for any future image where
    # mongod drops privileges.
    chown -R "$(id -u)":"$(id -g)" "$MONGO_DBPATH" 2>/dev/null || true
    FRESHLY_SEEDED=1
else
    echo "[openhost-init] MongoDB data already present at $MONGO_DBPATH; not copying"
fi

# ----------------------------------------------------------------------
# Admin credentials
# ----------------------------------------------------------------------
# The seeded DB has the admin user's bpass set to the hash of
# whatever password lila-db-seed's spamdb.py was passed via
# --su-password.  reset-db.sh (which we run on first boot only)
# reads $LILA_USER_PASSWORD from its environment and uses that.
#
# Default behaviour:
#   * Honour an explicit LILA_ADMIN_PASSWORD env var if set —
#     the operator wants a known password.
#   * Otherwise: on FIRST boot, generate a strong random
#     password and persist it.  The operator never sees it
#     directly (auth_proxy auto-logs them in over SSO); they
#     can read it from the persistent CRED_FILE if needed for
#     manual debugging.
#   * On subsequent boots: read the persisted password back so
#     it survives container restarts.
#
# Why generate rather than use a fixed default?  Even though
# /login is only reachable via the OpenHost router (which gates
# anonymous traffic at the public-URL boundary), defense in
# depth says: don't ship a fixed default password.  If the
# OpenHost router is ever misconfigured to expose /login as
# public, every openhost-lila install would have the same
# trivially-guessable admin password.

ADMIN_USER="${LILA_ADMIN_USER:-admin}"

if [[ -n "${LILA_ADMIN_PASSWORD:-}" ]]; then
    ADMIN_PASSWORD="$LILA_ADMIN_PASSWORD"
    echo "[openhost-init] admin password sourced from LILA_ADMIN_PASSWORD env var"
elif [[ -f "$CRED_FILE" ]]; then
    # Re-read existing password from a prior boot.  Awk-extract
    # the LILA_ADMIN_PASSWORD line; tolerant of either single
    # or double quoting around the value.
    ADMIN_PASSWORD=$(
        awk -F= '
            /^[[:space:]]*(export[[:space:]]+)?LILA_ADMIN_PASSWORD[[:space:]]*=/ {
                # strip the leading KEY= part and any surrounding quotes
                sub(/^[[:space:]]*(export[[:space:]]+)?LILA_ADMIN_PASSWORD[[:space:]]*=[[:space:]]*/, "")
                gsub(/^['\''"]|['\''"]$/, "")
                print
                exit
            }
        ' "$CRED_FILE"
    )
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        echo "[openhost-init] WARNING: $CRED_FILE exists but LILA_ADMIN_PASSWORD missing or unparseable; regenerating"
        ADMIN_PASSWORD=""
    else
        echo "[openhost-init] admin password recovered from prior boot's $CRED_FILE"
    fi
fi

if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    # 32 chars of base64 = 192 bits of entropy.  /dev/urandom
    # is unconditionally available in Linux containers; tr
    # filters out characters that would need shell-quoting.
    ADMIN_PASSWORD=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)
    echo "[openhost-init] generated fresh 32-char admin password (192 bits of entropy)"
fi

# Persist for the auth_proxy to read.  Written every boot
# (idempotent if the value is unchanged).
#
# Note on rotation: changing the password after first boot
# requires updating the admin user's bpass in MongoDB too,
# because reset-db.sh runs on first boot only (it's
# destructive — passes --drop-db).  Rotation flow:
#   1. Delete $PERSIST/.seeded-once and the entire
#      $PERSIST/mongodb dir.
#   2. Set LILA_ADMIN_PASSWORD=<new> via OpenHost env vars.
#   3. Restart the app.  reset-db.sh re-runs with the new
#      password and the persistent dir is repopulated.
# This wipes user state — it's a clean reset, not a password-
# only rotation.  A surgical password change can be done via
# /account/security in Lila's web UI (auth_proxy will
# silently still log in with the OLD password until you
# update CRED_FILE on disk to match).
umask 077
cat > "$CRED_FILE" <<EOF
# auth_proxy reads this file to auto-login on owner requests.
# Format: shell-style export lines.  Mode 0600.
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
