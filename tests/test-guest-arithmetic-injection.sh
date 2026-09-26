#!/usr/bin/env bash
# shellcheck disable=SC2016 # payloads and patterns are literal on purpose.
set -euo pipefail

# Guests and External hosts control the text they print. Bash evaluates the
# operands of [[ -gt ]] and (( )) as expressions, including array subscripts,
# so a count such as 'x[$(cmd)]' would run cmd as root on the Proxmox host.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
MARKER="$WORK_DIR/host-command-executed"
PAYLOAD="x[\$(touch $MARKER)]"

# --- GUEST_COUNT accepts plain counts only. ---------------------------------
eval "$(sed -n '/^GUEST_COUNT() {/,/^}/p' "$ROOT_DIR/check-updates.sh")"
[[ "$(GUEST_COUNT ' 7')" == 7 ]]
[[ "$(GUEST_COUNT $'12\n')" == 12 ]]
[[ "$(GUEST_COUNT 08)" == 8 ]]
for invalid in '' 'abc' '-1' '1e3' '0x10' '1234567890' "$PAYLOAD"; do
  if GUEST_COUNT "$invalid" >/dev/null; then
    echo "GUEST_COUNT accepted: $invalid" >&2
    exit 1
  fi
done
[[ ! -e "$MARKER" ]]

# --- The real LXC check path with a hostile Alpine container. ---------------
awk '/^# Container Check$/,/^## VM ##/' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/container-functions.sh"
cat > "$WORK_DIR/harness.sh" <<'HARNESS'
# Mirror check-updates.sh, which runs without nounset: under set -u bash
# would reject the unset array name before expanding the subscript.
set -o pipefail
LOCAL_FILES="$PWD"; mkdir -p "$LOCAL_FILES/temp"
RDU=false INITIAL_INVENTORY=false CHECK_URL=example.invalid EXE_FOR_INTERNET_CHECK=ping
STATUS_MODEL_NODE=test-node STATUS_MODEL_GUEST_NAME=hostile BL='' OR='' RD='' GN='' CL=''
record() { printf '%s\n' "$*" >> "$RECORD_LOG"; }
STATUS_MODEL_RECORD() { record "status $*"; }
cluster_target_guest_name() { printf 'hostile\n'; }
GUEST_INTERNET_PREFLIGHT_PCT() { return 0; }
pct() { [[ "${1:-}" == config ]] && printf 'ostype: alpine\n'; return 0; }
RUN_PCT_COMMAND() {
  case "$*" in
    *'apk list -u'*) printf '%s\n' "$PAYLOAD" ;;
    *hostname*) printf 'hostile\n' ;;
  esac
  return 0
}
source "$GUEST_COUNT_FUNCTIONS"
source "$CONTAINER_FUNCTIONS"
CHECK_CONTAINER 150 || true
HARNESS
sed -n '/^GUEST_COUNT() {/,/^}/p' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/guest-count.sh"
(cd "$WORK_DIR" && PAYLOAD="$PAYLOAD" RECORD_LOG="$WORK_DIR/records" \
  GUEST_COUNT_FUNCTIONS="$WORK_DIR/guest-count.sh" CONTAINER_FUNCTIONS="$WORK_DIR/container-functions.sh" \
  bash "$WORK_DIR/harness.sh" >"$WORK_DIR/lxc.out" 2>&1) || true  # the marker below is the verdict
if [[ -e "$MARKER" ]]; then
  echo 'LXC output was executed on the host' >&2
  exit 1
fi
grep -Fq 'error CHECK_COMMAND_FAILED Unexpected update count reported by LXC 150' "$WORK_DIR/records"

# --- External targets: the UU_RESULT line comes from the remote host. -------
mkdir -p "$WORK_DIR/fake-bin"
cat > "$WORK_DIR/fake-bin/ssh" <<'FAKE_SSH'
#!/bin/bash
cat >/dev/null
printf 'UU_RESULT|ok|Debian|13|%s|false|apt|||\n' "$REMOTE_UPDATES"
FAKE_SSH
chmod 755 "$WORK_DIR/fake-bin/ssh"
printf '[hostile]\nhost=hostile-target\ntransport=ssh\nuser=root\nport=22\n' > "$WORK_DIR/targets.conf"
run_external_check() {
  REMOTE_UPDATES="$1" PATH="$WORK_DIR/fake-bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" \
    TARGET_INVENTORY_FILE="$WORK_DIR/targets.conf" TARGET_INVENTORY_SCRIPT="$ROOT_DIR/target-inventory.sh" \
    STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh" TARGET_RUNTIME_SCRIPT="$ROOT_DIR/target-runtime.sh" \
    STATUS_MODEL_FILE="$WORK_DIR/external-status.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/external-records" \
    UU_SSH_COMMAND_TIMEOUT=5 "$ROOT_DIR/external-apt.sh" check hostile >"$WORK_DIR/external.out" 2>&1
}
if run_external_check "$PAYLOAD"; then
  echo 'external check accepted a non-numeric update count' >&2
  exit 1
fi
[[ ! -e "$MARKER" ]] || { echo 'External host output was executed on the host' >&2; exit 1; }
grep -Fq 'invalid update count' "$WORK_DIR/external.out"
run_external_check 3
grep -Fq '"available": 3' "$WORK_DIR/external-status.json"

# --- No guest command output may be compared inline. ------------------------
scripts=("$ROOT_DIR"/*.sh "$ROOT_DIR/ultimate-updater")
if grep -nE '\[\[ *"?\$\((pct|qm|ssh|RUN_PCT_COMMAND|RUN_SSH_COMMAND|RUN_QEMU)[^]]*-(gt|lt|ge|le|eq|ne) ' "${scripts[@]}"; then
  echo 'guest command output is compared arithmetically without validation' >&2
  exit 1
fi

echo 'guest arithmetic injection: PASS'
