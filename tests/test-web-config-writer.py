#!/usr/bin/env python3
"""Settings saved by the Web UI must read back identically in the scripts.

Every script reads update.conf with awk -F'"' '/^KEY=/ {print $2}'. The
writer used JSON escaping (a backslash became two, "é" became \\u00e9), kept
stray text after unquoted values, and preserved indented assignments that
the scripts never see.
"""

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server


def awk_value(content, key):
    """The value exactly as update.sh/check-updates.sh read it."""
    result = subprocess.run(["awk", "-F\"", f"/^{key}=/ {{print $2}}"], input=content,
                            capture_output=True, text=True, check=True)
    return result.stdout.rstrip("\n")


def rejected(values):
    try:
        server.validate_config_values(values)
    except ValueError:
        return True
    return False


# --- writer ------------------------------------------------------------------------
original = (
    '# comment line stays\n'
    'EMAIL_USER="root" # recipient comment\n'
    'COMPOSE_PATH=/home stray words\n'
    '  ONLY = "101"\n'
    'EXCLUDE="a # b"\n'
    'SSH_PORT="22"\r\n'
    'DEBUG="false"'
)
values = server.validate_config_values({
    "EMAIL_USER": "ops@example.org, admin@example.org",
    "COMPOSE_PATH": "/opt/stacks",
    "ONLY": "101 102 web",
    "EXCLUDE": "",
    "SSH_PORT": 2222,
    "DEBUG": True,
    "EMAIL_SENDER": "$USER",
})
written = server.update_config_text(original, values)
assert written.startswith("# comment line stays\n"), written
assert 'EMAIL_USER="ops@example.org, admin@example.org" # recipient comment\n' in written, written
assert 'COMPOSE_PATH="/opt/stacks"\n' in written, written          # stray text dropped
assert 'ONLY="101 102 web"\n' in written and "  ONLY" not in written, written
assert 'SSH_PORT="2222"\r\n' in written, written                   # line ending kept
assert written.endswith('DEBUG="true"\nEMAIL_SENDER="$USER"\n'), written
for key, expected in (("EMAIL_USER", "ops@example.org, admin@example.org"),
                      ("COMPOSE_PATH", "/opt/stacks"), ("ONLY", "101 102 web"), ("EXCLUDE", ""),
                      ("SSH_PORT", "2222"), ("DEBUG", "true"), ("EMAIL_SENDER", "$USER")):
    assert awk_value(written, key) == expected, (key, awk_value(written, key))
    assert server.parse_config_text(written)[key] == expected, key

# Unchanged values leave the shipped configuration byte-identical.
root = Path(__file__).parents[1]
for name in ("update.conf", "update.conf.dist"):
    text = (root / name).read_text(encoding="utf-8")
    current = {key: value for key, value in server.config_value_map(text).items() if value is not None}
    assert server.update_config_text(text, server.validate_config_values(current)) == text, name

# --- reader shows what the scripts see ----------------------------------------------
parsed = server.config_value_map('DEBUG=true\n  SNAPSHOT="true"\nEXCLUDE="a # b"\nONLY="1" "2"\n')
assert parsed["DEBUG"] is False and parsed["SNAPSHOT"] is None, parsed   # ignored by the scripts
assert parsed["EXCLUDE"] == "a # b" and parsed["ONLY"] == "1", parsed

# --- values that would break the file format or reach a shell -------------------------
for key, value in (
    ("EMAIL_USER", 'root" DEBUG="true'), ("EMAIL_USER", "C:\\temp"), ("EMAIL_USER", "-oProxyCommand=x"),
    ("EMAIL_SENDER", "J\u00f6rg@example.org"), ("EMAIL_SENDER", "$(id)"),
    ("EXE_FOR_INTERNET_CHECK", "ping; id"), ("EXE_FOR_INTERNET_CHECK", "-f"),
    ("URL_FOR_INTERNET_CHECK", "example.org $(id)"), ("URL_FOR_INTERNET_CHECK", "-c1000"),
    ("PACMAN_ENVIRONMENT", "LANG=C; id"), ("PACMAN_ENVIRONMENT", "`id`"),
    ("COMPOSE_PATH", "relative/path"), ("COMPOSE_PATH", "/home`id`"),
    ("ONLY", "101 && reboot"), ("EXCLUDE", "$(id)"), ("BACKUP_STORAGE", "local lvm"),
):
    assert rejected({key: value}), (key, value)
for key, value in (
    ("URL_FOR_INTERNET_CHECK", "2001:db8::1"), ("URL_FOR_INTERNET_CHECK", "1.1.1.1"),
    ("EXE_FOR_INTERNET_CHECK", "/usr/bin/ping"), ("PACMAN_ENVIRONMENT", "LANG=C HTTP_PROXY=http://proxy:3128"),
    ("PACMAN_ENVIRONMENT", "env http_proxy=http://some.proxy:1234"),
    ("EMAIL_SENDER", "Updater <updater@example.org>"), ("ONLY", "100,101 prod"), ("EXCLUDE", ""),
    ("COMPOSE_PATH", "/srv/docker compose"),
):
    assert not rejected({key: value}), (key, value)

print("web config writer: PASS")
