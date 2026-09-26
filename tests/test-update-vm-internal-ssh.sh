#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # harness code runs in separate shells.
set -euo pipefail

# VM updates honor Internal SSH overrides the way checks and docs/ssh.md do:
# - an override without a legacy VMs/<id> profile selects SSH (it used to be
#   ignored, so the VM was updated over QGA or not at all);
# - a disabled override falls back to the guest agent (it used to skip the
#   VM silently);
# - an invalid internal-ssh.conf is reported as an error;
# - the SSH probe uses the override's identity file.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
{
  for function in VM_HAS_SSH_PROFILE UPDATE_VM; do
    sed -n "/^$function () {/,/^}/p" "$ROOT_DIR/update.sh"
  done
} > "$WORK_DIR/functions.sh"
grep -q '^VM_HAS_SSH_PROFILE () {' "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
LOCAL_FILES="$PWD/lf" TEMP_STATE_DIR="$PWD/lf" INTERNAL_SSH_CONFIG_FILE="$PWD/lf/internal-ssh.conf"
START_WAITING=false ERROR_CODE=""
mkdir -p "$LOCAL_FILES/VMs"
source "$ROOT_DIR/internal-ssh.sh"
source "$FUNCTIONS"
log() { printf '%s\n' "$*" >> "$LOG"; }
qm() { printf 'name: vm%s\n' "$2"; }
VM_BACKUP() { return 0; }
SCRIPT_ONLY_ENABLED() { return 1; }
UPDATE_VM_QEMU() { log "qga $VM"; }
ERROR() { log "error $ID: $ERROR_MSG"; }
RUN_SSH_COMMAND() { log "probe $1:$2 $3 identity=${RUN_SSH_IDENTITY_FILE:-none}"; return 1; }
case "$SCENARIO" in
  override-only)
    printf '[vm:201]\nhost=192.0.2.9\nport=2201\nidentity_file=/root/.ssh/vm201\n' > "$INTERNAL_SSH_CONFIG_FILE"
    UPDATE_VM 201 ;;
  disabled)
    printf 'IP="192.0.2.10"\nUSER="root"\n' > "$LOCAL_FILES/VMs/202"
    printf '[vm:202]\nhost=192.0.2.10\nenabled=false\n' > "$INTERNAL_SSH_CONFIG_FILE"
    UPDATE_VM 202 ;;
  invalid)
    printf 'IP="192.0.2.11"\n' > "$LOCAL_FILES/VMs/203"
    printf '[vm:203]\nbogus=1\n' > "$INTERNAL_SSH_CONFIG_FILE"
    UPDATE_VM 203 || log "returned $?" ;;
  none)
    : > "$INTERNAL_SSH_CONFIG_FILE"
    UPDATE_VM 204 ;;
esac
HARNESS

run() {
  rm -rf "${WORK_DIR:?}/lf" "$WORK_DIR/log"
  (cd "$WORK_DIR" && SCENARIO="$1" ROOT_DIR="$ROOT_DIR" FUNCTIONS="$WORK_DIR/functions.sh" LOG="$WORK_DIR/log" \
    bash harness.sh > /dev/null 2>&1)
  cat "$WORK_DIR/log"
}

[[ "$(run override-only)" == $'probe 192.0.2.9:2201 root identity=/root/.ssh/vm201\nqga 201' ]]
[[ "$(run disabled)" == 'qga 202' ]]
[[ "$(run invalid)" == $'error 203: Internal SSH configuration is invalid: unsupported key \'bogus\' at line 2\nreturned 1' ]]
[[ "$(run none)" == 'qga 204' ]]

# Stopped VMs are started for an override-only SSH profile too.
grep -Fq 'if QGA_CONFIG_ENABLED "$VM" || VM_HAS_SSH_PROFILE "$VM"; then' "$ROOT_DIR/update.sh"

echo 'VM updates with Internal SSH overrides: PASS'
