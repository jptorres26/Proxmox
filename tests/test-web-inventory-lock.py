#!/usr/bin/env python3
"""External target edits must not overwrite each other.

The handlers used to read and validate targets.conf, compute the new content,
and only then take the file lock to write it: two concurrent edits both
started from the same content and the second silently dropped the first.
The Web UI also locked update.conf as "update.conf.uu-lock" while the
installer's config merge locks "update.conf.lock".
"""

import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server

ROOT = Path(__file__).parents[1]

validate = server.validate_inventory_text


def slow_validate(content, script):
    time.sleep(0.2)  # widen the window between reading and writing
    return validate(content, script)


server.validate_inventory_text = slow_validate


class Handler(server.StatusHandler):
    def __init__(self, inventory_file):  # no socket: call the handlers directly
        self.server = SimpleNamespace(inventory_file=inventory_file,
                                      inventory_script=ROOT / "target-inventory.sh")
        self.responses = []

    def send_json(self, payload, status=server.HTTPStatus.OK):
        self.responses.append((int(status), payload))


with tempfile.TemporaryDirectory() as temporary:
    inventory = Path(temporary) / "targets.conf"
    inventory.write_text("", encoding="utf-8")
    handlers = [Handler(inventory) for _ in range(4)]
    threads = [threading.Thread(target=handler.handle_target_add,
                                args=({"id": f"web{number}", "host": f"192.0.2.{number + 10}"},))
               for number, handler in enumerate(handlers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    content = inventory.read_text(encoding="utf-8")
    ids = sorted(item["id"] for item in server.inventory_payload(content))
    assert ids == ["web0", "web1", "web2", "web3"], (ids, content)
    assert all(handler.responses[0][0] == 201 for handler in handlers), [h.responses for h in handlers]

    # A duplicate is detected against the content under the lock.
    duplicate = Handler(inventory)
    duplicate.handle_target_add({"id": "web1", "host": "192.0.2.99"})
    assert duplicate.responses[0][0] == 409, duplicate.responses
    # Concurrent update and delete of the same target: whichever runs second
    # sees the result of the first, never stale content.
    updater, remover = Handler(inventory), Handler(inventory)
    threads = [threading.Thread(target=updater.handle_target_update, args=("web2", {"host": "192.0.2.50"})),
               threading.Thread(target=remover.handle_target_delete, args=("web2",))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    statuses = sorted(handler.responses[0][0] for handler in (updater, remover))
    remaining = {item["id"]: item for item in server.inventory_payload(inventory.read_text(encoding="utf-8"))}
    if "web2" in remaining:  # delete ran first, then the update found nothing
        raise AssertionError(f"target reappeared after delete: {remaining}")
    assert statuses in ([200, 200], [200, 404]), statuses
    assert set(remaining) == {"web0", "web1", "web3"}, remaining
    # The lock file is shared with config-merge.sh.
    assert (Path(temporary) / "targets.conf.lock").exists()
    assert not (Path(temporary) / "targets.conf.uu-lock").exists()

merge = (ROOT / "config-merge.sh").read_text(encoding="utf-8")
assert 'CONFIG_MERGE_LOCK_SUFFIX=".lock"' in merge
print("web inventory lock: PASS")
