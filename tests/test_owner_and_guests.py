import re
import time

import requests
from openhost_test_harness import OpenhostStack

HTML = {"Accept": "text/html"}


def _context(stack: OpenhostStack, response: requests.Response | None) -> str:
    summary = "no response" if response is None else f"{response.status_code}: {response.text[:500]}"
    return f"{summary}\n\napp logs:\n{stack.app_logs()[-5000:]}"


def _wait_for_lila(stack: OpenhostStack) -> str:
    """Waits until Lila serves its lobby (it takes minutes to boot: mongo seeding, reset-db.sh, then the JVM)."""
    deadline = time.monotonic() + 600
    response = None
    while time.monotonic() < deadline:
        try:
            response = requests.get(f"{stack.url}/", headers=HTML, allow_redirects=False, timeout=30)
        except requests.ConnectionError:
            response = None
        else:
            if response.status_code == 200 and "data-socket-domains" in response.text:
                return response.text
        time.sleep(5)
    raise AssertionError(f"Lila never served its lobby: {_context(stack, response)}")


def _owner_lila_session(stack: OpenhostStack) -> str:
    """Returns the ``lila2`` session cookie auth_proxy.py mints on the owner's first navigation."""
    _wait_for_lila(stack)
    deadline = time.monotonic() + 120
    response = None
    while time.monotonic() < deadline:
        try:
            response = stack.owner_session.get(f"{stack.url}/", headers=HTML, allow_redirects=False, timeout=30)
        except requests.ConnectionError:
            response = None
        else:
            match = re.search(r"lila2=([^;]+)", response.headers.get("Set-Cookie", ""))
            if response.status_code == 302 and match and "sessionId" in match.group(1):
                return match.group(1)
        time.sleep(5)
    raise AssertionError(f"owner GET / never got an auto-login session: {_context(stack, response)}")


def test_owner_sso(stack: OpenhostStack) -> None:
    # The owner lands in Lila logged in as its admin, without the login form.
    session = _owner_lila_session(stack)
    response = requests.get(f"{stack.url}/", headers={**HTML, "Cookie": f"lila2={session}"}, timeout=30)
    assert response.status_code == 200, _context(stack, response)
    assert 'data-user="admin"' in response.text, response.text[:3000]


def test_anonymous_guest(stack: OpenhostStack) -> None:
    # public_paths = ["/"]: people the owner shares links with use Lila as anonymous guests, never as the admin, even
    # when they forge the owner header the router stamps.
    page = _wait_for_lila(stack)
    # LILA_DOMAIN / LILA_URL come from the zone: live-game sockets and assets point at the app's public URL.
    assert f'data-socket-domains="{stack.url.split("://", 1)[1]}"' in page, page[:3000]
    assert f'data-asset-url="{stack.url}"' in page, page[:3000]
    for headers in (HTML, {**HTML, "X-OpenHost-Is-Owner": "true"}):
        response = requests.get(f"{stack.url}/", headers=headers, allow_redirects=False, timeout=30)
        assert response.status_code == 200, f"anonymous GET / with {headers}: {_context(stack, response)}"
        assert "sessionId" not in response.headers.get("Set-Cookie", ""), response.headers
        assert 'data-user="admin"' not in response.text


def test_computer_opponent_moves(stack: OpenhostStack) -> None:
    # "Play with the computer" needs our pinned lila-fishnet broker and Stockfish worker: Lila itself never moves.
    _wait_for_lila(stack)
    form = {"variant": "1", "timeMode": "0", "time": "10", "increment": "0", "days": "2", "level": "1"}
    response = requests.post(
        f"{stack.url}/setup/ai",
        data={**form, "color": "black", "fen": ""},
        headers={**HTML, "Origin": stack.url},
        timeout=30,
    )
    game = re.fullmatch(r"/(\w{8})(\w{4})?", response.url.split(stack.url, 1)[-1])
    assert response.status_code == 200 and game, f"POST /setup/ai ended at {response.url}: {_context(stack, response)}"
    # We play black, so the computer (white) has to make the first move.
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        response = requests.get(f"{stack.url}/game/export/{game.group(1)}", timeout=30)
        if response.status_code == 200 and re.search(r"\b1\. \S", response.text):
            return
        time.sleep(5)
    raise AssertionError(f"the computer never moved in game {game.group(1)}: {_context(stack, response)}")
