#!/usr/bin/env python3
"""Every Web UI response carries hardening headers; the page gets a hash-based CSP."""

import base64
import hashlib
import re
import socket
import sys
import threading
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server


def start():
    instance = server.UpdaterServer(("127.0.0.1", 0), server.StatusHandler)
    instance.auth = server.AuthStore(Path("/nonexistent/web-auth.json"))
    instance.update_script = Path("/nonexistent/update.sh")
    instance.config_file = Path("/nonexistent/update.conf")
    instance.asset_dir = Path("/nonexistent")
    instance.version_last_data = None
    instance.version_refresh_lock = threading.Lock()
    instance.version_refresh_running = True  # never start a background refresh
    threading.Thread(target=instance.serve_forever, daemon=True).start()
    return instance, instance.server_address[1]


def request(port, raw):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.sendall(raw)
        response = b""
        while chunk := connection.recv(65536):
            response += chunk
    head, _, body = response.partition(b"\r\n\r\n")
    lines = head.decode("iso-8859-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers.setdefault(name.strip().lower(), []).append(value.strip())
    return lines[0], headers, body


def get(port, path):
    return request(port, f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())


def check_common(status, headers):
    for name, value in server.SECURITY_HEADERS:
        assert headers.get(name.lower()) == [value], (status, name, headers.get(name.lower()))
    assert len(headers.get("content-security-policy", [])) == 1, (status, headers)
    assert "frame-ancestors 'none'" in headers["content-security-policy"][0], status
    # No Python version disclosure.
    assert headers["server"] == [server.StatusHandler.server_version], headers["server"]


class InlineCode(HTMLParser):
    """Collects what a CSP without 'unsafe-inline' for scripts would block."""

    def __init__(self):
        super().__init__()
        self.scripts = []
        self.blocked = []
        self.in_script = False

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name.startswith("on") or (value or "").strip().lower().startswith("javascript:"):
                self.blocked.append((tag, name))
        if tag == "script":
            assert not attrs, f"unexpected script attributes: {attrs}"
            self.in_script = True
            self.scripts.append("")

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_script = False

    def handle_data(self, data):
        if self.in_script:
            self.scripts[-1] += data


instance, port = start()
try:
    status, headers, body = get(port, "/")
    assert status.endswith(" 200 OK"), status
    check_common(status, headers)
    policy = headers["content-security-policy"][0]
    directives = dict(part.strip().split(" ", 1) for part in policy.split(";"))
    assert directives["default-src"] == "'none'", policy
    assert "'unsafe-inline'" not in directives["script-src"], policy
    assert "'unsafe-eval'" not in directives["script-src"], policy

    # Each inline script is allowed by exactly its hash, and nothing else in the
    # markup (inline handlers, javascript: URLs) needs 'unsafe-inline'.
    parser = InlineCode()
    parser.feed(body.decode())
    assert parser.scripts and not parser.blocked, parser.blocked
    expected = {"'sha256-" + base64.b64encode(hashlib.sha256(script.encode()).digest()).decode() + "'"
                for script in parser.scripts}
    assert set(directives["script-src"].split()) == expected, (directives["script-src"], expected)

    # JSON API responses, missing assets, and stock error pages.
    for path in ("/api/session", "/api/status", "/assets/favicon.png", "/nope"):
        status, headers, _ = get(port, path)
        check_common(status, headers)
        assert headers["content-security-policy"] == [server.DEFAULT_CSP], (path, headers)
    status, headers, _ = request(port, b"BREW / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert status.split()[1] == "501", status
    check_common(status, headers)
    assert headers["content-security-policy"] == [server.DEFAULT_CSP], headers
finally:
    instance.shutdown()
    instance.server_close()

assert re.search(r"script-src 'sha256-", server.PAGE_CSP)
print("web security headers: PASS")
