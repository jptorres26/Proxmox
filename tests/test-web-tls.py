#!/usr/bin/env python3
"""TLS selection, safe fallback, and certificate reload regression checks."""

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server


old = {key: os.environ.get(key) for key in ("WEB_UI_HTTPS", "WEB_UI_CERT_FILE", "WEB_UI_KEY_FILE")}
try:
    os.environ["WEB_UI_HTTPS"] = "false"
    os.environ.pop("WEB_UI_CERT_FILE", None)
    os.environ.pop("WEB_UI_KEY_FILE", None)
    context, source, cert, reason = server.build_tls_context()
    assert context is None and source == "disabled" and cert is None

    with tempfile.TemporaryDirectory() as directory:
        os.environ["WEB_UI_HTTPS"] = "true"
        os.environ["WEB_UI_CERT_FILE"] = str(Path(directory) / "missing.pem")
        os.environ["WEB_UI_KEY_FILE"] = str(Path(directory) / "missing.key")
        try:
            server.build_tls_context()
        except server.TLSConfigurationError as error:
            assert "HTTPS requested but unavailable" in str(error)
        else:
            raise AssertionError("invalid required TLS configuration was accepted")
finally:
    for key, value in old.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

print("Web UI TLS selection tests: PASS")

# --- a Proxmox node never falls back to plain HTTP ------------------------------
saved = {name: getattr(server, name) for name in (
    "PROXMOX_NODE_MARKER", "DEFAULT_PROXMOX_CERT", "DEFAULT_PROXMOX_KEY",
    "DEFAULT_PROXMOX_CUSTOM_CERT", "DEFAULT_PROXMOX_CUSTOM_KEY")}
old = {key: os.environ.get(key) for key in ("WEB_UI_HTTPS", "WEB_UI_CERT_FILE", "WEB_UI_KEY_FILE")}
try:
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        os.environ["WEB_UI_HTTPS"] = "auto"
        os.environ.pop("WEB_UI_CERT_FILE", None)
        os.environ.pop("WEB_UI_KEY_FILE", None)
        server.DEFAULT_PROXMOX_CERT = base / "pve-ssl.pem"
        server.DEFAULT_PROXMOX_KEY = base / "pve-ssl.key"
        server.DEFAULT_PROXMOX_CUSTOM_CERT = base / "pveproxy-ssl.pem"
        server.DEFAULT_PROXMOX_CUSTOM_KEY = base / "pveproxy-ssl.key"

        server.PROXMOX_NODE_MARKER = base / "not-a-pve-node"
        context, source, _cert, _reason = server.build_tls_context()
        assert context is None and source == "HTTP fallback"      # other hosts keep the fallback
        server.PROXMOX_NODE_MARKER = base / "pveversion"
        server.PROXMOX_NODE_MARKER.touch()
        try:
            server.build_tls_context()
        except server.TLSConfigurationError as error:
            assert "not available yet" in str(error)
        else:
            raise AssertionError("a Proxmox node without its certificate served plain HTTP")

        # --- renewed certificates are picked up without a restart ----------------------
        def issue(name):
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", f"/CN={name}", "-keyout", str(server.DEFAULT_PROXMOX_KEY),
                            "-out", str(server.DEFAULT_PROXMOX_CERT)], check=True, capture_output=True)

        issue("first")
        context, source, cert, _reason = server.build_tls_context()
        assert context is not None and source == "Proxmox", source
        fake = SimpleNamespace(tls_context=context)
        state = server.tls_certificate_state()
        assert server.reload_tls_context(fake, state) == state and fake.tls_context is context  # unchanged
        time.sleep(0.01)
        issue("renewed")
        state = server.reload_tls_context(fake, state)
        assert fake.tls_context is not context, "renewed certificate was not loaded"
        # A broken renewal keeps serving the current certificate.
        current = fake.tls_context
        server.DEFAULT_PROXMOX_KEY.write_text("broken")
        server.reload_tls_context(fake, state)
        assert fake.tls_context is current
finally:
    for name, value in saved.items():
        setattr(server, name, value)
    for key, value in old.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

unit = (Path(__file__).parents[1] / "ultimate-updater-web.service").read_text()
assert "After=network-online.target pve-cluster.service" in unit
assert "Environment=WEB_UI_PORT=8765" in unit
assert unit.index("Environment=WEB_UI_PORT=8765") < unit.index("EnvironmentFile=")
# The UI's process tree runs pct exec, qm start, ssh, and ctypes PAM callbacks.
directives = {line.split("=", 1)[0] for line in unit.splitlines() if "=" in line and not line.startswith("#")}
for unsafe in ("ProtectClock", "PrivateDevices", "ProtectControlGroups", "RestrictNamespaces",
               "ProtectProc", "ProtectHome", "MemoryDenyWriteExecute", "CapabilityBoundingSet"):
    assert unsafe not in directives, unsafe
print("Web UI TLS reload and Proxmox node guard: PASS")
