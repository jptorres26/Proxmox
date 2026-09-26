#!/usr/bin/env python3
"""Unauthenticated request handling must not exhaust or stall the Web UI."""

import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server


class FastTimeoutHandler(server.StatusHandler):
    timeout = 1


class SmallServer(server.UpdaterServer):
    max_connections = 3


def start(tls_context=None, server_class=SmallServer):
    instance = server_class(("127.0.0.1", 0), FastTimeoutHandler, tls_context=tls_context)
    instance.auth = server.AuthStore(Path("/nonexistent/web-auth.json"))
    instance.update_script = Path("/nonexistent/update.sh")
    instance.config_file = Path("/nonexistent/update.conf")
    instance.version_last_data = None
    instance.version_refresh_lock = threading.Lock()
    instance.version_refresh_running = True  # never start a background refresh
    threading.Thread(target=instance.serve_forever, daemon=True).start()
    return instance, instance.server_address[1]


def raw_request(port, request, shutdown_write=False, timeout=5):
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as connection:
        connection.sendall(request)
        if shutdown_write:
            connection.shutdown(socket.SHUT_WR)
        started = time.monotonic()
        response = b""
        while chunk := connection.recv(65536):
            response += chunk
        return response, time.monotonic() - started


def post_login(port, headers, body=b"", **options):
    head = "POST /api/login HTTP/1.1\r\nHost: localhost\r\n" + "".join(f"{k}: {v}\r\n" for k, v in headers.items())
    return raw_request(port, head.encode() + b"\r\n" + body, **options)


instance, port = start()
try:
    # A negative length used to make rfile.read(-1) buffer until EOF.
    response, elapsed = post_login(port, {"Content-Type": "application/json", "Content-Length": "-1"}, b"x" * 1000)
    assert response.startswith(b"HTTP/1.0 400"), response[:80]
    assert b"invalid content length" in response and elapsed < 3, (response, elapsed)
    for bad in ("+10", "1e3", " 12x", "99999999"):
        response, _ = post_login(port, {"Content-Type": "application/json", "Content-Length": bad})
        assert response.startswith((b"HTTP/1.0 400", b"HTTP/1.0 413")), (bad, response[:80])
    response, _ = post_login(port, {"Content-Type": "application/json", "Content-Length": "5000"})
    assert response.startswith(b"HTTP/1.0 413"), response[:80]
    response, _ = post_login(port, {"Content-Type": "application/json", "Content-Length": "100"}, b"{}",
                             shutdown_write=True)
    assert response.startswith(b"HTTP/1.0 400") and b"incomplete" in response, response[:120]
    nested = b"[" * 3000
    response, _ = post_login(port, {"Content-Type": "application/json", "Content-Length": str(len(nested))}, nested)
    assert response.startswith(b"HTTP/1.0 400") and b"JSON body is invalid" in response, response[:120]
    response, _ = post_login(port, {"Content-Type": "text/plain", "Content-Length": "2"}, b"{}")
    assert response.startswith(b"HTTP/1.0 400"), response[:80]
    response, _ = post_login(port, {"Transfer-Encoding": "chunked"}, b"0\r\n\r\n")
    assert response.startswith(b"HTTP/1.0 400"), response[:80]

    # Unexpected handler errors are answered instead of dropping the connection.
    original = server.StatusHandler.public_version
    server.StatusHandler.public_version = lambda self: 1 / 0
    try:
        with open(os.devnull, "w") as quiet:
            stderr, sys.stderr = sys.stderr, quiet
            try:
                response, _ = raw_request(port, b"GET /api/public-version HTTP/1.1\r\nHost: localhost\r\n\r\n")
            finally:
                sys.stderr = stderr
    finally:
        server.StatusHandler.public_version = original
    assert response.startswith(b"HTTP/1.0 500") and b"INTERNAL_ERROR" in response, response[:120]

    # Idle clients are disconnected after the handler timeout and cannot
    # occupy more than max_connections slots.
    idle = [socket.create_connection(("127.0.0.1", port)) for _ in range(3)]
    time.sleep(0.2)
    with socket.create_connection(("127.0.0.1", port), timeout=3) as extra:
        assert extra.recv(1) == b"", "connection beyond the cap was served"
    for connection in idle:
        connection.settimeout(3)
        assert connection.recv(1) == b"", "idle connection was not closed by the timeout"
        connection.close()
    time.sleep(0.2)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/public-version", timeout=3) as reply:
        assert reply.status == 200
finally:
    instance.shutdown()
    instance.server_close()

# A client that never completes the TLS handshake must not block others.
if shutil.which("openssl"):
    with tempfile.TemporaryDirectory() as directory:
        cert, key = Path(directory, "cert.pem"), Path(directory, "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(cert)],
                       check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        instance, port = start(tls_context=context, server_class=server.UpdaterServer)
        try:
            staller = socket.create_connection(("127.0.0.1", port))
            client_context = ssl.create_default_context(cafile=str(cert))
            client_context.check_hostname = False
            started = time.monotonic()
            with urllib.request.urlopen(f"https://127.0.0.1:{port}/api/public-version",
                                        context=client_context, timeout=3) as reply:
                assert reply.status == 200
            assert time.monotonic() - started < 2
            staller.settimeout(3)
            assert staller.recv(1) == b"", "stalled handshake was not timed out"
            staller.close()
        finally:
            instance.shutdown()
            instance.server_close()
else:
    print("TLS handshake check skipped: openssl is unavailable")

print("Web UI request safety: PASS")
