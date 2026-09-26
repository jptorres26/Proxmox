#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # harness code runs in a separate shell.
set -euo pipefail

# The update loops must reset per-target state (a failed LXC used to make every
# later VM skip its upgrade), recognize templates exactly, and skip paused VMs
# without reporting a failure.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

{
  sed -n '/^RESET_TARGET_STATE () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^CONTAINER_UPDATE_START () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^VM_UPDATE_START () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^guest_id_matches() {/,/^}/p' "$ROOT_DIR/tag-filter.sh"
} > "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
set -o pipefail
source "$FUNCTIONS"
LOCAL_FILES="$HARNESS_DIR" TEMP_STATE_DIR="$HARNESS_DIR/state" EXCLUDED="" ONLY="" SINGLE_UPDATE=false
STOPPED_CONTAINER=true RUNNING_CONTAINER=true STOPPED_VM=true RUNNING_VM=true UPDATE_FAILURE=false
log() { printf '%s\n' "$*" >> "$LOG"; }
pct() {
  case "$1" in
    list) printf 'VMID       Status     Lock         Name\n101        running                 broken\n' ;;
    config) printf 'ostype: debian\nhostname: broken\n' ;;
    status) printf 'status: running\n' ;;
  esac
}
qm() {
  case "$1" in
    list) printf '      VMID NAME\n       201 nginx-template\n       202 golden\n       203 sleeper\n       204 web\n' ;;
    config)
      case "$2" in
        201) printf 'name: nginx-template\nostype: l26\ndescription: built from a template\n' ;;
        202) printf 'name: golden\nostype: l26\ntemplate: 1\n' ;;
        *) printf 'name: vm%s\nostype: l26\n' "$2" ;;
      esac
      ;;
    status) if [[ "$2" == 203 ]]; then printf 'status: paused\n'; else printf 'status: running\n'; fi ;;
  esac
}
RUN_PROXMOX_COMMAND() { :; }
CAPTURE_POST_UPDATE_STATUS() { :; }
QGA_CONFIG_ENABLED() { return 0; }
UPDATE_CONTAINER() {
  CCONTAINER=true UPDATE_USER="sudo "
  ERROR_CODE=100 ERROR_MSG="apt failed" UPDATE_FAILURE=true
}
UPDATE_VM() { log "update-vm $1 error_code=[${ERROR_CODE}] update_user=[${UPDATE_USER}] ccontainer=[${CCONTAINER}]"; }
CONTAINER_UPDATE_START
UPDATE_FAILURE=false
VM_UPDATE_START
log "update_failure=$UPDATE_FAILURE"
HARNESS

HARNESS_DIR="$WORK_DIR" LOG="$WORK_DIR/log" FUNCTIONS="$WORK_DIR/functions.sh" \
  bash "$WORK_DIR/harness.sh" > "$WORK_DIR/output" 2>&1

# VM 201 only mentions "template" in its name and description: it is updated.
grep -Fxq 'update-vm 201 error_code=[] update_user=[] ccontainer=[]' "$WORK_DIR/log"
grep -Fxq 'update-vm 204 error_code=[] update_user=[] ccontainer=[]' "$WORK_DIR/log"
# The real template and the paused VM are skipped without an update attempt.
if grep -Eq 'update-vm (202|203) ' "$WORK_DIR/log"; then
  echo 'a template or paused VM was updated' >&2
  exit 1
fi
grep -Fq 'VM 202 is a template - skip update' "$WORK_DIR/output"
grep -Fq 'Skipped VM 203 because it is paused' "$WORK_DIR/output"
# Skipping a paused VM is not a failure.
grep -Fxq 'update_failure=false' "$WORK_DIR/log"

echo 'update target state reset: PASS'
