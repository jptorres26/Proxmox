#!/usr/bin/env bash
# shellcheck disable=SC2016 # the bash -c body expands in the child shell.
set -euo pipefail

# A self-update installs the payload without prompts, keeps edited exit
# hooks, and never treats an unmatched glob as a file name.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
{
  sed -n '/^INSTALL_PAYLOAD_FILES () {/,/^}/p' "$ROOT_DIR/install.sh"
  sed -n '/^CHECK_DIFF () {/,/^}/p' "$ROOT_DIR/install.sh"
} > "$WORK_DIR/functions.sh"
grep -q '^INSTALL_PAYLOAD_FILES () {' "$WORK_DIR/functions.sh"

payload="$WORK_DIR/payload" local_files="$WORK_DIR/etc"
mkdir -p "$payload/exit" "$local_files/exit"
printf 'new update\n' > "$payload/update.sh"
printf 'new passed\n' > "$payload/exit/passed.sh"
printf 'new error\n' > "$payload/exit/error.sh"
printf 'shipped inventory\n' > "$payload/targets.conf"
printf 'old update\n' > "$local_files/update.sh"
printf 'my webhook\n' > "$local_files/exit/error.sh"
printf 'new passed\n' > "$local_files/exit/passed.sh"
printf 'stale default\n' > "$local_files/exit/passed.sh.dist"
printf 'my inventory\n' > "$local_files/targets.conf"

(cd "$payload" && LOCAL_FILES="$local_files" TEMP_FILES="$payload" UU_NONINTERACTIVE=true \
  bash -c 'set -e; source "$1"; INSTALL_PAYLOAD_FILES' _ "$WORK_DIR/functions.sh" > /dev/null)

[[ "$(cat "$local_files/update.sh")" == 'new update' ]]
[[ "$(cat "$local_files/update.sh.bak")" == 'old update' ]]
[[ "$(cat "$local_files/exit/error.sh")" == 'my webhook' ]]
[[ "$(cat "$local_files/exit/error.sh.dist")" == 'new error' ]]
[[ ! -e "$local_files/exit/error.sh.bak" ]]
[[ "$(cat "$local_files/exit/passed.sh")" == 'new passed' ]]
[[ ! -e "$local_files/exit/passed.sh.dist" ]]
[[ "$(cat "$local_files/targets.conf")" == 'my inventory' ]]

# A new hook is installed as usual.
rm -f "$local_files/exit/error.sh" "$local_files/exit/error.sh.dist"
printf 'new error\n' > "$payload/exit/error.sh"
(cd "$payload" && LOCAL_FILES="$local_files" TEMP_FILES="$payload" UU_NONINTERACTIVE=true \
  bash -c 'set -e; source "$1"; INSTALL_PAYLOAD_FILES' _ "$WORK_DIR/functions.sh" > /dev/null)
[[ "$(cat "$local_files/exit/error.sh")" == 'new error' ]]

# A payload without subdirectories installs no literal "*/*.*" file.
empty="$WORK_DIR/flat" flat_local="$WORK_DIR/flat-etc"
mkdir -p "$empty" "$flat_local"
printf 'x\n' > "$empty/update.sh"
(cd "$empty" && LOCAL_FILES="$flat_local" TEMP_FILES="$empty" UU_NONINTERACTIVE=true \
  bash -c 'set -e; source "$1"; INSTALL_PAYLOAD_FILES' _ "$WORK_DIR/functions.sh")
[[ "$(find "$flat_local" -type f | wc -l)" -eq 1 && -f "$flat_local/update.sh" ]]

# UPDATE uses the helper instead of an unquoted glob list.
update_body=$(sed -n '/^UPDATE () {/,/^}/p' "$ROOT_DIR/install.sh")
grep -Fq 'INSTALL_PAYLOAD_FILES' <<< "$update_body"
if grep -Fq 'FILES="*.*' <<< "$update_body"; then
  echo 'UPDATE still expands an unquoted glob list' >&2
  exit 1
fi

echo 'installer exit hooks: PASS'
