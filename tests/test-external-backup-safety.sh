#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
STATE="$WORK_DIR/backup.json"
trap 'rm -rf "$WORK_DIR"' EXIT

run_check() {
  UU_EXTERNAL_BACKUP_STATE_FILE="$STATE" "$ROOT_DIR/external-backup-safety.sh" check rocky-test "$@"
}

if run_check >/dev/null 2>&1; then
  echo "missing verification was accepted" >&2
  exit 1
fi

UU_EXTERNAL_BACKUP_STATE_FILE="$STATE" "$ROOT_DIR/external-backup-safety.sh" verify rocky-test fixture-reference >/dev/null
[[ "$(UU_EXTERNAL_BACKUP_STATE_FILE="$STATE" "$ROOT_DIR/external-backup-safety.sh" status rocky-test)" == *'"status": "verified"'* ]]
run_check >/dev/null

python3 - "$STATE" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    state = json.load(source)
state["rocky-test"]["verified_at"] = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat().replace("+00:00", "Z")
with open(path, "w", encoding="utf-8") as target:
    json.dump(state, target)
PY

if run_check >/dev/null 2>&1; then
  echo "expired verification was accepted" >&2
  exit 1
fi
run_check --override >/dev/null
if run_check >/dev/null 2>&1; then
  echo "one-time override persisted" >&2
  exit 1
fi

# Concurrent verifications of different targets are all recorded.
PARALLEL_STATE="$WORK_DIR/parallel.json"
for number in $(seq 1 8); do
  UU_EXTERNAL_BACKUP_STATE_FILE="$PARALLEL_STATE" "$ROOT_DIR/external-backup-safety.sh" \
    verify "target-$number" "ref-$number" >/dev/null &
done
wait
python3 - "$PARALLEL_STATE" <<'PY'
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert sorted(state) == [f"target-{number}" for number in range(1, 9)], sorted(state)
PY

# Control characters never reach the state file.
for reference in $'tab\there' $'bell\a' $'line\nbreak'; do
  if UU_EXTERNAL_BACKUP_STATE_FILE="$STATE" "$ROOT_DIR/external-backup-safety.sh" verify rocky-test "$reference" 2>/dev/null; then
    echo "accepted a reference with a control character" >&2
    exit 1
  fi
done

echo "external backup safety tests: PASS"
