#!/usr/bin/env python3
"""Scheduler changes are serialized, and each schedule shows its own last run.

- Create/update/delete read schedules.json, change systemd units, and write
  the file back; concurrent requests dropped entries whose timers kept
  running.
- The last run shown for a schedule was the newest scheduled job of the same
  type, from any schedule.
- Units written by older releases are refreshed at startup so their jobs are
  attributed too.
"""

import json
import os
import stat
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server


class Handler(server.StatusHandler):
    def __init__(self, fixture):  # no socket: call the handlers directly
        self.server = fixture
        self.responses = []

    def send_json(self, payload, status=server.HTTPStatus.OK):
        self.responses.append((int(status), payload))

    def scheduler_systemctl(self, *arguments, timeout=15):
        time.sleep(0.05)  # systemctl is slow; widen the read-modify-write window
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def jobs(self):
        return self.server.jobs


def schedule(name, kind="check-all"):
    return {"name": name, "type": kind, "days": ["Mon"], "time": "03:00", "enabled": True, "targets": []}


with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    fixture = SimpleNamespace(scheduler_file=base / "schedules.json", scheduler_unit_dir=base / "units",
                              cli=Path("/usr/local/sbin/ultimate-updater"), jobs=[])

    # --- concurrent creates keep every schedule ------------------------------------
    handlers = [Handler(fixture) for _ in range(6)]
    threads = [threading.Thread(target=handler.handle_scheduler_create, args=(schedule(f"Check {number}"),))
               for number, handler in enumerate(handlers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    stored = server.scheduler_load(fixture.scheduler_file)
    assert sorted(item["name"] for item in stored) == [f"Check {number}" for number in range(6)], stored
    timers = sorted(path.name for path in fixture.scheduler_unit_dir.glob("*.timer"))
    assert len(timers) == 6, timers

    # --- concurrent update and delete of different schedules ---------------------------
    first, second = stored[0]["id"], stored[1]["id"]
    updater, remover = Handler(fixture), Handler(fixture)
    threads = [threading.Thread(target=updater.handle_scheduler_update, args=(first, {"time": "05:30"})),
               threading.Thread(target=remover.handle_scheduler_delete, args=(second,))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    stored = {item["id"]: item for item in server.scheduler_load(fixture.scheduler_file)}
    assert second not in stored and stored[first]["time"] == "05:30", stored
    assert len(stored) == 5, stored

    # --- each schedule is credited with its own runs only ----------------------------------
    one, other = list(stored)[:2]
    service = (fixture.scheduler_unit_dir / f"{server.scheduler_unit_name(one)}.service").read_text()
    assert f"Environment=UU_JOB_SOURCE=scheduler:{one}\n" in service, service
    fixture.jobs = [
        {"unit": "ultimate-updater-check-all-a", "source": f"scheduler:{one}", "type": "check",
         "state": "completed", "started_at": "2026-09-01T03:00:00Z"},
        {"unit": "ultimate-updater-check-all-b", "source": "scheduler", "type": "check",
         "state": "failed", "started_at": "2026-09-02T03:00:00Z"},
    ]
    handler = Handler(fixture)
    handler.handle_scheduler_get()
    projected = {item["id"]: item for item in handler.responses[0][1]["schedules"]}
    assert projected[one]["last_run"] == {"timestamp": "2026-09-01T03:00:00Z", "result": "completed",
                                          "job": "ultimate-updater-check-all-a"}, projected[one]
    assert projected[other]["last_run"] is None, projected[other]

    # --- units from older releases are refreshed at startup ---------------------------------
    old_service = fixture.scheduler_unit_dir / f"{server.scheduler_unit_name(other)}.service"
    old_service.write_text(old_service.read_text().replace(f"UU_JOB_SOURCE=scheduler:{other}", "UU_JOB_SOURCE=scheduler"))
    bin_dir = base / "bin"
    bin_dir.mkdir()
    (bin_dir / "systemctl").write_text(f"#!/bin/sh\necho \"$@\" >> {base / 'systemctl.log'}\n")
    (bin_dir / "systemctl").chmod(stat.S_IRWXU)
    os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ['PATH']}"
    changed = server.scheduler_refresh_units(fixture.scheduler_file, fixture.scheduler_unit_dir, fixture.cli)
    assert changed == [old_service.name], changed
    assert f"UU_JOB_SOURCE=scheduler:{other}\n" in old_service.read_text()
    assert (base / "systemctl.log").read_text() == "daemon-reload\n"
    # Nothing to do on the next start: no rewrite, no reload.
    assert server.scheduler_refresh_units(fixture.scheduler_file, fixture.scheduler_unit_dir, fixture.cli) == []
    assert (base / "systemctl.log").read_text() == "daemon-reload\n"
    json.loads(fixture.scheduler_file.read_text())

print("scheduler concurrency and attribution: PASS")
