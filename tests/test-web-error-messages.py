#!/usr/bin/env python3
"""Error responses show validation messages but not internal details."""

import contextlib
import importlib.util
import io
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("server", ROOT / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

fallback = "Schedule could not be removed."
assert server.error_message(ValueError("Unsupported schedule time."), fallback) == "Unsupported schedule time."
assert server.error_message(RuntimeError("Unit failed: bad value"), fallback) == "Unit failed: bad value"
assert server.error_message(ValueError(""), fallback) == fallback

# Lookups meant for the user read without dict-key quotes.
missing = server.NotFoundError("Internal SSH target not found.")
assert isinstance(missing, KeyError)
assert server.error_message(missing, fallback) == "Internal SSH target not found."

# File paths, stray KeyErrors and timeouts go to the journal only.
for error in (PermissionError(13, "Permission denied", "/etc/ultimate-updater/schedules.json"),
              KeyError("host"),
              subprocess.TimeoutExpired(["systemctl"], 15)):
    journal = io.StringIO()
    with contextlib.redirect_stderr(journal):
        assert server.error_message(error, fallback) == fallback
    assert type(error).__name__ in journal.getvalue()

# No handler answers with a raw str(error) fallback chain any more.
source = (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
assert not re.search(r'str\(error\) or "', source), "a handler still echoes str(error)"
assert 'raise KeyError("Internal SSH target not found.")' not in source

print("web error messages: PASS", file=sys.stdout)
