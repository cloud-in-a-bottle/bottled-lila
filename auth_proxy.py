"""OpenHost auto-login auth-proxy for Lila.

Sits between the OpenHost router and Caddy (which fronts Lila +
lila-ws).  When the authenticated zone owner visits Lila's web UI
for the first time on a device, this proxy logs them in to Lila
automatically using the on-disk admin username + password and sets
the resulting ``lila2`` cookie on the browser.  After the cookie
is set, the proxy is a near-pass-through; subsequent requests
carry the cookie and Lila treats them as a normal authenticated
session.

Pattern B (from the OpenHost SSO playbook): the OpenHost router
verifies the visitor's zone_auth JWT and stamps
``X-OpenHost-Is-Owner: true`` on requests where the visitor is
the owner of the zone.  We use that header as the trigger to
mint an in-app session by calling Lila's own ``POST /login``
endpoint.

Auth model summary:

  * Anonymous on a path the OpenHost router gates → router 302's
    to the OpenHost SSO before the request reaches us.  We never
    see anonymous traffic except on the public_paths declared in
    openhost.toml: /healthz, /login, /socket/, /assets/,
    /api/socket.

  * Owner with a Lila ``lila2`` cookie → forward unchanged.

  * Owner without a Lila ``lila2`` cookie → POST to Lila's
    /login with admin credentials, capture the Set-Cookie,
    issue a 302 to the same path with the cookie set.  We only
    do this on top-level HTML navigations (Accept: text/html)
    so XHR / asset fetches don't get caught in a redirect loop
    while the session is being established.

  * /healthz → answered locally by the proxy (200 ``ok``);
    NEVER forwarded to Caddy, because Caddy's upstream Lila
    can take 60-120s to fully boot and we don't want OpenHost's
    healthcheck to flap during cold start.

  * WebSocket upgrades on /socket/ → forward unchanged.  Lila's
    desktop / mobile clients open a WS here for live game
    updates; bypassing the auto-login dance avoids a redirect
    during the WS handshake (which the WS client can't follow).

  * /api/* → forward unchanged.  Lila's API surface uses bearer
    tokens (OAuth2) for auth, not session cookies; the auto-
    login dance would clobber the bearer header.

Defense in depth: ALWAYS strip any client-supplied
``X-OpenHost-Is-Owner`` / ``X-OpenHost-User`` before forwarding
upstream.  The OpenHost router stamps the real value fresh on
every request, so any pre-existing instance of those headers
came from the client and is not to be trusted.

Implementation is adapted from openhost-joplin/auth_proxy.py
(also Pattern B, also a Set-Cookie capture + 302 dance).
"""

from __future__ import annotations

import http.client
import logging
import os
import re
import socket
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import AbstractSet, Iterable

OWNER_HEADER_NAME = "X-OpenHost-Is-Owner"
USER_HEADER_NAME = "X-OpenHost-User"
LILA_SESSION_COOKIE = "lila2"

# Hop-by-hop headers (RFC 9110 §7.6.1) plus the framing headers
# we rebuild ourselves at the proxy seam.
HOP_BY_HOP_HEADERS = frozenset(
    h.lower()
    for h in (
        "Connection",
        "Keep-Alive",
        "Proxy-Authenticate",
        "Proxy-Authorization",
        "TE",
        "Trailer",
        "Transfer-Encoding",
        "Upgrade",
        "Host",
        "Content-Length",
    )
)

# Trust headers a hostile client could try to forge.  Always
# stripped from inbound requests, even though the OpenHost
# router also strips client-supplied versions before stamping
# its own.
ALWAYS_STRIP_HEADERS = frozenset(
    h.lower() for h in (OWNER_HEADER_NAME, USER_HEADER_NAME)
)

CLIENT_READ_TIMEOUT_SECONDS = 60

# 32 MiB body cap.  Lila pushes JSON game-state updates and PGN
# uploads through; default Play body cap is 100 KiB but Lila
# raises it to several MiB for the analysis upload endpoint.
# 32 MiB is plenty.
MAX_BODY_BYTES = 32 * 1024 * 1024

# Lila's login endpoint.
LILA_LOGIN_PATH = "/login"

# Paths we never inject auto-login on (forwarded verbatim,
# regardless of owner status).  Lila's /api/* uses OAuth2 bearer
# tokens, /socket/* is a WebSocket upgrade, and /assets/* is
# Caddy-served static content that's identical for every visitor
# anyway.  /login itself is excluded too — visiting /login means
# the user explicitly wants the manual form, e.g. to log in as
# a non-admin user, and intercepting it would be a UX trap.
NO_AUTO_LOGIN_PREFIXES = (
    "/api/",
    "/socket/",
    "/assets/",
    "/login",
    "/logout",
    "/healthz",
)

# Health endpoint: answered locally, never forwarded.  Lila's
# JVM cold-start takes 60-120s; the OpenHost router's
# healthcheck would flap if we forwarded.  Returning 200 ``ok``
# from the proxy means OpenHost considers the container alive
# the moment auth_proxy itself binds — same pattern openhost-
# joplin and openhost-bookstack use.
HEALTH_PATH = "/healthz"

logging.basicConfig(
    level=os.environ.get("AUTH_PROXY_LOG_LEVEL", "INFO"),
    format="[auth-proxy] %(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("auth_proxy")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _parse_cookie_header(cookie_header: str | None) -> dict[str, str]:
    """Parse an RFC 6265 Cookie header into a {name: value} dict.

    First-value-wins semantics for duplicate cookie names —
    matches browser ordering and prevents trivial duplicate-
    cookie DoS.
    """
    if not cookie_header:
        return {}
    result: dict[str, str] = {}
    for part in cookie_header.split(";"):
        if "=" not in part:
            continue
        name, value = part.split("=", 1)
        result.setdefault(name.strip(), value.strip())
    return result


def _strip_headers(
    headers: Iterable[tuple[str, str]], drop: AbstractSet[str]
) -> list[tuple[str, str]]:
    drop_lower = {h.lower() for h in drop}
    return [(k, v) for k, v in headers if k.lower() not in drop_lower]


def _read_admin_creds(cred_file: str) -> tuple[str, str] | None:
    """Read LILA_ADMIN_USER / LILA_ADMIN_PASSWORD from
    openhost-init.sh's on-disk credentials file.

    Format: ``export NAME='VALUE'`` per line.  Re-parsed on every
    auto-login attempt so an operator who rotates the
    credentials (delete the file, restart, let openhost-init
    regenerate) doesn't need a separate sidecar restart.
    """
    try:
        with open(cred_file, encoding="utf-8") as fh:
            content = fh.read()
    except FileNotFoundError:
        return None
    user = password = None
    for line in content.splitlines():
        m = re.match(
            r"^\s*(?:export\s+)?(LILA_ADMIN_USER|LILA_ADMIN_PASSWORD)\s*=\s*(.*?)\s*$",
            line,
        )
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key == "LILA_ADMIN_USER":
            user = val
        elif key == "LILA_ADMIN_PASSWORD":
            password = val
    if user and password:
        return user, password
    return None


def _login_to_lila(
    upstream_host: str,
    upstream_port: int,
    username: str,
    password: str,
    forwarded_host: str,
) -> list[str] | None:
    """POST credentials to Lila's /login (via Caddy, which routes
    on path) and return the Set-Cookie header value (the entire
    ``lila2=...; HttpOnly; ...`` string, suitable for echoing on
    a 302 response back to the browser).

    Returns None on any failure — auto-login is best-effort; on
    failure the proxy falls through to a normal forward and the
    visitor sees Lila's own login form.  This preserves the
    worst-case UX (manual login) when something is misconfigured
    upstream rather than locking the operator out.

    ``forwarded_host`` becomes the Host header on the upstream
    request — Lila's Origin check on /login requires the public
    domain.  Falls back to ``upstream_host:upstream_port`` for
    direct-loopback diagnostic calls (which won't pass Origin
    validation but produce a clear error in logs).
    """
    payload = urllib.parse.urlencode({
        "username": username,
        "password": password,
    }).encode("utf-8")
    host_header = forwarded_host or f"{upstream_host}:{upstream_port}"
    try:
        conn = http.client.HTTPConnection(upstream_host, upstream_port, timeout=15)
        # Lila's /login responds with a 303 to /lobby on success
        # for browser sessions, or 200 with a JSON body for XHR.
        # We treat any 2xx/3xx with a Set-Cookie: lila2=... as
        # success.
        conn.request(
            "POST",
            LILA_LOGIN_PATH,
            body=payload,
            headers={
                "Host": host_header,
                "Origin": f"https://{host_header}",
                "Content-Type": "application/x-www-form-urlencoded",
                "Content-Length": str(len(payload)),
                # Lila returns plain HTML on the login form for
                # text/html Accept, and JSON for application/json.
                # We want the redirect / cookie path, which goes
                # via text/html.
                "Accept": "text/html,application/xhtml+xml",
                # Lila looks at User-Agent for some bot-detection
                # paths.  A vanilla curl-like UA is fine; the
                # Firewall middleware doesn't block based on UA
                # alone, only IP-reputation.
                "User-Agent": "openhost-lila-auth-proxy/0.1",
            },
        )
        resp = conn.getresponse()
        try:
            resp.read()
        except (OSError, http.client.HTTPException):
            pass
    except (OSError, http.client.HTTPException) as exc:
        log.warning("auto-login: upstream POST %s failed: %s", LILA_LOGIN_PATH, exc)
        return None
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass

    # Accept any 2xx or 3xx — Lila's /login returns 303 on
    # success for HTML accepts but 200 with sessionId in JSON
    # for XHR; we don't inspect the body.
    if not (200 <= resp.status < 400):
        log.warning(
            "auto-login: Lila returned status %d to login attempt "
            "(expected 2xx/3xx on success)",
            resp.status,
        )
        return None

    # Lila's Set-Cookie header value contains the lila2 session
    # cookie.  When multiple cookies are set in one response Play
    # uses comma-separation in a single Set-Cookie header (see
    # play.api.mvc.Cookie); use getheaders + multi-value join to
    # capture all of them, since Lila also sets a few helper
    # cookies (ai-rating, sound-set) on login that we want to
    # echo back.
    set_cookies = resp.getheaders()
    cookie_lines = [v for k, v in set_cookies if k.lower() == "set-cookie"]
    # Verify lila2 is among them.
    joined = "; ".join(cookie_lines)
    if LILA_SESSION_COOKIE not in joined:
        log.warning(
            "auto-login: Lila response had no %s cookie; "
            "got headers: %s",
            LILA_SESSION_COOKIE,
            cookie_lines,
        )
        return None
    return cookie_lines


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------


class AuthProxyHandler(BaseHTTPRequestHandler):
    upstream_host: str = "127.0.0.1"
    upstream_port: int = 8081
    cred_file: str = "/data/app_data/lila/admin-credentials.txt"

    def log_message(self, format: str, *args) -> None:  # noqa: A002, N802
        log.info("%s - " + format, self.address_string(), *args)

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch()

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch()

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch()

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch()

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch()

    def do_PATCH(self) -> None:  # noqa: N802
        self._dispatch()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._dispatch()

    def _safe_send_error(self, code: int, message: str) -> None:
        try:
            self.send_error(code, message)
        except OSError as exc:
            log.debug("client disconnected before error response: %s", exc)

    def _dispatch(self) -> None:
        try:
            self.connection.settimeout(CLIENT_READ_TIMEOUT_SECONDS)
        except OSError:
            pass

        # Health endpoint: answer locally, NEVER touch upstream.
        # Lila's JVM cold-start takes minutes; this lets OpenHost's
        # readiness probe flip to "alive" the moment auth_proxy
        # binds, avoiding the cold-start 5xx flap pattern called
        # out in the spec.
        if self.path == HEALTH_PATH or self.path.startswith(HEALTH_PATH + "?"):
            self._serve_health()
            return

        # WebSocket upgrade.  Forward verbatim — the auth dance
        # would 302 the client, which it can't follow during a
        # WS handshake, and Lila's WS auth uses the lila2 cookie
        # (already set on the browser by then) anyway.
        upgrade = self.headers.get("Upgrade", "").lower().strip()
        if upgrade == "websocket":
            self._proxy_websocket()
            return

        # Paths that bypass the auto-login dance.
        for prefix in NO_AUTO_LOGIN_PREFIXES:
            if self.path.startswith(prefix):
                self._proxy()
                return

        is_owner = self.headers.get(OWNER_HEADER_NAME, "").lower() == "true"
        cookies = _parse_cookie_header(self.headers.get("Cookie"))
        has_lila_session = LILA_SESSION_COOKIE in cookies

        accept = self.headers.get("Accept", "")
        is_html_navigation = (
            self.command == "GET" and "text/html" in accept.lower()
        )

        if is_owner and not has_lila_session and is_html_navigation:
            if self._maybe_auto_login():
                return

        self._proxy()

    def _serve_health(self) -> None:
        body = b"ok\n"
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except OSError as exc:
            log.debug("client disconnected during health response: %s", exc)

    def _maybe_auto_login(self) -> bool:
        """Attempt to auto-login to Lila and 302 with the cookie set.

        Returns True on success, False otherwise.  On False the
        caller falls through to a normal request forward — the
        user sees Lila's own login form, the worst-case UX.
        """
        creds = _read_admin_creds(self.cred_file)
        if creds is None:
            log.warning(
                "auto-login: credentials file missing or unreadable at %s; "
                "falling through to manual login",
                self.cred_file,
            )
            return False

        username, password = creds
        forwarded_host = self.headers.get("X-Forwarded-Host", "").strip()
        cookie_lines = _login_to_lila(
            self.upstream_host,
            self.upstream_port,
            username,
            password,
            forwarded_host,
        )
        if cookie_lines is None:
            return False
        # _login_to_lila returns the list of Set-Cookie header
        # values directly so we can echo each back on its own
        # Set-Cookie line (browsers handle multi-Set-Cookie
        # correctly; combining them into one header is RFC-
        # ambiguous).

        target_path = self.path or "/"
        parsed = urllib.parse.urlparse(target_path)
        if parsed.scheme or parsed.netloc:
            target_path = "/"

        try:
            self.send_response(302)
            self.send_header("Location", target_path)
            for cookie_line in cookie_lines:
                self.send_header("Set-Cookie", cookie_line)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
        except OSError as exc:
            log.debug("client disconnected during auto-login redirect: %s", exc)
            return False

        log.info(
            "auto-login: minted Lila session for %s; redirected to %s",
            username,
            target_path,
        )
        return True

    def _proxy_websocket(self) -> None:
        """Tunnel a WebSocket upgrade through to Caddy.

        Caddy's reverse_proxy handles the actual lila-ws side;
        we just need to copy bytes in both directions after the
        upgrade.  We don't try to inspect or rewrite the WS
        framing — Lila's WS protocol is binary and version-
        sensitive.
        """
        cleaned_headers = _strip_headers(
            self.headers.items(),
            ALWAYS_STRIP_HEADERS,
        )
        # Don't strip Connection / Upgrade / Sec-WebSocket-* —
        # those are the WS handshake.

        try:
            up = socket.create_connection(
                (self.upstream_host, self.upstream_port), timeout=15
            )
        except OSError as exc:
            log.warning("ws: upstream connect failed: %s", exc)
            self._safe_send_error(502, "Bad Gateway")
            return

        try:
            # Reconstruct the request line + headers.
            request = f"{self.command} {self.path} HTTP/1.1\r\n"
            for k, v in cleaned_headers:
                request += f"{k}: {v}\r\n"
            request += "\r\n"
            up.sendall(request.encode("latin-1"))

            # Read the upstream response headers + 101 line, copy
            # to the client.  Then swap to bidirectional copy.
            up_file = up.makefile("rb")
            status_line = up_file.readline()
            if not status_line:
                self._safe_send_error(502, "Bad Gateway")
                return
            try:
                self.wfile.write(status_line)
            except OSError:
                return

            while True:
                line = up_file.readline()
                if not line:
                    return
                try:
                    self.wfile.write(line)
                except OSError:
                    return
                if line in (b"\r\n", b"\n"):
                    break

            # Bidirectional bytes copy.  Spawn one socket→socket
            # thread for each direction.
            import threading

            def _copy(src, dst):
                try:
                    while True:
                        data = src.recv(65536)
                        if not data:
                            break
                        dst.sendall(data)
                except OSError:
                    pass

            t1 = threading.Thread(
                target=_copy, args=(self.connection, up), daemon=True
            )
            t2 = threading.Thread(
                target=_copy, args=(up, self.connection), daemon=True
            )
            t1.start()
            t2.start()
            t1.join()
            t2.join()
        finally:
            try:
                up.close()
            except OSError:
                pass

    def _proxy(self) -> None:
        cleaned_headers = _strip_headers(
            self.headers.items(),
            HOP_BY_HOP_HEADERS | ALWAYS_STRIP_HEADERS,
        )
        forwarded_host = self.headers.get("X-Forwarded-Host", "").strip()
        if forwarded_host:
            # Caddy / Lila enforce Origin against the public URL;
            # rewrite Host to match before forwarding.
            cleaned_headers.append(("Host", forwarded_host))

        transfer_encoding = self.headers.get("Transfer-Encoding", "").lower().strip()
        if transfer_encoding and transfer_encoding != "identity":
            self._safe_send_error(501, "Transfer-Encoding not supported")
            return

        body: bytes | None = None
        content_length_header = self.headers.get("Content-Length")
        if content_length_header:
            try:
                length = int(content_length_header)
            except ValueError:
                self._safe_send_error(400, "invalid Content-Length")
                return
            if length < 0:
                self._safe_send_error(400, "negative Content-Length")
                return
            if length > MAX_BODY_BYTES:
                self._safe_send_error(413, "request body too large")
                return
            if length > 0:
                try:
                    body = self.rfile.read(length)
                except (OSError, TimeoutError) as exc:
                    log.info("client read error: %s", exc)
                    self._safe_send_error(400, "request body read failed")
                    return
                if len(body) != length:
                    log.info(
                        "short read: expected %d bytes, got %d",
                        length,
                        len(body),
                    )
                    self._safe_send_error(400, "incomplete request body")
                    return
            else:
                body = b""
        elif self.command in ("POST", "PUT", "PATCH", "DELETE"):
            body = b""

        conn = http.client.HTTPConnection(
            self.upstream_host, self.upstream_port, timeout=120
        )
        try:
            try:
                conn.putrequest(
                    self.command,
                    self.path,
                    skip_host=True,
                    skip_accept_encoding=True,
                )
                for key, value in cleaned_headers:
                    conn.putheader(key, value)
                if body is not None:
                    conn.putheader("Content-Length", str(len(body)))
                conn.endheaders(message_body=body)
                upstream = conn.getresponse()
            except (OSError, http.client.HTTPException) as exc:
                log.warning("upstream error: %s", exc)
                self._serve_cold_start_placeholder()
                return

            try:
                payload = upstream.read(MAX_BODY_BYTES + 1)
            except (OSError, http.client.HTTPException) as exc:
                log.warning("upstream read error: %s", exc)
                self._serve_cold_start_placeholder()
                try:
                    upstream.close()
                except Exception as close_exc:  # noqa: BLE001
                    log.debug("upstream.close() raised: %s", close_exc)
                return
            try:
                upstream.close()
            except Exception as exc:  # noqa: BLE001
                log.debug("upstream.close() raised (ignored): %s", exc)
            if len(payload) > MAX_BODY_BYTES:
                log.warning(
                    "upstream response exceeded %d bytes; returning 502",
                    MAX_BODY_BYTES,
                )
                self._safe_send_error(502, "upstream response too large")
                return

            # 5xx-during-cold-start: Caddy returns 502 while Lila
            # is still booting.  Replace with a friendlier
            # auto-refreshing placeholder so the operator's
            # browser doesn't render a raw 502 page.  Asset and
            # XHR responses fall through unchanged so the noVNC-
            # equivalent (the SPA shell) eventually works.
            if (
                500 <= upstream.status < 600
                and self.command == "GET"
                and "text/html" in self.headers.get("Accept", "").lower()
            ):
                self._serve_cold_start_placeholder()
                return

            reason = upstream.reason or ""
            try:
                self.send_response(upstream.status, reason)
                for key, value in upstream.getheaders():
                    if key.lower() in HOP_BY_HOP_HEADERS:
                        continue
                    self.send_header(key, value)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(payload)
            except OSError as exc:
                log.debug("client disconnected mid-response: %s", exc)
        finally:
            conn.close()

    def _serve_cold_start_placeholder(self) -> None:
        """During cold start (Lila's JVM is still warming up),
        return an auto-refreshing HTML page rather than letting
        the browser render Caddy's raw 502.  Pattern called out
        in the OpenHost playbook for slow-starting JVM apps.
        """
        body = (
            b"<!doctype html>"
            b"<html><head><title>Lichess starting...</title>"
            b'<meta http-equiv="refresh" content="3">'
            b"</head>"
            b'<body style="background:#161512;color:#bababa;'
            b'font-family:sans-serif;padding:2em">'
            b"<h1>Lichess is starting up...</h1>"
            b"<p>The Lila JVM takes 60-120 seconds to fully boot "
            b"on the first request after a container restart.  This "
            b"page refreshes every 3 seconds; you'll be in shortly.</p>"
            b"</body></html>"
        )
        try:
            self.send_response(503)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Retry-After", "3")
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except OSError as exc:
            log.debug("client disconnected during cold-start placeholder: %s", exc)


class IPv4ThreadingServer(ThreadingHTTPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True
    daemon_threads = True


def _port_from_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        port = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name}={raw!r} is not an integer: {exc}") from exc
    if not 1 <= port <= 65535:
        raise ValueError(f"{name}={raw!r} is out of range (1-65535)")
    return port


def main() -> int:
    try:
        listen_port = _port_from_env("AUTH_PROXY_LISTEN_PORT", 8080)
        upstream_port = _port_from_env("AUTH_PROXY_UPSTREAM_PORT", 8081)
    except ValueError as exc:
        log.error("invalid port configuration: %s", exc)
        return 1

    upstream_host = os.environ.get("AUTH_PROXY_UPSTREAM_HOST", "127.0.0.1").strip()
    cred_file = os.environ.get(
        "OPENHOST_LILA_CRED_FILE",
        "/data/app_data/lila/admin-credentials.txt",
    )

    AuthProxyHandler.upstream_host = upstream_host
    AuthProxyHandler.upstream_port = upstream_port
    AuthProxyHandler.cred_file = cred_file

    try:
        server = IPv4ThreadingServer(("0.0.0.0", listen_port), AuthProxyHandler)
    except OSError as exc:
        log.error(
            "failed to bind auth-proxy listener on 0.0.0.0:%d: %s",
            listen_port,
            exc,
        )
        return 1
    log.info(
        "listening on 0.0.0.0:%d -> %s:%d (creds=%s)",
        listen_port,
        upstream_host,
        upstream_port,
        cred_file,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
