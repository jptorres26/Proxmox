#!/usr/bin/env bash
set -euo pipefail

# install.sh used to map exit status 1 to 0 in its EXIT trap, so failed
# downloads, copies, and service setup were reported as successful updates.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

run_installer() {
  local rc=0
  env -u TERM bash "$ROOT_DIR/install.sh" "$@" >"$WORK_DIR/out" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

if [[ "$EUID" -ne 0 ]]; then
  # The header refuses non-root callers before any argument is handled.
  [[ "$(run_installer --help)" == 1 ]]
  grep -Fq 'Please run this as root' "$WORK_DIR/out"
  grep -Fq 'Error during install --- Exit Code: 1' "$WORK_DIR/out"
else
  [[ "$(run_installer --help)" == 0 ]]
  [[ "$(run_installer unexpected-argument)" == 1 ]]
  grep -Fq 'Got an unexpected argument' "$WORK_DIR/out"
  grep -Fq 'Error during install --- Exit Code: 1' "$WORK_DIR/out"
fi

# "status" answers whether the updater is installed; it is not an error.
if [[ "$EUID" -eq 0 && ! -e /usr/local/sbin/update && ! -d /etc/ultimate-updater ]]; then
  [[ "$(run_installer status)" == 1 ]]
  if grep -Fq 'Error during install' "$WORK_DIR/out"; then
    echo 'status on an uninstalled host was reported as an installer error' >&2
    exit 1
  fi
fi

# The trap itself: failures keep their status and clean the temp folder.
eval "$(sed -n '/^EXIT () {/,/^}/p' "$ROOT_DIR/install.sh")"
declare -f EXIT > "$WORK_DIR/exit-function.sh"
for status in 0 1 2 75; do
  mkdir -p "$WORK_DIR/temp"
  rc=0
  TEMP_FOLDER="$WORK_DIR/temp" bash -c 'source "$1"; set -e; trap EXIT EXIT; exit "$2"' _ \
    "$WORK_DIR/exit-function.sh" "$status" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == "$status" ]] || { echo "EXIT trap turned $status into $rc" >&2; exit 1; }
  if [[ "$status" -ne 0 && -e "$WORK_DIR/temp" ]]; then
    echo 'EXIT trap kept the temp folder after a failure' >&2
    exit 1
  fi
done
# A failing command under set -e is a failure, not a success.
rc=0
TEMP_FOLDER="$WORK_DIR/temp" bash -c 'source "$1"; set -e; trap EXIT EXIT; false; exit 0' _ \
  "$WORK_DIR/exit-function.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# A missing Welcome-Screen source fails before /etc/motd is touched. The
# fresh install copies from the (nested) archive root, not $TEMP_FOLDER.
eval "$(sed -n '/^WELCOME_SCREEN_INSTALL () {/,/^}/p' "$ROOT_DIR/install.sh")"
motd_before=$(stat -c '%Y %s' /etc/motd 2>/dev/null || echo missing)
if WELCOME_SCREEN_INSTALL "$WORK_DIR/missing/welcome-screen.sh" 2>/dev/null; then
  echo 'Welcome-Screen install accepted a missing source' >&2
  exit 1
fi
[[ "$(stat -c '%Y %s' /etc/motd 2>/dev/null || echo missing)" == "$motd_before" ]]
# shellcheck disable=SC2016 # literal installer code is the assertion target.
grep -Fq 'WELCOME_SCREEN_INSTALL "$TEMP_FILES/welcome-screen.sh"' "$ROOT_DIR/install.sh"

echo 'installer exit codes: PASS'
