#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # harness code runs in separate shells.
set -euo pipefail

# Run control in update.sh: set -e pitfalls, EXIT_ON_ERROR, guest listing
# failures, fstrim options, node SSH ports, local-node detection, and the
# EXIT trap that could delete the installation.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
UPDATE="$ROOT_DIR/update.sh"

extract() { sed -n "/^$1 \{0,1\}() {/,/^}/p" "$UPDATE"; }
{
  for function in UPDATE_CHECK DIST_UPGRADE TRIM_FILESYSTEM STOP_AFTER_FAILURE RESET_TARGET_STATE \
    CONTAINER_UPDATE_START HOST_UPDATE_START UPDATE_HOST_IS_LOCAL UPDATE_HOST; do
    extract "$function"
  done
  sed -n '/^guest_id_matches() {/,/^}/p' "$ROOT_DIR/tag-filter.sh"
} > "$WORK_DIR/functions.sh"
for function in UPDATE_CHECK DIST_UPGRADE TRIM_FILESYSTEM STOP_AFTER_FAILURE CONTAINER_UPDATE_START \
  HOST_UPDATE_START UPDATE_HOST_IS_LOCAL UPDATE_HOST; do
  grep -Eq "^$function ?\(\) \{" "$WORK_DIR/functions.sh" || { echo "missing $function" >&2; exit 1; }
done

run() {  # run <name>: harness body on stdin, production shell options (no -u)
  cat > "$WORK_DIR/$1.sh"
  (cd "$WORK_DIR" && FUNCTIONS="$WORK_DIR/functions.sh" LOG="$WORK_DIR/$1.log" bash "$WORK_DIR/$1.sh")
}

# --- UPDATE_CHECK succeeds for a guest that will be stopped (set -e) --------------
run welcome <<'HARNESS'
set -e
source "$FUNCTIONS"
WELCOME_SCREEN=true WILL_STOP=true CVM=true VM=105 LOCAL_FILES=$PWD
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$LOG" > check-updates.sh
chmod +x check-updates.sh
UPDATE_CHECK >/dev/null
echo reached-after >> "$LOG"
HARNESS
grep -Fxq -- '-u cvm 105' "$WORK_DIR/welcome.log"
grep -Fxq reached-after "$WORK_DIR/welcome.log"

# --- DIST_UPGRADE: set -e does not leak, deb822 guests, too little space ----------
run dist <<'HARNESS'
source "$FUNCTIONS"
CONTAINER=300 DPKG_OPTIONS_STRING="" ERROR_CODE=""
CONTAINER_BACKUP() { return 0; }
ERROR() { echo "error $ERROR_MSG" >> "$LOG"; }
pct() {
  shift 3  # exec 300 --
  printf '%s\n' "$*" >> "$LOG"
  case "$*" in
    *VERSION_ID*) echo 12 ;;
    *'df --output'*) echo " ${FREE_GB}G" ;;
  esac
  return 0
}
FREE_GB=20 DIST_UPGRADE <<< $'y\ny' >/dev/null
[[ $- != *e* ]] && echo 'errexit restored' >> "$LOG"
FREE_GB=2 DIST_UPGRADE <<< $'y\ny' >/dev/null || echo "returned $?" >> "$LOG"
echo 'still running' >> "$LOG"
HARNESS
grep -Fxq 'errexit restored' "$WORK_DIR/dist.log"
grep -Fq "[ ! -f /etc/apt/sources.list ] || sed -i 's/bookworm/trixie/g' /etc/apt/sources.list" "$WORK_DIR/dist.log"
grep -Fxq 'error Less than 5 GB free on / - distribution upgrade not started' "$WORK_DIR/dist.log"
grep -Fxq 'returned 1' "$WORK_DIR/dist.log"
grep -Fxq 'still running' "$WORK_DIR/dist.log"   # no `exit 100` from the middle of a run

# --- fstrim: mount point option and this container's disks only ---------------------
run trim <<'HARNESS'
source "$FUNCTIONS"
CONTAINER=101 INCLUDE_FSTRIM=true
df() { printf 'Filesystem Type\n/dev/x ext4\n'; }
lvs() {
  printf '  LV VG Attr LSize Pool Origin Data%%\n'
  printf '  vm-101-disk-0 pve Vwi-aotz-- 8.00g data  12.50\n'
  printf '  vm-1010-disk-0 pve Vwi-aotz-- 8.00g data  99.00\n'
}
pct() { printf '%s\n' "$*" >> "$LOG"; }
sleep() { :; }
FSTRIM_WITH_MOUNTPOINT=true TRIM_FILESYSTEM > trim-true.out
FSTRIM_WITH_MOUNTPOINT=false TRIM_FILESYSTEM > /dev/null
HARNESS
[[ "$(cat "$WORK_DIR/trim.log")" == $'fstrim 101 --ignore-mountpoints 0\nfstrim 101 --ignore-mountpoints 1' ]]
grep -Fq 'Data before trim: 12.50%' "$WORK_DIR/trim-true.out"

# --- EXIT_ON_ERROR=true skips the remaining guests; listing failures count ---------------
cat > "$WORK_DIR/loop-common.sh" <<'HARNESS'
source "$FUNCTIONS"
EXCLUDED="" ONLY="" SINGLE_UPDATE=false RUNNING_CONTAINER=true STOPPED_CONTAINER=true
UPDATE_FAILURE=false SAFETY_FAILURE=false
pct() {
  case "$1" in
    list) [[ "${PCT_LIST_FAILS:-false}" == true ]] && return 1
      printf 'VMID       Status     Lock         Name\n101        running                 a\n102        running                 b\n' ;;
    config) printf 'ostype: debian\n' ;;
    status) printf 'status: running\n' ;;
  esac
}
CAPTURE_POST_UPDATE_STATUS() { :; }
UPDATE_CONTAINER() {
  echo "update $1" >> "$LOG"
  [[ "$1" == 101 ]] && UPDATE_FAILURE=true
  return 0
}
HARNESS
run stop <<'HARNESS'
source loop-common.sh
EXIT_ON_ERROR=true CONTAINER_UPDATE_START > stop.out
HARNESS
[[ "$(cat "$WORK_DIR/stop.log")" == 'update 101' ]]
grep -Fq 'Skipped LXC 102: an earlier update failed' "$WORK_DIR/stop.out"
run continue <<'HARNESS'
source loop-common.sh
EXIT_ON_ERROR=false CONTAINER_UPDATE_START > /dev/null
HARNESS
[[ "$(cat "$WORK_DIR/continue.log")" == $'update 101\nupdate 102' ]]
run listing <<'HARNESS'
source loop-common.sh
EXIT_ON_ERROR=false PCT_LIST_FAILS=true CONTAINER_UPDATE_START > /dev/null
echo "update_failure=$UPDATE_FAILURE" >> "$LOG"
HARNESS
grep -Fxq 'update_failure=true' "$WORK_DIR/listing.log"

# --- node loop: a port override applies to its node only -------------------------------
run ports <<'HARNESS'
source "$FUNCTIONS"
HOSTS="192.0.2.1 192.0.2.2" SSH_PORT=22 RICM=true EXIT_ON_ERROR=false UPDATE_FAILURE=false
INTERNAL_SSH_RESOLVE_NODE() {
  INTERNAL_SSH_HOST="" INTERNAL_SSH_PORT="" INTERNAL_SSH_ENABLED=true
  [[ "$2" == 192.0.2.1 ]] && INTERNAL_SSH_PORT=2222
  return 0
}
INTERNAL_SSH_USE_IDENTITY() { :; }
ssh() { return 0; }
UPDATE_HOST() { echo "$1:$SSH_PORT" >> "$LOG"; }
HOST_UPDATE_START
echo "global:$SSH_PORT" >> "$LOG"
HARNESS
[[ "$(cat "$WORK_DIR/ports.log")" == $'192.0.2.1:2222\n192.0.2.2:22\nglobal:22' ]]

# --- UPDATE_HOST: local detection, scp port, IPv6 ---------------------------------------
run copy <<'HARNESS'
source "$FUNCTIONS"
LOCAL_FILES="$PWD/lf" HOSTNAME=pve1 SSH_PORT=2222 WELCOME_SCREEN=false HEADLESS=false
mkdir -p "$LOCAL_FILES/VMs"
touch "$LOCAL_FILES/update-extras.sh" "$LOCAL_FILES/update.conf" "$LOCAL_FILES/tag-filter.sh"
hostname() {
  case "${1:-}" in
    -I) echo '192.0.2.10 10.10.10.1' ;;
    -i) echo '192.0.2.10' ;;
    -s) echo pve1 ;;
    -f) echo pve1.example.org ;;
  esac
}
ssh() { echo "ssh $*" >> "$LOG"; return 0; }
scp() { echo "scp $*" >> "$LOG"; }
HOST_NODE=pve1 UPDATE_HOST 10.10.10.1 < /dev/null     # corosync address of this node
echo '--' >> "$LOG"
HOST_NODE=pve2 UPDATE_HOST 10.10.10.2 < /dev/null
echo '--' >> "$LOG"
HOST_NODE=pve3 UPDATE_HOST 2001:db8::3 < /dev/null
HARNESS
local_part=$(sed -n '1,/^--$/p' "$WORK_DIR/copy.log")
if grep -q '^scp ' <<< "$local_part"; then
  echo 'the local node copied its installation onto itself' >&2
  exit 1
fi
grep -Fq "scp -P 2222 $WORK_DIR/lf/update.conf 10.10.10.2:$WORK_DIR/lf/update.conf" "$WORK_DIR/copy.log"
grep -Fq "scp -P 2222 -r $WORK_DIR/lf/VMs/ 10.10.10.2:$WORK_DIR/lf/" "$WORK_DIR/copy.log"
grep -Fq "scp -P 2222 $WORK_DIR/lf/tag-filter.sh [2001:db8::3]:$WORK_DIR/lf/tag-filter.sh" "$WORK_DIR/copy.log"
if grep -E '^scp ' "$WORK_DIR/copy.log" | grep -v -- '-P 2222'; then
  echo 'scp without the SSH port' >&2
  exit 1
fi

# --- static guarantees ---------------------------------------------------------------------
# The error log is reset on every run, not only with EXIT_ON_ERROR=false.
awk '/^ERROR_LOGGING$/ {found = 1} END {exit !found}' "$UPDATE"
# The EXIT trap never deletes the installation.
if grep -nE 'rm -rf "\$LOCAL_FILES"( |;|$)' "$UPDATE"; then
  echo 'update.sh can still remove LOCAL_FILES' >&2
  exit 1
fi

echo 'update run control: PASS'
