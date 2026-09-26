#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329 # globals and stubs are used by extracted functions.
set -euo pipefail

# External updates run apt-get update/dist-upgrade/autoremove/autoclean in one
# SSH session; the generic 120 s command timeout must not apply to them.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

eval "$(awk '/^remote_update\(\) \{/{copy=1} /^update_target\(\) \{/{exit} copy' "$ROOT_DIR/external-apt.sh")"
RUN_SSH_COMMAND() {
  printf '%s\n' "${UU_SSH_COMMAND_TIMEOUT:-unset}" > "$WORK_DIR/timeout"
  cat > /dev/null
}
EXTERNAL_HELPER_PATH=/usr/local/sbin/ultimate-updater-external EXTERNAL_HELPER_VERSION=1
EXTERNAL_TARGET=fixture EXTERNAL_IDENTITY_FILE="" EXTERNAL_HOST=192.0.2.5 EXTERNAL_PORT=22 EXTERNAL_USER=root

remote_update
[[ "$(cat "$WORK_DIR/timeout")" == 14400 ]]
UU_EXTERNAL_UPDATE_TIMEOUT=600 remote_update
[[ "$(cat "$WORK_DIR/timeout")" == 600 ]]

# The shared SSH wrapper sends keepalives so dead peers are still detected.
unset -f RUN_SSH_COMMAND
eval "$(sed -n '/^RUN_SSH_COMMAND() {/,/^}/p' "$ROOT_DIR/target-runtime.sh")"
mkdir -p "$WORK_DIR/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\n' "$WORK_DIR/timeout-args" > "$WORK_DIR/bin/timeout"
chmod 755 "$WORK_DIR/bin/timeout"
PATH="$WORK_DIR/bin:$PATH" RUN_SSH_COMMAND 192.0.2.5 22 root true
grep -Fxq 'ServerAliveInterval=30' "$WORK_DIR/timeout-args"
[[ "$(head -n 1 "$WORK_DIR/timeout-args")" == 120 ]]

echo 'external update timeout: PASS'
