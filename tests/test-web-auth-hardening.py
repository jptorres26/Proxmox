#!/usr/bin/env python3
"""Login rate limiting, session lifetime, and cookie flags of the Web UI."""

import base64
import contextlib
import hashlib
import io
import json
import os
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server

os.environ["UU_AUTH_BACKEND"] = "internal"
directory = Path(tempfile.mkdtemp(prefix="uu-auth-"))
salt = os.urandom(16)
auth_file = directory / "web-auth.json"
auth_file.write_text(json.dumps({
    "username": "admin", "salt": base64.b64encode(salt).decode(), "iterations": 1000,
    "password_hash": base64.b64encode(hashlib.pbkdf2_hmac("sha256", b"correct horse", salt, 1000)).decode(),
}), encoding="utf-8")


class SlowCountingStore(server.AuthStore):
    """Mimics pam_faildelay: every verification takes a while."""

    def __init__(self, path):
        super().__init__(path)
        self.verifications = 0
        self.counter_lock = threading.Lock()

    def verify(self, username, password, client=None):
        with self.counter_lock:
            self.verifications += 1
        time.sleep(0.2)
        return super().verify(username, password, client)


quiet = contextlib.redirect_stdout(io.StringIO())

# Parallel guesses from one client must not bypass the per-client limit.
store = SlowCountingStore(auth_file)
with quiet:
    threads = [threading.Thread(target=store.login, args=("admin", f"guess-{n}", "198.51.100.1")) for n in range(30)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
assert store.verifications == server.AuthStore.LOGIN_ATTEMPTS, store.verifications
with quiet:
    assert store.login("admin", "correct horse", "198.51.100.1") is None  # still rate limited
    assert store.login("admin", "correct horse", "198.51.100.2") is not None  # other client unaffected

# The window expires: the limited client may try again.
store.failed_logins["198.51.100.1"] = (99, time.monotonic() - server.AuthStore.LOGIN_WINDOW_SECONDS - 1)
with quiet:
    token, csrf = store.login("admin", "correct horse", "198.51.100.1")
assert store.session(token)["csrf"] == csrf

# Activity extends the idle timeout, but never beyond the absolute lifetime.
store.sessions[token]["created"] -= server.AuthStore.SESSION_MAX_SECONDS
assert store.session(token) is None and token not in store.sessions
with quiet:
    stale, _ = store.login("admin", "correct horse", "198.51.100.3")
store.sessions[stale]["expires"] = time.time() - 1
with quiet:
    store.login("admin", "wrong", "198.51.100.4")  # any login attempt prunes expired sessions
assert stale not in store.sessions

# NUL bytes and wrong usernames fail; the internal backend always hashes.
assert not server.AuthStore(auth_file).verify("admin", "correct horse\x00")
assert not server.AuthStore(auth_file).verify("root", "correct horse")
assert not server.AuthStore(auth_file).verify("ädmin", "correct horse")

# Login results are logged on a single line even for hostile usernames.
output = io.StringIO()
with contextlib.redirect_stdout(output):
    server.AuthStore(auth_file).login("evil\nWeb UI login succeeded for user 'root'", "x", "192.0.2.1")
assert output.getvalue().count("\n") == 1 and "login failed for user" in output.getvalue(), output.getvalue()

# Session cookie flags over a real connection; the side-effecting GET
# duplicate of the internal SSH connection test is gone.
instance = server.UpdaterServer(("127.0.0.1", 0), server.StatusHandler)
instance.auth = server.AuthStore(auth_file)
threading.Thread(target=instance.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{instance.server_address[1]}"
try:
    request = urllib.request.Request(base + "/api/login", method="POST",
                                     data=json.dumps({"username": "admin", "password": "correct horse"}).encode(),
                                     headers={"Content-Type": "application/json"})
    with quiet, urllib.request.urlopen(request, timeout=5) as reply:
        cookie = reply.headers["Set-Cookie"]
    assert "HttpOnly" in cookie and "SameSite=Strict" in cookie, cookie
    assert f"Max-Age={server.AuthStore.SESSION_MAX_SECONDS}" in cookie, cookie
    session_cookie = cookie.split(";", 1)[0]
    probe = urllib.request.Request(base + "/api/internal-ssh/vm/100/test", headers={"Cookie": session_cookie})
    try:
        urllib.request.urlopen(probe, timeout=5)
    except urllib.error.HTTPError as error:
        assert error.code == 404, error.code
    else:
        raise AssertionError("GET must not run the internal SSH connection test")
finally:
    instance.shutdown()
    instance.server_close()

print("Web UI auth hardening: PASS")
