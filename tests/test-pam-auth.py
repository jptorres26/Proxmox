#!/usr/bin/env python3
"""End-to-end check of the ctypes PAM adapter used by the Web UI login.

As root on a host with the PAM "login" service, a temporary local account is
created, authenticated against the real PAM stack, and removed again.
"""

import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import pam_auth

# Embedded NUL bytes would be truncated by strdup(); they must never reach PAM.
assert pam_auth.authenticate("root\x00suffix", "secret") is False
assert pam_auth.authenticate("root", "pass\x00word") is False

tools = all(shutil.which(tool) for tool in ("useradd", "chpasswd", "userdel"))
if os.geteuid() != 0 or not Path("/etc/pam.d/login").is_file() or not tools:
    print("PAM adapter: PASS (live PAM round trip skipped: needs root, useradd and /etc/pam.d/login)")
    raise SystemExit(0)

user = f"uu-pam-{secrets.token_hex(4)}"
password = secrets.token_urlsafe(18)
subprocess.run(["useradd", "--no-create-home", "--shell", "/usr/sbin/nologin", user], check=True)
try:
    subprocess.run(["chpasswd"], input=f"{user}:{password}\n", text=True, check=True)
    assert pam_auth.authenticate(user, password) is True
    assert pam_auth.authenticate(user, password, rhost="192.0.2.7") is True
    assert pam_auth.authenticate(user, password + "x") is False
    assert pam_auth.authenticate(f"{user}-missing", password) is False
finally:
    subprocess.run(["userdel", user], check=False)

print("PAM adapter: PASS")
