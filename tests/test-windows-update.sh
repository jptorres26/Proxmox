#!/usr/bin/env bash
# shellcheck disable=SC2016 # the bash -c bodies expand in the child shell.
set -euo pipefail

# The Windows update step accepts license terms, skips interactive updates,
# waits as long as the other QGA update steps, and keeps a VM that is still
# installing from being shut down.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# shellcheck source=/dev/null
source "$ROOT_DIR/windows-update.sh"
install_script=$(WINDOWS_POWERSHELL_SCRIPT install)
line_of() { grep -nF -- "$1" <<< "$install_script" | head -1 | cut -d: -f1; }
accept=$(line_of '$update.AcceptEula()')
interactive=$(line_of 'CanRequestUserInput')
download=$(line_of '$downloader.Download()')
[[ -n "$accept" && -n "$interactive" && -n "$download" ]]
(( interactive < accept && accept < download ))
grep -Fq '$downloader.Updates = $installable' <<< "$install_script"
grep -Fq '$installer.Updates = $installable' <<< "$install_script"
if grep -Fq 'Updates = $available' <<< "$install_script"; then
  echo 'the install still uses the unfiltered update list' >&2
  exit 1
fi
# The check stays read-only.
if WINDOWS_POWERSHELL_SCRIPT check | grep -Eq 'AcceptEula|Install\(|Download\('; then
  echo 'the Windows check changes the guest' >&2
  exit 1
fi

{
  sed -n '/^QGA_NOTE_UNFINISHED_JOB () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^UPDATE_VM_QEMU_WINDOWS () {/,/^}/p' "$ROOT_DIR/update.sh"
} > "$WORK_DIR/functions.sh"
grep -q '^UPDATE_VM_QEMU_WINDOWS () {' "$WORK_DIR/functions.sh"

run_windows_update() {  # run_windows_update <error class> <transport rc> <stdout>
  bash -c '
    source "$1"
    WINDOWS_POWERSHELL_ENCODE() { echo encoded; }
    ERROR() { echo "ERROR $ERROR_CODE $ERROR_MSG"; }
    QGA_UPDATE_TIMEOUT=5400 VM=101
    QEMU_GUEST_EXEC() {
      echo "timeout=$3"
      QEMU_EXEC_ERROR_CLASS=$ERROR_CLASS QEMU_EXEC_TRANSPORT_RC=$TRANSPORT_RC
      QEMU_EXEC_EXITCODE=0 QEMU_EXEC_STDOUT=$STDOUT QEMU_EXEC_OUTPUT="guest-exec failed"
    }
    UPDATE_VM_QEMU_WINDOWS
    echo "running=${QGA_JOB_MAY_BE_RUNNING:-false}"' _ "$WORK_DIR/functions.sh"
}

output=$(ERROR_CLASS=QGA_TIMEOUT TRANSPORT_RC=1 STDOUT="" run_windows_update)
grep -Fxq 'timeout=5400' <<< "$output"
grep -Fxq 'running=true' <<< "$output"
grep -q '^ERROR ' <<< "$output"

output=$(ERROR_CLASS="" TRANSPORT_RC=0 \
  STDOUT=$'UU_WINDOWS|ok|3|true|installed; 1 interactive update(s) skipped\r' run_windows_update)
grep -Fxq 'running=false' <<< "$output"
grep -Fq 'Windows updates processed: 3 (installed; 1 interactive update(s) skipped)' <<< "$output"
if grep -q '^ERROR ' <<< "$output"; then
  echo 'a successful Windows update reported an error' >&2
  exit 1
fi

echo 'windows update: PASS'
