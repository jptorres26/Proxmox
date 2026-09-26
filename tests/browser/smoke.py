#!/usr/bin/env python3
"""Browser smoke test for the Web UI.

Starts web-ui/server.py against temporary fixtures (internal authentication,
stubbed Proxmox/systemd/job-runner commands), signs in with Chromium via
Playwright, visits every page, and fails on uncaught JavaScript errors,
console errors, or HTML injected through status data.

Requirements (not needed for tests/run-all.sh):
    python3 -m pip install -r tests/browser/requirements.txt
    python3 -m playwright install --with-deps chromium
"""

import base64
import hashlib
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[2]
USERNAME = "smoke-admin"
PASSWORD = secrets.token_urlsafe(16)
COMMIT = "0123456789abcdef0123456789abcdef01234567"
# Rendered as text, these probes are harmless; parsed as HTML they would set
# window.__uuInjected or add an element with the uu-injected class.
PROBE = '<img src=x class="uu-injected" onerror="window.__uuInjected=1">'


def write_executable(path, content):
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def build_fixture(base):
    etc, bin_dir = base / "etc", base / "bin"
    etc.mkdir()
    bin_dir.mkdir()
    (base / "jobs").mkdir()
    (base / "units").mkdir()

    config = (ROOT / "update.conf.dist").read_text(encoding="utf-8")
    (etc / "update.conf").write_text(config.replace('USED_BRANCH="develop"', 'USED_BRANCH="master"'),
                                     encoding="utf-8")
    shutil.copy(ROOT / "targets.conf", etc / "targets.conf")
    with (etc / "targets.conf").open("a", encoding="utf-8") as inventory:
        inventory.write("\n[smoke-external]\nhost=192.0.2.10\ntransport=ssh\nuser=root\nport=22\n")
    for script in ("tag-filter.sh", "target-inventory.sh", "external-apt.sh", "cluster-target.sh"):
        shutil.copy(ROOT / script, etc / script)
    (etc / "build-metadata").write_text(
        f'schema_version=1\nbranch="master"\ncommit="{COMMIT}"\ntag="v5.1.2"\n', encoding="utf-8")
    write_executable(etc / "update.sh", f"""#!/bin/bash
VERSION="5.1.2"
[[ "${{1:-}}" == status ]] || exit 0
printf '  Version overview (master)\\n\\nInstalled commit: {COMMIT}\\n'
printf 'Available commit: {COMMIT}\\nInstalled tag: v5.1.2\\n\\n'
printf '%-12s %-9s %-9s\\n' Component Local Server Updater 5.1.2 5.1.2
""")

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    def target(target_id, kind, transport, name, **extra):
        record = {
            "id": target_id, "type": kind, "transport": transport, "name": name,
            "node": "pve-smoke" if kind != "external" else None, "reachable": True,
            "os": "Debian GNU/Linux 13 (trixie)", "os_version": "13", "updater": "apt",
            "updates": {"available": 0}, "reboot_required": False, "last_check": now,
            "check_status": "no_updates", "error": None, "security_split_supported": True,
            "last_update": {"status": "unknown", "timestamp": None},
        }
        record.update(extra)
        return record

    status = {"schema_version": 1, "generated_at": now, "targets": [
        target("host:pve-smoke", "host", "local", "pve-smoke"),
        target("101", "lxc", "pct", f"web{PROBE}", check_status="updates_available",
               updates={"available": 3, "normal": 2, "security": 1}),
        target("102", "vm", "qga", "db", os=f"Ubuntu {PROBE}", check_status="error",
               reachable=False, error={"code": "QGA_NOT_READY", "message": f"agent {PROBE}"}),
        target("smoke-external", "external", "ssh", "smoke-external", reboot_required=True),
    ]}
    (base / "status.json").write_text(json.dumps(status, indent=2), encoding="utf-8")

    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", PASSWORD.encode(), salt, 1000)
    (base / "auth.json").write_text(json.dumps({
        "username": USERNAME, "salt": base64.b64encode(salt).decode(),
        "password_hash": base64.b64encode(digest).decode(), "iterations": 1000,
    }), encoding="utf-8")

    resources = {
        "node": [{"type": "node", "node": "pve-smoke", "status": "online"}],
        "vm": [
            {"type": "lxc", "vmid": 101, "node": "pve-smoke", "name": f"web{PROBE}",
             "status": "running", "template": 0},
            {"type": "qemu", "vmid": 102, "node": "pve-smoke", "name": "db", "status": "stopped", "template": 0},
        ],
    }
    write_executable(bin_dir / "pvesh", f"""#!/usr/bin/env python3
import json, sys
resources = {json.dumps(resources)!r}
kind = sys.argv[sys.argv.index("--type") + 1] if "--type" in sys.argv else "vm"
print(json.dumps(json.loads(resources).get(kind, [])))
""")
    write_executable(bin_dir / "systemctl", "#!/bin/sh\nexit 0\n")
    write_executable(bin_dir / "systemd-run", "#!/bin/sh\nexit 0\n")
    finished = "2026-01-01T00:05:00Z"
    write_executable(base / "job-runner.sh", f"""#!/bin/sh
[ "$1" = list ] || exit 0
printf 'ultimate-updater-check-101-20260101-000000\\t101\\tsucceeded\\t2026-01-01T00:00:00Z\\t{finished}\\t0\\tcheck\\n'
""")
    write_executable(base / "ultimate-updater", "#!/bin/sh\nexit 0\n")
    return etc, bin_dir


def wait_for_server(url, process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited early with status {process.returncode}")
        try:
            with urllib.request.urlopen(url + "/api/session", timeout=2):
                return
        except urllib.error.HTTPError:
            return  # 401 means the server is up.
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("server did not start")


def main():
    with tempfile.TemporaryDirectory(prefix="uu-browser-") as temporary:
        base = Path(temporary)
        etc, bin_dir = build_fixture(base)
        port = free_port()
        url = f"http://127.0.0.1:{port}"
        environment = {
            **os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "UU_AUTH_BACKEND": "internal", "WEB_UI_HTTPS": "false", "PYTHONUNBUFFERED": "1",
        }
        log_path = base / "server.log"
        with log_path.open("w", encoding="utf-8") as log:
            server = subprocess.Popen([
                sys.executable, str(ROOT / "web-ui" / "server.py"),
                "--status-file", str(base / "status.json"), "--config-file", str(etc / "update.conf"),
                "--inventory-file", str(etc / "targets.conf"),
                "--inventory-script", str(etc / "target-inventory.sh"),
                "--external-script", str(etc / "external-apt.sh"),
                "--cluster-target-script", str(etc / "cluster-target.sh"),
                "--asset-dir", str(ROOT / "web-ui" / "assets"), "--cli", str(base / "ultimate-updater"),
                "--job-runner", str(base / "job-runner.sh"), "--jobs-dir", str(base / "jobs"),
                "--scheduler-file", str(base / "schedules.json"), "--scheduler-unit-dir", str(base / "units"),
                "--auth-file", str(base / "auth.json"), "--bind", "127.0.0.1", "--port", str(port),
            ], env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for_server(url, server)
            run_browser(url, etc / "update.conf", base / "schedules.json")
        except BaseException:
            print(log_path.read_text(encoding="utf-8"), file=sys.stderr)
            raise
        finally:
            server.terminate()
            server.wait(timeout=10)
    print("browser smoke test: PASS")


def injected_markup(page):
    return page.evaluate("() => window.__uuInjected === 1 || !!document.querySelector('.uu-injected')")


def run_browser(url, config_file, schedules_file):
    problems = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page(viewport={"width": 1400, "height": 1000})
        page.on("pageerror", lambda error: problems.append(f"uncaught exception: {error}"))
        page.on("console", lambda message: problems.append(f"console {message.type}: {message.text}")
                if message.type == "error" and "Failed to load resource" not in message.text else None)
        page.on("dialog", lambda dialog: (problems.append(f"unexpected dialog: {dialog.message}"),
                                          dialog.dismiss()))
        try:
            exercise_pages(page, url)
            exercise_settings(page, url, config_file)
            exercise_scheduler(page, url, schedules_file)
        except Exception as error:
            problems.append(f"{type(error).__name__}: {error}")
        finally:
            browser.close()
    if problems:
        raise AssertionError("\n".join(problems))


def exercise_pages(page, url):
    page.goto(url + "/")
    login = page.locator("#login-form")
    expect(login).to_be_visible()
    login.locator('input[name="username"]').fill(USERNAME)
    login.locator('input[name="password"]').fill(PASSWORD)
    login.locator('button[type="submit"]').click()

    expect(page.locator("#dashboard")).to_be_visible()
    targets = page.locator("#targets")
    expect(targets).to_contain_text("pve-smoke")
    expect(targets).to_contain_text("smoke-external")
    page.locator('button[aria-label="Expand pve-smoke"]').click()
    expect(targets).to_contain_text("db")
    page.wait_for_load_state("networkidle")
    assert not injected_markup(page), "status data was rendered as HTML (XSS)"
    # The probe must render as literal text, never as markup.
    expect(targets).to_contain_text("web<img")

    for route, section in (("settings", "#settings-page"), ("scheduler", "#scheduler-page"),
                           ("overview", "#overview-page")):
        link = page.locator(f'a[data-page="{route}"]').first
        if not link.is_visible():
            page.locator("button.nav-toggle").first.click()
        link.click()
        expect(page.locator(section)).to_be_visible()
        page.wait_for_load_state("networkidle")
    expect(page.locator("#config-form")).to_be_attached()

    page.goto(url + "/")
    expect(page.locator("#dashboard")).to_be_visible()
    page.wait_for_load_state("networkidle")
    assert not injected_markup(page), "status data was rendered as HTML (XSS)"


def exercise_settings(page, url, config_file):
    """Saving keeps the editor usable and writes only the changed setting."""
    page.goto(url + "/settings")
    form = page.locator("#config-form")
    message = page.locator("#config-message")
    recipient = form.locator('input[data-key="EMAIL_USER"]')
    expect(recipient).to_be_visible()
    before = config_file.read_text(encoding="utf-8")

    form.locator('button[type="submit"]').click()
    expect(message).to_have_text("No changes to save.")
    assert config_file.read_text(encoding="utf-8") == before, "an unchanged form rewrote update.conf"

    recipient.fill("ops@example.org")
    form.locator('button[type="submit"]').click()
    expect(message).to_have_text("Configuration saved.")
    expect(recipient).to_be_visible()
    expect(recipient).to_have_value("ops@example.org")
    after = config_file.read_text(encoding="utf-8")
    changed = [(old, new) for old, new in zip(before.splitlines(), after.splitlines(), strict=True) if old != new]
    assert changed == [('EMAIL_USER="root"', 'EMAIL_USER="ops@example.org"')], changed

    recipient.fill("someone@example.org")
    form.locator("#config-close").click()
    expect(message).to_have_text("Changes discarded.")
    expect(form.locator('input[data-key="EMAIL_USER"]')).to_have_value("ops@example.org")

    recipient = form.locator('input[data-key="EMAIL_USER"]')
    recipient.fill('root" DEBUG="true')
    form.locator('button[type="submit"]').click()
    expect(message).to_have_text("Configuration was not changed: EMAIL_USER contains unsupported characters.")
    assert config_file.read_text(encoding="utf-8") == after


def exercise_scheduler(page, url, schedules_file):
    """A double submission creates one schedule, not two."""
    page.goto(url + "/scheduler")
    page.locator("#schedule-add").click()
    form = page.locator("#schedule-form")
    form.locator('input[name="name"]').fill("Nightly smoke check")
    form.locator('input[name="days"][value="Mon"]').check()
    form.locator('input[name="time"]').fill("03:15")
    form.evaluate("form => { form.requestSubmit(); form.requestSubmit(); }")
    expect(page.locator("#scheduler-list .scheduler-card")).to_have_count(1)
    expect(page.locator("#scheduler-list")).to_contain_text("Nightly smoke check")
    page.wait_for_load_state("networkidle")
    stored = json.loads(schedules_file.read_text(encoding="utf-8"))["schedules"]
    assert [item["name"] for item in stored] == ["Nightly smoke check"], stored


if __name__ == "__main__":
    main()
