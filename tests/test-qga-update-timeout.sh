#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # stubs and globals are used by the extracted functions.
set -euo pipefail

# Package steps run through the QEMU Guest Agent used qm's 30-second default
# wait (120 s for the APT upgrade). After the wait ended the updater shut
# down a VM it had started for the update while dpkg/dnf was still running
# inside it. Package steps now wait up to QGA_UPDATE_TIMEOUT, and a VM whose
# guest job may still be running is left running.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# --- durable guest jobs -------------------------------------------------------
# shellcheck disable=SC1091
source "$ROOT_DIR/qga-guest-exec.sh"
POLL_RESULTS=()
poll_count=0
QEMU_GUEST_EXEC() {
  QEMU_EXEC_STDOUT="" QEMU_EXEC_STDERR="" QEMU_EXEC_OUTPUT="" QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_TRANSPORT_RC=0 QEMU_EXEC_ERROR_CLASS=""
  [[ "$*" == *systemd-run* || "$*" == *'rm -f'* ]] && return 0   # launch and cleanup
  local result="${POLL_RESULTS[$poll_count]:-done}"
  poll_count=$((poll_count + 1))
  case "$result" in
    pending) QEMU_EXEC_EXITCODE=75 ;;
    broken) QEMU_EXEC_EXITCODE=3 ;;
    done) QEMU_EXEC_STDOUT=$'upgraded\n__UU_GUEST_EXIT__0' ;;
  esac
}

# A timeout of 0 waits without limit, as it does for QEMU_GUEST_EXEC; it used
# to end the wait on the first "still running" poll.
POLL_RESULTS=(pending pending done) poll_count=0
SECONDS=100   # the old deadline arithmetic only misbehaved once SECONDS > 0
QEMU_GUEST_EXEC_DURABLE 700 --timeout 0 -- bash -c 'dnf -y upgrade'
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 0 ]] ||
  { echo "timeout 0 ended the wait: $QEMU_EXEC_OUTPUT" >&2; exit 1; }

# An unreadable job status keeps its own error instead of being reported as
# a timeout.
POLL_RESULTS=(broken) poll_count=0
QEMU_GUEST_EXEC_DURABLE 700 --timeout 60 -- bash -c 'dnf -y upgrade'
[[ "$QEMU_EXEC_ERROR_CLASS" == QGA_GUEST_EXEC_STATUS ]]
[[ "$QEMU_EXEC_OUTPUT" == 'Invalid durable guest-job status' ]]

# --- package steps use the update timeout -------------------------------------
{
  sed -n '/^QGA_NOTE_UNFINISHED_JOB () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^RUN_QEMU_COMMAND () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^RUN_QEMU_DURABLE () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^RESET_TARGET_STATE () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^UPDATE_VM_QEMU () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^VM_UPDATE_START () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^guest_id_matches() {/,/^}/p' "$ROOT_DIR/tag-filter.sh"
} > "$WORK_DIR/functions.sh"
awk '/^QGA_UPDATE_TIMEOUT=/ { print; getline; print }' "$ROOT_DIR/update.sh" > "$WORK_DIR/settings.sh"
[[ $(wc -l < "$WORK_DIR/settings.sh") == 2 ]]

cat > "$WORK_DIR/package-harness.sh" <<'HARNESS'
set -o pipefail
source "$SETTINGS"
source "$FUNCTIONS"
VM=700 FREEBSD_UPDATES=true INCLUDE_PHASED_UPDATES=false DPKG_OPTIONS_STRING="-o x" CHECK_URL_EXE=ping CHECK_URL=example.org
log() { printf '%s\n' "$*" >> "$LOG"; }
WAIT_FOR_QGA() { return 0; }
CHECK_QGA_EXEC() { return 0; }
UPDATE_CHECK() { :; }
ERROR() { log "error $ERROR_CODE"; }
qm() {
  case "$GUEST" in
    freebsd) printf '"kernel-version" : "FreeBSD 14.3"\n"name" : "FreeBSD"\n' ;;
    debian) printf '"kernel-version" : "#1 SMP"\n"name" : "Debian GNU/Linux"\n' ;;
    fedora) printf '"kernel-version" : "#1 SMP"\n"name" : "Fedora Linux"\n' ;;
    arch) printf '"kernel-version" : "#1 SMP"\n"name" : "Arch Linux"\n' ;;
    alpine) printf '"kernel-version" : "#1 SMP"\n"name" : "Alpine Linux"\n' ;;
    centos) printf '"kernel-version" : "#1 SMP"\n"name" : "CentOS Stream"\n' ;;
  esac
}
QEMU_GUEST_EXEC() {
  QEMU_EXEC_STDOUT="" QEMU_EXEC_STDERR="" QEMU_EXEC_OUTPUT="" QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_TRANSPORT_RC=0 QEMU_EXEC_ERROR_CLASS=""
  log "exec $*"
}
QEMU_GUEST_EXEC_DURABLE() {
  QEMU_EXEC_STDOUT="" QEMU_EXEC_STDERR="" QEMU_EXEC_OUTPUT="" QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_TRANSPORT_RC=0 QEMU_EXEC_ERROR_CLASS=""
  log "durable $*"
}
UPDATE_VM_QEMU
HARNESS

for guest in freebsd debian fedora arch alpine centos; do
  : > "$WORK_DIR/$guest.log"
  GUEST=$guest LOG="$WORK_DIR/$guest.log" SETTINGS="$WORK_DIR/settings.sh" FUNCTIONS="$WORK_DIR/functions.sh" \
    UU_QGA_UPDATE_TIMEOUT=5400 bash "$WORK_DIR/package-harness.sh" > "$WORK_DIR/$guest.out" 2>&1
  # Every package step (all but the ping of the Internet check) waits long
  # enough for a real upgrade.
  steps=$(grep -Ec '^(exec|durable) ' "$WORK_DIR/$guest.log" || true)
  (( steps > 0 )) || { echo "$guest: no package step ran" >&2; cat "$WORK_DIR/$guest.out" >&2; exit 1; }
  if grep -E '^(exec|durable) ' "$WORK_DIR/$guest.log" | grep -v ' ping ' | grep -Fv -- '--timeout 5400 '; then
    echo "$guest: a package step uses the short default wait" >&2
    exit 1
  fi
  if grep -Fq 'error ' "$WORK_DIR/$guest.log"; then
    echo "$guest: unexpected error" >&2
    exit 1
  fi
done
# Transactional upgrades on systemd guests survive a qemu-ga restart.
grep -Fq 'durable 700 --timeout 5400 -- bash -c DEBIAN_FRONTEND=noninteractive apt-get -o x upgrade -y' "$WORK_DIR/debian.log"
grep -Fq 'durable 700 --timeout 5400 -- bash -c dnf -y upgrade' "$WORK_DIR/fedora.log"
grep -Fq 'durable 700 --timeout 5400 -- bash -c pacman -Syu --noconfirm' "$WORK_DIR/arch.log"
grep -Fq 'durable 700 --timeout 5400 -- bash -c yum -y update' "$WORK_DIR/centos.log"
# Alpine (OpenRC) and FreeBSD have no systemd-run.
if grep -q '^durable ' "$WORK_DIR/alpine.log" "$WORK_DIR/freebsd.log"; then
  echo 'a guest without systemd uses the durable runner' >&2
  exit 1
fi

# An invalid override falls back to the default instead of reaching qm.
for value in abc 0 -5 '1;id' 99999999; do
  (
    UU_QGA_UPDATE_TIMEOUT=$value
    # shellcheck disable=SC1091
    source "$WORK_DIR/settings.sh"
    [[ "$QGA_UPDATE_TIMEOUT" == 3600 ]] || { echo "accepted timeout: $value" >&2; exit 1; }
  )
done

# --- a VM started for the update is not shut down under a running job ------
cat > "$WORK_DIR/stop-harness.sh" <<'HARNESS'
set -o pipefail
source "$SETTINGS"
source "$FUNCTIONS"
LOCAL_FILES="$HARNESS_DIR" EXCLUDED="" ONLY="" SINGLE_UPDATE=false
STOPPED_VM=true RUNNING_VM=true UPDATE_FAILURE=false
log() { printf '%s\n' "$*" >> "$LOG"; }
qm() {
  case "$1" in
    list) printf '      VMID NAME\n       701 slow\n       702 quick\n' ;;
    config) printf 'name: vm%s\nostype: l26\nagent: 1\n' "$2" ;;
    status) printf 'status: stopped\n' ;;
  esac
}
RUN_PROXMOX_COMMAND() { log "proxmox $*"; }
CAPTURE_POST_UPDATE_STATUS() { :; }
QGA_CONFIG_ENABLED() { return 0; }
ERROR() { log "error $ID $ERROR_CODE"; }
QEMU_GUEST_EXEC_DURABLE() {
  QEMU_EXEC_STDOUT="" QEMU_EXEC_STDERR="" QEMU_EXEC_EXITCODE="" QEMU_EXEC_TRANSPORT_RC=0 QEMU_EXEC_ERROR_CLASS=""
  QEMU_EXEC_OUTPUT="upgraded"
  if [[ "$1" == 701 ]]; then
    QEMU_EXEC_ERROR_CLASS=QGA_TIMEOUT QEMU_EXEC_TRANSPORT_RC=1
    QEMU_EXEC_OUTPUT="Durable guest update job did not finish within 3600s; it was not terminated"
  else
    QEMU_EXEC_EXITCODE=0
  fi
}
UPDATE_VM() {
  RUN_QEMU_DURABLE "$1" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c 'apt-get upgrade -y' ||
    { ERROR_CODE=$?; ID=$1; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
}
VM_UPDATE_START
wait
HARNESS
HARNESS_DIR="$WORK_DIR" LOG="$WORK_DIR/stop.log" SETTINGS="$WORK_DIR/settings.sh" FUNCTIONS="$WORK_DIR/functions.sh" \
  bash "$WORK_DIR/stop-harness.sh" > "$WORK_DIR/stop.out" 2>&1
grep -Fxq 'proxmox qm start 701' "$WORK_DIR/stop.log"
grep -Fxq 'error 701 1' "$WORK_DIR/stop.log"
if grep -Fxq 'proxmox qm shutdown 701' "$WORK_DIR/stop.log"; then
  echo 'VM 701 was shut down while its package job may still run' >&2
  exit 1
fi
grep -Fq 'VM 701 may still run a package job; it is left running' "$WORK_DIR/stop.out"
# The flag is per target: the next VM is stopped again after its update.
grep -Fxq 'proxmox qm start 702' "$WORK_DIR/stop.log"
grep -Fxq 'proxmox qm shutdown 702' "$WORK_DIR/stop.log"

echo 'QGA package-step timeouts: PASS'
