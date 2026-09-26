#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # stubs and globals are used by job-runner functions.
set -euo pipefail

# job-runner maintenance paths: target validation, remote reference retention,
# the running/finished race, stale refresh locks, and status.json writes.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
RUNNER="$ROOT_DIR/job-runner.sh"

# --- valid_target ------------------------------------------------------------
eval "$(sed -n '/^valid_target() {/,/^}/p' "$RUNNER")"
for target in 101 host local-host all-systems node-pve1 mediacenter web.example-01; do
  valid_target "$target" || { echo "rejected valid target: $target" >&2; exit 1; }
done
for target in 'ab;id' 'ab/../x' $'ab\nstate=completed' '-x' '' '.hidden' 'a b'; do
  if valid_target "$target"; then
    echo "accepted invalid target: $target" >&2
    exit 1
  fi
done

# --- remote reference retention ---------------------------------------------
JOBS="$WORK_DIR/jobs"
mkdir -p "$JOBS/remote" "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/bin/ssh"          # owner nodes unreachable
printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/bin/systemctl"
chmod 755 "$WORK_DIR/bin/ssh" "$WORK_DIR/bin/systemctl"
write_ref() {
  local unit="$1" registered="$2" refresh="$3"
  printf 'schema_version=1\nunit=%s\ntarget=101\nowner_node=pve2\nowner_host=192.0.2.2\nport=22\nregistered_at=%s\nstatus_refresh=%s\nworkspace=\n' \
    "$unit" "$registered" "$refresh" > "$JOBS/remote/$unit.ref"
}
for number in $(seq -w 1 60); do
  write_ref "ultimate-updater-update-101-old-$number" "2026-01-01T00:00:${number}Z" "done"
done
write_ref ultimate-updater-update-101-stale "2020-01-01T00:00:00Z" pending
write_ref ultimate-updater-update-101-fresh "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" pending
mkdir "$JOBS/remote/ultimate-updater-update-101-old-01.ref.refresh.lock"
UU_JOB_STATE_DIR="$JOBS" UU_MAX_COMPLETED_JOBS=50 PATH="$WORK_DIR/bin:$PATH" \
  UU_LOCAL_FILES="$WORK_DIR" bash "$RUNNER" list > "$WORK_DIR/list.out"
done_refs=$(grep -l '^status_refresh=done$' "$JOBS"/remote/*.ref | wc -l)
[[ "$done_refs" -eq 50 ]] || { echo "kept $done_refs finished refs instead of 50" >&2; exit 1; }
[[ ! -e "$JOBS/remote/ultimate-updater-update-101-old-10.ref" ]]
[[ -e "$JOBS/remote/ultimate-updater-update-101-old-11.ref" ]]
[[ ! -e "$JOBS/remote/ultimate-updater-update-101-stale.ref" ]]
[[ -e "$JOBS/remote/ultimate-updater-update-101-fresh.ref" ]]
[[ ! -e "$JOBS/remote/ultimate-updater-update-101-old-01.ref.refresh.lock" ]]

# --- a job that finishes during the systemd query stays finished -------------
RACE="$WORK_DIR/race"
mkdir -p "$RACE"
unit=ultimate-updater-update-202-race
started=$(date -u -d '-2 minutes' '+%Y-%m-%dT%H:%M:%SZ')
printf 'schema_version=1\nunit=%s\ntarget=202\nstate=running\nstarted_at=%s\nfinished_at=\nexit_code=\ntype=update\nmessage=\nsource=\n' \
  "$unit" "$started" > "$RACE/$unit.state"
cat > "$WORK_DIR/bin/systemctl" <<STUB
#!/bin/bash
# The job completes (and writes its final state) while systemd is queried.
sed -i 's/^state=running$/state=completed/; s/^exit_code=$/exit_code=0/' "$RACE/$unit.state"
printf 'ActiveState=inactive\nLoadState=loaded\n'
STUB
UU_JOB_STATE_DIR="$RACE" PATH="$WORK_DIR/bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" bash "$RUNNER" list >/dev/null
grep -Fxq 'state=completed' "$RACE/$unit.state"
grep -Fxq 'exit_code=0' "$RACE/$unit.state"

# --- a stale directory lock no longer blocks remote status refreshes ---------
STALE="$WORK_DIR/stale"
mkdir -p "$STALE/remote"
JOBS_BACKUP=$JOBS
JOBS=$STALE
write_ref ultimate-updater-update-303-stale-lock "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" pending
JOBS=$JOBS_BACKUP
sed -i 's/^target=101$/target=303/' "$STALE/remote/ultimate-updater-update-303-stale-lock.ref"
mkdir "$STALE/remote/ultimate-updater-update-303-stale-lock.ref.refresh.lock"
cat > "$WORK_DIR/bin/ssh" <<'STUB'
#!/bin/bash
# The owner reports the remote job as completed.
printf 'unit=ultimate-updater-update-303-stale-lock\ntarget=303\nstate=completed\nstarted_at=2026-01-01T00:00:00Z\nfinished_at=2026-01-01T00:05:00Z\nexit_code=0\n'
STUB
printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/bin/systemctl"
UU_JOB_STATE_DIR="$STALE" PATH="$WORK_DIR/bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" \
  UU_CHECK_CLI="$WORK_DIR/missing-cli" bash "$RUNNER" list >/dev/null 2>&1
grep -Fxq 'status_refresh=failed' "$STALE/remote/ultimate-updater-update-303-stale-lock.ref"

# --- remote results reach status.json only when they change ------------------
printf '{"schema_version": 1, "targets": [{"id": "303", "last_update": {"status": "unknown", "timestamp": null}}]}\n' \
  > "$WORK_DIR/status.json"
UU_JOB_STATE_DIR="$STALE" PATH="$WORK_DIR/bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" \
  UU_CHECK_CLI="$WORK_DIR/missing-cli" bash "$RUNNER" list >/dev/null 2>&1
python3 - "$WORK_DIR/status.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))["targets"][0]
assert record["last_update"] == {"status": "success", "timestamp": "2026-01-01T00:05:00Z", "exit_code": 0}, record
PY
[[ -e "$WORK_DIR/status.json.lock" ]]
before=$(stat -c '%i %Y' "$WORK_DIR/status.json")
sleep 1
UU_JOB_STATE_DIR="$STALE" PATH="$WORK_DIR/bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" \
  UU_CHECK_CLI="$WORK_DIR/missing-cli" bash "$RUNNER" list >/dev/null 2>&1
[[ "$(stat -c '%i %Y' "$WORK_DIR/status.json")" == "$before" ]] || { echo 'unchanged status.json was rewritten' >&2; exit 1; }

# --- remote hosts never start with "-" (they are ssh arguments) --------------
eval "$(sed -n '/^valid_remote_value() {/,/^}/p' "$RUNNER")"
valid_remote_value 192.0.2.2 && valid_remote_value pve-2.lan
! valid_remote_value -oProxyCommand=x && ! valid_remote_value ''

# --- a self-update conflicts with every running job and vice versa -----------
eval "$(sed -n '/^state_value() {/,/^}/p' "$RUNNER")"
eval "$(sed -n '/^running_job_conflict() {/,/^}/p' "$RUNNER")"
CONFLICT="$WORK_DIR/conflict"
mkdir -p "$CONFLICT"
JOB_STATE_DIR=$CONFLICT
printf 'unit=ultimate-updater-update-101-x\ntarget=101\nstate=running\n' > "$CONFLICT/a.state"
running_job_conflict selfupdate >/dev/null || { echo 'self-update started during a target job' >&2; exit 1; }
printf 'unit=ultimate-updater-update-selfupdate-x\ntarget=selfupdate\nstate=running\n' > "$CONFLICT/a.state"
running_job_conflict 102 >/dev/null || { echo 'target job started during a self-update' >&2; exit 1; }
printf 'unit=ultimate-updater-update-103-x\ntarget=103\nstate=running\n' > "$CONFLICT/a.state"
if running_job_conflict 104 >/dev/null; then echo 'unrelated targets conflict' >&2; exit 1; fi

# --- the payload does not inherit the target lock ----------------------------
LOCKS="$WORK_DIR/locks"
mkdir -p "$LOCKS"
cat > "$WORK_DIR/payload.sh" <<PAYLOAD
#!/bin/bash
if [[ -e /proc/self/fd/9 ]]; then echo inherited; else echo closed; fi > "$WORK_DIR/payload-fd"
PAYLOAD
chmod +x "$WORK_DIR/payload.sh"
UU_JOB_STATE_DIR="$LOCKS" PATH="$WORK_DIR/bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" \
  bash "$RUNNER" run ultimate-updater-update-host-fd host "$WORK_DIR/payload.sh" >/dev/null
[[ "$(cat "$WORK_DIR/payload-fd")" == closed ]] || { echo 'the payload inherited the target lock fd' >&2; exit 1; }
if UU_JOB_STATE_DIR="$LOCKS" bash "$RUNNER" run 'bad unit' host "$WORK_DIR/payload.sh" >/dev/null 2>&1; then
  echo 'run accepted an invalid unit' >&2
  exit 1
fi

echo 'job runner maintenance: PASS'
