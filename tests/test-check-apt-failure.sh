#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # harness code runs in a separate shell.
set -euo pipefail

# A failed `apt-get -s` (for example a held dpkg lock) is a failed check,
# not "0 updates, ok".

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
{
  sed -n '/^CHECK_HOST_ITSELF () {/,/^}/p' "$ROOT_DIR/check-updates.sh"
  sed -n '/^READ_APT_UPDATE_COUNTS() {/,/^}/p' "$ROOT_DIR/target-runtime.sh"
} > "$WORK_DIR/functions.sh"
grep -q '^CHECK_HOST_ITSELF () {' "$WORK_DIR/functions.sh"
mkdir -p "$WORK_DIR/bin"

run_host_check() {  # run_host_check <apt-get -s exit code>
  printf '#!/bin/sh\n[ "$1" = -s ] || exit 0\necho "Inst foo [1] (2 Debian:13 [amd64])"\nexit %s\n' "$1" > "$WORK_DIR/bin/apt-get"
  chmod +x "$WORK_DIR/bin/apt-get"
  : > "$WORK_DIR/records"
  PATH="$WORK_DIR/bin:$PATH" RECORDS="$WORK_DIR/records" bash -c '
    source "$1"
    HOSTNAME=pve1 BL="" CL="" GN="" OR="" RD=""
    STATUS_MODEL_RECORD() { printf "%s\n" "$*" >> "$RECORDS"; }
    HOST_KERNEL_REBOOT_REQUIRED() { return 1; }
    PRINT_UPDATE_SPLIT() { :; }
    CHECK_HOST_ITSELF' _ "$WORK_DIR/functions.sh" > /dev/null
}

if run_host_check 100; then
  echo 'a failed apt simulation passed the host check' >&2
  exit 1
fi
grep -Fq 'host:pve1 host local true  apt null null error CHECK_COMMAND_FAILED' "$WORK_DIR/records"
run_host_check 0
grep -Fq 'host:pve1 host local true' "$WORK_DIR/records"
grep -Fq ' apt 1 false updates_available ' "$WORK_DIR/records"

# The SSH VM path checks the simulation too.
grep -Fq 'if ! APT_OUTPUT=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "apt-get -s --with-new-pkgs upgrade"); then' \
  "$ROOT_DIR/check-updates.sh"

# Every caller counts a failed host check in the exit status.
if grep -En '(^|[;[:space:]])CHECK_HOST_ITSELF($|;)' "$ROOT_DIR/check-updates.sh" | grep -v 'CHECK_FAILURE=1'; then
  echo 'a CHECK_HOST_ITSELF call ignores its failure' >&2
  exit 1
fi

echo 'apt check failures: PASS'
