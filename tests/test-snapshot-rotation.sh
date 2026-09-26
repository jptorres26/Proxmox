#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329 # stubs and globals are used by extracted functions.
set -euo pipefail

# Snapshot rotation must only delete this updater's Update_<date>_<time>
# snapshots, oldest first, and always keep the one taken for the current run.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

eval "$(sed -n '/^ROTATE_UPDATE_SNAPSHOTS () {/,/^}/p' "$ROOT_DIR/update.sh")"
sed -n '/^READ_CONFIG () {/,/^}/p' "$ROOT_DIR/update.sh" > "$WORK_DIR/read-config.sh"
# READ_CONFIG runs without nounset/errexit in update.sh; mirror that.
keep_snapshots_for() {
  printf 'KEEP_SNAPSHOTS="%s"\n' "$1" > "$WORK_DIR/update.conf"
  bash -c 'source "$1"; CONFIG_FILE="$2"; READ_CONFIG >/dev/null 2>&1; printf "%s" "$KEEP_SNAPSHOT"' \
    _ "$WORK_DIR/read-config.sh" "$WORK_DIR/update.conf"
}

listing() {
  cat <<'LISTING'
`-> UpdateTest                   2026-01-01 00:00:00     manual snapshot by the admin
 `-> Update_20260102_010000     2026-01-02 01:00:00     no-description
  `-> Update_20260101_010000    2026-01-01 01:00:00     Update notes mention Update_20250101_000000
   `-> pre-Update               2026-01-03 00:00:00     before an Update
    `-> Update_20260103_010000  2026-01-03 01:00:00     no-description
     `-> Update_20260104_010000 2026-01-04 01:00:00     no-description
      `-> current                                        You are here!
LISTING
}
pct() { [[ "$1" == listsnapshot ]] && listing; }
qm() { [[ "$1" == listsnapshot ]] && listing; }
RUN_PROXMOX_COMMAND() { printf '%s\n' "$*" >> "$WORK_DIR/deleted"; }

rotate() {
  : > "$WORK_DIR/deleted"
  KEEP_SNAPSHOT="$1" ROTATE_UPDATE_SNAPSHOTS "$2" 101
}

rotate 2 pct
[[ "$(cat "$WORK_DIR/deleted")" == $'pct delsnapshot 101 Update_20260101_010000\npct delsnapshot 101 Update_20260102_010000' ]]
rotate 1 qm
[[ "$(wc -l < "$WORK_DIR/deleted")" -eq 3 ]]
grep -Fxq 'qm delsnapshot 101 Update_20260103_010000' "$WORK_DIR/deleted"
if grep -Eq 'UpdateTest|pre-Update|Update_20260104_010000|Update_20250101' "$WORK_DIR/deleted"; then
  echo 'rotation deleted a user snapshot or the newest update snapshot' >&2
  exit 1
fi
rotate 10 pct
[[ ! -s "$WORK_DIR/deleted" ]]

# KEEP_SNAPSHOTS=0 (or garbage) must never delete the snapshot just taken.
for value in 0 00; do
  keep=$(keep_snapshots_for "$value")
  [[ "$keep" == 1 ]] || { echo "KEEP_SNAPSHOTS=$value became $keep" >&2; exit 1; }
done
for value in -1 abc ''; do
  keep=$(keep_snapshots_for "$value")
  [[ "$keep" == 3 ]] || { echo "KEEP_SNAPSHOTS=$value became $keep" >&2; exit 1; }
done
[[ "$(keep_snapshots_for 7)" == 7 ]]
[[ "$(keep_snapshots_for 08)" == 8 ]]

echo 'snapshot rotation: PASS'
