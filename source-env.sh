# shellcheck shell=bash
# source-env.sh — robust loader for /etc/environment-openhost-lila.
#
# Every long-running supervisord child (mongo, redis, caddy,
# lila-ws, lila) needs the environment openhost-init computes at
# boot (LILA_URL, LILA_DOMAIN, the MongoDB / Redis persistent
# paths, the admin creds).  openhost-init writes that to
# /etc/environment-openhost-lila, but supervisord does NOT enforce
# ordering between the oneshot init and the long-running programs
# beyond a soft `priority` hint — a child can be spawned before the
# file exists.
#
# The naive prelude
#
#     bash -c '. /etc/environment-openhost-lila && <cmd>; <more>'
#
# has TWO failure modes when the file is missing at spawn:
#
#   1. `.` on a missing file returns non-zero, so the `&&` guard
#      stops at the FIRST following statement — but any subsequent
#      `;`-separated statements STILL run, now with whatever the
#      variables happened to inherit from the container image's own
#      ENV.  The upstream lila-docker image bakes
#      `LILA_URL=http://localhost:8080`, so lila-ws would come up
#      with `-Dcsrf.origin=http://localhost:8080` instead of the
#      real public origin.  lila-ws does an EXACT-string Origin
#      check on the WebSocket handshake, so every /socket
#      connection is then rejected with 403 and the client is stuck
#      on "Reconnecting…" — even though lila-ws looks healthy to
#      supervisord.  This is silent and sticky: it never self-heals
#      until lila-ws happens to restart after the file appears.
#
#   2. Even a correct single `&&` chain just crashes the child once
#      and relies on autorestart racing the oneshot — noisy, and a
#      hard-coded `sleep` is a guess.
#
# So instead we WAIT (bounded) for the file to appear, then source
# it, then fail loud if it never shows.  Callers do:
#
#     bash -c 'set -a; . /opt/openhost-lila/source-env.sh; set +a; exec <cmd>'
#
# `set -a` (before) exports everything the env file defines so it
# propagates to the exec'd program; the sourced file's own `export`
# statements make this belt-and-suspenders.

_openhost_lila_env_file="${OPENHOST_LILA_ENV_FILE:-/etc/environment-openhost-lila}"

# Wait up to ~60s (120 * 0.5s) for openhost-init to write the file.
# openhost-init is a fast oneshot (its slow step, the first-boot
# /seeded copy, still completes well inside this window on the
# OpenHost-managed volume); 60s is comfortable headroom without
# hanging a genuinely-broken boot forever.
_openhost_lila_waited=0
while [ ! -f "$_openhost_lila_env_file" ]; do
	if [ "$_openhost_lila_waited" -ge 120 ]; then
		echo "[source-env] FATAL: $_openhost_lila_env_file did not appear after ~60s; openhost-init must run first" >&2
		exit 1
	fi
	sleep 0.5
	_openhost_lila_waited=$((_openhost_lila_waited + 1))
done

# shellcheck source=/dev/null
. "$_openhost_lila_env_file"

# Fail loud rather than silently running with the image's baked-in
# placeholders.  openhost-init writes this file atomically, so seeing it at
# all should mean seeing it complete; this is the backstop that turns any
# future regression into an obvious crash-loop instead of a site that answers
# 301 to http://localhost:8080/ and rejects every WebSocket handshake.
#
# Match the placeholder precisely.  A bare *localhost* glob would also reject
# a legitimate zone domain that merely contains the string, e.g.
# https://lila.localhost.example.com.
case "${LILA_URL:-}" in
	"" | "http://localhost" | "http://localhost:"* | "https://localhost" | "https://localhost:"*)
		echo "[source-env] FATAL: LILA_URL is '${LILA_URL:-<unset>}' after sourcing $_openhost_lila_env_file; refusing to start with the image's placeholder origin" >&2
		exit 1
		;;
esac
