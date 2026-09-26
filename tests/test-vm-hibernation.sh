#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # harness code runs in separate shells.
set -euo pipefail

# Hibernated VMs (qm suspend --todisk) report "stopped" and keep their RAM in
# a vmstate volume. The check compared the lock with "suspend" (the values are
# "suspending"/"suspended"), so it resumed them and then hard-stopped them,
# discarding the saved state; the update path had no guard at all. A VM
# booted only for a check is now shut down cleanly instead of `qm stop`.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

{
  sed -n '/^VM_IS_HIBERNATED() {/,/^}/p' "$ROOT_DIR/target-runtime.sh"
  sed -n '/^CHECK_VM_LIFECYCLE () {/,/^}/p' "$ROOT_DIR/check-updates.sh"
  for function in RESET_TARGET_STATE STOP_AFTER_FAILURE VM_UPDATE_START; do
    sed -n "/^$function () {/,/^}/p" "$ROOT_DIR/update.sh"
  done
  sed -n '/^guest_id_matches() {/,/^}/p' "$ROOT_DIR/tag-filter.sh"
} > "$WORK_DIR/functions.sh"
grep -q '^VM_IS_HIBERNATED() {' "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/common.sh" <<'HARNESS'
source "$FUNCTIONS"
log() { printf '%s\n' "$*" >> "$LOG"; }
qm() {
  case "$1" in
    status) echo 'status: stopped' ;;
    list) printf '      VMID NAME\n       301 sleeper\n       302 plain\n' ;;
    config)
      printf 'name: vm%s\nostype: l26\nagent: 1\n' "$2"
      case "$2" in
        301) printf 'lock: suspended\nvmstate: local-lvm:vm-301-state-suspend-2026-09-01\n' ;;
        303) printf 'lock: suspending\n' ;;
      esac
      ;;
  esac
}
RUN_PROXMOX_COMMAND() { log "proxmox $*"; }
STATUS_MODEL_RECORD() { log "record $1 ${9} ${10}"; }
HARNESS

# --- detection ---------------------------------------------------------------------
FUNCTIONS="$WORK_DIR/functions.sh" LOG=/dev/null bash -c '
  source "$1"
  VM_IS_HIBERNATED 301 && VM_IS_HIBERNATED 303 && ! VM_IS_HIBERNATED 302' _ "$WORK_DIR/common.sh"

# --- check: skip hibernated, shut down cleanly otherwise ----------------------------------
cat > "$WORK_DIR/check.sh" <<'HARNESS'
source "$COMMON"
STOPPED_VM=true VM_START_DELAY=0 LOCAL_FILES="$PWD" INITIAL_INVENTORY=false
SANITIZE_NUMBER() { tr -cd '0-9' <<< "$1"; }
WAIT_FOR_QGA() { return 0; }
timeout() { shift; "$@"; }   # reach the qm stub
CHECK_VM() { log "check $1"; }
CHECK_VM_LIFECYCLE 301
CHECK_VM_LIFECYCLE 302
HARNESS
(cd "$WORK_DIR" && COMMON="$WORK_DIR/common.sh" FUNCTIONS="$WORK_DIR/functions.sh" LOG="$WORK_DIR/check.log" \
  bash check.sh > /dev/null)
log="$WORK_DIR/check.log"
grep -Fxq 'record 301 not_checked HIBERNATED_READ_ONLY' "$log"
if grep -Eq 'proxmox qm (start|stop|shutdown) 301' "$log"; then echo 'the check woke a hibernated VM' >&2; exit 1; fi
grep -Fxq 'proxmox qm start 302' "$log"
grep -Fxq 'check 302' "$log"
grep -Fxq 'proxmox qm shutdown 302 --timeout 120 --forceStop 1' "$log"
if grep -q 'qm stop' "$log"; then echo 'hard stop after a read-only check' >&2; exit 1; fi

# --- update: hibernated VMs are skipped --------------------------------------------------------
cat > "$WORK_DIR/update.sh" <<'HARNESS'
source "$COMMON"
EXCLUDED="" ONLY="" SINGLE_UPDATE=false STOPPED_VM=true RUNNING_VM=true UPDATE_FAILURE=false
EXIT_ON_ERROR=false LOCAL_FILES="$PWD"
QGA_CONFIG_ENABLED() { return 0; }
CAPTURE_POST_UPDATE_STATUS() { :; }
UPDATE_VM() { log "update $1"; }
VM_UPDATE_START
wait
HARNESS
(cd "$WORK_DIR" && COMMON="$WORK_DIR/common.sh" FUNCTIONS="$WORK_DIR/functions.sh" LOG="$WORK_DIR/update.log" \
  bash update.sh > "$WORK_DIR/update.out")
log="$WORK_DIR/update.log"
if grep -Eq '(start|update) 301' "$log"; then echo 'the update woke a hibernated VM' >&2; exit 1; fi
grep -Fq 'Skipped VM 301 because it is hibernated' "$WORK_DIR/update.out"
grep -Fxq 'proxmox qm start 302' "$log"
grep -Fxq 'update 302' "$log"

echo 'hibernated VM handling: PASS'
