#!/usr/bin/env python3
"""Subprocess timeouts, failed writes, and schedule names in the Web UI."""

import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server

# A timeout stops the whole process group: subprocess.run() killed only the
# direct child, and grandchildren such as ssh or pvesh kept running.
marker = f"{time.time_ns() % 100000}.123"
started = time.monotonic()
try:
    server.run_process(["bash", "-c", f"sleep {marker} & sleep {marker}; wait"], timeout=1,
                       capture_output=True, text=True)
except subprocess.TimeoutExpired:
    pass
else:
    raise AssertionError("run_process did not time out")
assert time.monotonic() - started < 8, "the timeout waited for the grandchild"
time.sleep(0.2)
leftover = subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True, text=True)
assert leftover.returncode != 0, f"orphaned grandchild still running: {leftover.stdout}"

result = server.run_process(["bash", "-c", "echo out; echo err >&2; exit 3"], timeout=5,
                            capture_output=True, text=True, check=False)
assert (result.returncode, result.stdout, result.stderr) == (3, "out\n", "err\n"), result

# A failed write leaves no temporary files behind.
with tempfile.TemporaryDirectory() as directory:
    target = Path(directory) / "update.conf"
    target.write_text("A=1\n")

    def failing(_content):
        raise ValueError("rejected")

    try:
        server.locked_atomic_update(target, failing)
    except ValueError:
        pass
    original_replace = server.os.replace
    server.os.replace = lambda *_args: (_ for _ in ()).throw(OSError("disk full"))
    try:
        server.locked_atomic_update(target, lambda content: content + "B=2\n")
    except OSError:
        pass
    finally:
        server.os.replace = original_replace
    leftovers = sorted(path.name for path in Path(directory).iterdir())
    assert leftovers == ["update.conf", "update.conf.lock"], leftovers
    assert target.read_text() == "A=1\n"

# A trailing backslash would continue the unit's Description= line.
base = {"name": "Nightly", "type": "check-all", "days": ["Mon"], "time": "03:00", "enabled": True, "targets": []}
server.scheduler_validate(base, "0123456789ab")
try:
    server.scheduler_validate({**base, "name": "Nightly \\"}, "0123456789ab")
except ValueError:
    pass
else:
    raise AssertionError("schedule name with a trailing backslash accepted")

print("web process control: PASS")
