#!/usr/bin/env bash
set -euo pipefail

# CLEAN_LOGFILE used to pipe the log through `cat | sed | tee` into itself,
# which truncated /var/log/ultimate-updater.log (and the summary mail built
# from it) in most runs.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

{
  sed -n '/^OUTPUT_TO_FILE () {/,/^}/p' "$ROOT_DIR/update.sh"
  sed -n '/^CLEAN_LOGFILE () {/,/^}/p' "$ROOT_DIR/update.sh"
} > "$WORK_DIR/functions.sh"
grep -q '^CLEAN_LOGFILE () {' "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
set -o pipefail
source "$FUNCTIONS"
LOG_FILE="$RUN_DIR/ultimate-updater.log" TEMP_STATE_DIR="$RUN_DIR/state" LOCAL_FILES="$RUN_DIR" RICM=""
mkdir -p "$TEMP_STATE_DIR"
OUTPUT_TO_FILE
printf 'header line removed by CLEAN_LOGFILE\n'
for index in $(seq 1 60000); do
  printf '\e[1;92mline %s\e[0m\n' "$index"
done
CLEAN_LOGFILE
printf 'after cleanup\n'
HARNESS

for run in $(seq 1 5); do
  run_dir="$WORK_DIR/run-$run"
  mkdir -p "$run_dir"
  (cd "$run_dir" && RUN_DIR="$run_dir" FUNCTIONS="$WORK_DIR/functions.sh" bash "$WORK_DIR/harness.sh" >"$run_dir/terminal" 2>&1)
  log="$run_dir/ultimate-updater.log"
  lines=$(wc -l < "$log")
  [[ "$lines" -eq 60000 ]] || { echo "run $run: log has $lines lines instead of 60000" >&2; exit 1; }
  [[ "$(head -n 1 "$log")" == 'line 1' && "$(tail -n 1 "$log")" == 'line 60000' ]]
  if grep -q $'\e' "$log"; then
    echo "run $run: ANSI escapes were not removed" >&2
    exit 1
  fi
  [[ "$(stat -c '%a' "$log")" == 640 ]]
  [[ ! -e "$run_dir/tmp.log" ]]
  grep -Fxq 'after cleanup' "$run_dir/terminal"
done

echo 'update log file cleanup: PASS'
