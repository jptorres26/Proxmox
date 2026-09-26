#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # harness code runs in separate shells.
set -euo pipefail

# Guest update steps and guest files:
# - a failed step runs once (it used to be repeated to capture its output);
# - extras and user scripts use a private work directory in the guest, and
#   no cleanup removes $LOCAL_FILES there (it wiped nested installations);
# - copies to SSH guests use the configured port and user;
# - script paths reach the guest as arguments, not re-parsed strings.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
UPDATE="$ROOT_DIR/update.sh"

{
  for function in RUN_STEP ERROR GUEST_WORKDIR GUEST_COPY GUEST_EXEC GUEST_REMOVE SCRIPT_ONLY_FILES \
    RUN_USER_SCRIPTS USER_SCRIPTS_RUN SCRIPT_ONLY_ENABLED SCRIPT_ONLY_RUN SCRIPT_ONLY_LXC \
    SCRIPT_ONLY_SSH_VM SCRIPT_ONLY_QEMU_VM EXTRAS; do
    sed -n "/^$function () {/,/^}/p" "$UPDATE"
    grep -q "^$function () {" "$UPDATE" || { echo "missing $function" >&2; exit 1; }
  done
  grep '^GUEST_WORK_DIR_RE=' "$UPDATE"
} > "$WORK_DIR/functions.sh"

run() {
  cat > "$WORK_DIR/$1.sh"
  (cd "$WORK_DIR" && FUNCTIONS="$WORK_DIR/functions.sh" LOG="$WORK_DIR/$1.log" bash "$WORK_DIR/$1.sh")
}

# --- RUN_STEP runs a failing command once and keeps its output ------------------
run step <<'HARNESS'
set -e   # EXIT_ON_ERROR=true
source "$FUNCTIONS"
ERROR_LOG_FILE="$PWD/errors" NAME=web UPDATE_FAILURE=false
attempt() { echo "attempt" >> "$LOG"; printf 'E: Sub-process /usr/bin/dpkg returned an error code (1)\n'; return 100; }
RUN_STEP 101 attempt > step.out
echo "after code=$ERROR_CODE id=$ID failure=$UPDATE_FAILURE" >> "$LOG"
ERROR_CODE=""
RUN_STEP 101 true > /dev/null
echo "success code=[$ERROR_CODE]" >> "$LOG"
HARNESS
[[ "$(grep -c '^attempt$' "$WORK_DIR/step.log")" == 1 ]] || { echo 'a failed step ran twice' >&2; exit 1; }
grep -Fxq 'after code=100 id=101 failure=true' "$WORK_DIR/step.log"
grep -Fxq 'success code=[]' "$WORK_DIR/step.log"
grep -Fq 'Sub-process /usr/bin/dpkg returned an error code (1)' "$WORK_DIR/step.out"
grep -Fq 'Error output: E: Sub-process /usr/bin/dpkg returned an error code (1)' "$WORK_DIR/errors"

# Guest-controlled text is written literally, not as escape sequences.
run escapes <<'HARNESS'
source "$FUNCTIONS"
ERROR_LOG_FILE="$PWD/escape-errors" ID=101 NAME='evil\e]0;x\a' ERROR_CODE=1 ERROR_MSG='line\nnext'
ERROR > /dev/null
HARNESS
grep -Fq 'evil\e]0;x\a' "$WORK_DIR/escape-errors"
grep -Fq 'Error output: line\nnext' "$WORK_DIR/escape-errors"

# --- extras and user scripts in an LXC ---------------------------------------------------
mkdir -p "$WORK_DIR/user-scripts/101" "$WORK_DIR/lf"
printf '#!/bin/sh\necho one\n' > "$WORK_DIR/user-scripts/101/10 first.sh"
printf '#!/bin/sh\necho two\n' > "$WORK_DIR/user-scripts/101/20-second.sh"
touch "$WORK_DIR/user-scripts/101/.hidden" "$WORK_DIR/lf/update-extras.sh" "$WORK_DIR/lf/update.conf"
cat > "$WORK_DIR/guest-common.sh" <<'HARNESS'
source "$FUNCTIONS"
LOCAL_FILES="$PWD/lf" USER_SCRIPTS="$PWD/user-scripts" ERROR_LOG_FILE="$PWD/errors" NAME=x
EXTRA_GLOBAL=true HEADLESS=false WILL_STOP=false WELCOME_SCREEN=false QGA_UPDATE_TIMEOUT=3600
CONTAINER=101 VM=101 IP=192.0.2.5 USER=admin SSH_VM_PORT=2200 SSH_CONNECTION=""
pct() {
  printf 'pct %s\n' "$*" >> "$LOG"
  [[ "$1 ${3:-}" == 'exec --' && "${4:-}" == mktemp ]] && echo /tmp/ultimate-updater.AbC123
  [[ "${FAIL_SCRIPT:-}" != "" && "$*" == *"$FAIL_SCRIPT"* && "$1" == exec ]] && return 7
  return 0
}
ssh() {
  printf 'ssh %s\n' "$*" >> "$LOG"
  [[ "$*" == *mktemp* ]] && printf '/tmp/ultimate-updater.XyZ789\r\n'
  return 0
}
scp() { printf 'scp %s\n' "$*" >> "$LOG"; }
RUN_QEMU_COMMAND() {
  printf 'qga %s\n' "$*" >> "$LOG"
  QEMU_EXEC_STDOUT=""
  [[ "$*" == *mktemp* ]] && QEMU_EXEC_STDOUT=/tmp/ultimate-updater.Qg4567
  return 0
}
HARNESS
run lxc <<'HARNESS'
source guest-common.sh
EXTRAS > lxc.out
HARNESS
log="$WORK_DIR/lxc.log"
grep -Fxq 'pct push 101 '"$WORK_DIR"'/lf/update-extras.sh /tmp/ultimate-updater.AbC123/update-extras.sh' "$log"
grep -Fxq 'pct exec 101 -- env LOCAL_FILES=/tmp/ultimate-updater.AbC123 sh -c chmod +x "$1" && exec "$1" sh /tmp/ultimate-updater.AbC123/update-extras.sh' "$log"
grep -Fxq 'pct exec 101 -- env LOCAL_FILES=/tmp/ultimate-updater.AbC123 sh -c chmod +x "$1" && exec "$1" sh /tmp/ultimate-updater.AbC123/10 first.sh' "$log"
grep -Fxq 'pct exec 101 -- rm -rf -- /tmp/ultimate-updater.AbC123' "$log"
if grep -q '\.hidden' "$log"; then echo 'a hidden file ran as a user script' >&2; exit 1; fi
if grep -Fq "rm -rf $WORK_DIR/lf" "$log" || grep -Eq 'rm -rf (--  )?/etc/ultimate-updater' "$log"; then
  echo 'the guest installation directory was removed' >&2
  exit 1
fi
# Scripts run in name order.
first=$(grep -n '10 first.sh$' "$log" | tail -1 | cut -d: -f1)
second=$(grep -n '20-second.sh$' "$log" | tail -1 | cut -d: -f1)
(( first < second ))

# A failing user script is reported and stops the remaining ones.
run lxc-fail <<'HARNESS'
source guest-common.sh
FAIL_SCRIPT='10 first.sh' EXTRAS > /dev/null
echo "code=$ERROR_CODE msg=$ERROR_MSG" >> "$LOG"
HARNESS
grep -Fxq 'code=1 msg=User script 10 first.sh in LXC 101 failed (exit code 7)' "$WORK_DIR/lxc-fail.log"
if grep -q 'exec 101 .*20-second.sh' "$WORK_DIR/lxc-fail.log"; then echo 'ran scripts after a failure' >&2; exit 1; fi

# --- SSH guests: port, user, work directory --------------------------------------------------
mkdir -p "$WORK_DIR/user-scripts/101"
run ssh <<'HARNESS'
source guest-common.sh
SSH_CONNECTION=true USER=root
EXTRAS > /dev/null
HARNESS
log="$WORK_DIR/ssh.log"
grep -Fxq "scp -q -P 2200 $WORK_DIR/lf/update.conf root@192.0.2.5:/tmp/ultimate-updater.XyZ789/update.conf" "$log"
grep -Fxq 'ssh -q -p 2200 -tt root@192.0.2.5 chmod +x /tmp/ultimate-updater.XyZ789/10\ first.sh && LOCAL_FILES=/tmp/ultimate-updater.XyZ789 /tmp/ultimate-updater.XyZ789/10\ first.sh' "$log"
grep -Fxq 'ssh -q -p 2200 root@192.0.2.5 rm -rf -- /tmp/ultimate-updater.XyZ789' "$log"
if grep -E '^scp ' "$log" | grep -v -- '-P 2200'; then echo 'scp without the SSH port' >&2; exit 1; fi

# --- script-only mode over QGA ----------------------------------------------------------------
touch "$WORK_DIR/user-scripts/101/.script-only"
run qga <<'HARNESS'
source guest-common.sh
SCRIPT_ONLY_QEMU_VM > qga.out
echo "rc=$?" >> "$LOG"
HARNESS
log="$WORK_DIR/qga.log"
grep -Fxq 'rc=0' "$log"
grep -Fq 'qga 101 --timeout 3600 -- env LOCAL_FILES=/tmp/ultimate-updater.Qg4567 sh -c chmod +x "$1" && exec "$1" sh /tmp/ultimate-updater.Qg4567/20-second.sh' "$log"
grep -Fq 'Script-only mode enabled for VM 101 via QEMU Guest Agent' "$WORK_DIR/qga.out"
rm -f "$WORK_DIR/user-scripts/101/"*.sh
run empty <<'HARNESS'
source guest-common.sh
rc=0
SCRIPT_ONLY_LXC > /dev/null || rc=$?
echo "rc=$rc error=$SCRIPT_ONLY_ERROR" >> "$LOG"
HARNESS
grep -Fxq 'rc=2 error=No user scripts found for LXC 101' "$WORK_DIR/empty.log"

# --- no failed step is repeated to capture its output anywhere -------------------------------
if grep -n 'ERROR_MSG=\$(' "$UPDATE" | grep -v 'tail -n 20 -- "\$output"'; then
  echo 'a failed command is still run a second time' >&2
  exit 1
fi

echo 'guest update steps and guest files: PASS'
