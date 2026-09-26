#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete 2>/dev/null || true; rmdir "$WORK_DIR"/* "$WORK_DIR" 2>/dev/null || true' EXIT
export UU_HARDCORE_TEST_ROOT="$WORK_DIR/runs"

start=$("$ROOT_DIR/hardcore-test.sh" start baseline fixture)
run_id=$(printf '%s\n' "$start" | awk -F= '$1 == "RUN_ID" {print $2}')
[[ -n "$run_id" ]]
[[ -f "$UU_HARDCORE_TEST_ROOT/$run_id/state" ]]

"$ROOT_DIR/hardcore-test.sh" log "$run_id" T-001 Config fixture initial none expected actual PASS '' '' PASS cleaned
"$ROOT_DIR/hardcore-test.sh" log "$run_id" T-002 Config fixture initial none expected actual PASS - - PASS cleaned
[[ $(awk -F '\t' 'NF != 13 { bad=1 } END { print bad+0 }' "$UU_HARDCORE_TEST_ROOT/$run_id/journal.tsv") -eq 0 ]]
status=$("$ROOT_DIR/hardcore-test.sh" status "$run_id")
grep -Fq 'Status: running' <<<"$status"
grep -Fq 'PASS: 2' <<<"$status"
grep -Fq 'Bugs: 0' <<<"$status"
"$ROOT_DIR/hardcore-test.sh" progress "$run_id" phase1 "current test"
grep -Fq 'phase=phase1' "$UU_HARDCORE_TEST_ROOT/$run_id/state"

# A line break may not add or replace state keys.
state_before=$(cat "$UU_HARDCORE_TEST_ROOT/$run_id/state")
for bad in $'phase2\nstatus=completed' $'phase2\rstatus=completed'; do
  if "$ROOT_DIR/hardcore-test.sh" progress "$run_id" "$bad" test 2>/dev/null; then
    echo 'progress accepted a line break' >&2
    exit 1
  fi
  if "$ROOT_DIR/hardcore-test.sh" progress "$run_id" phase2 "$bad" 2>/dev/null; then
    echo 'progress accepted a line break in the current test' >&2
    exit 1
  fi
  if "$ROOT_DIR/hardcore-test.sh" log "$run_id" T-003 Config fixture initial none expected "$bad" PASS - - PASS cleaned 2>/dev/null; then
    echo 'log accepted a line break' >&2
    exit 1
  fi
done
[[ "$(cat "$UU_HARDCORE_TEST_ROOT/$run_id/state")" == "$state_before" ]]
[[ $(wc -l < "$UU_HARDCORE_TEST_ROOT/$run_id/journal.tsv") -eq 2 ]]

"$ROOT_DIR/hardcore-test.sh" stop "$run_id"
grep -Fq 'status=stopping' "$UU_HARDCORE_TEST_ROOT/$run_id/state"
test -f "$UU_HARDCORE_TEST_ROOT/$run_id/STOP"
"$ROOT_DIR/hardcore-test.sh" finalize "$run_id" aborted 'owner requested stop'
grep -Fq 'status=aborted' "$UU_HARDCORE_TEST_ROOT/$run_id/state"

second=$("$ROOT_DIR/hardcore-test.sh" start phase2 second)
second_id=$(printf '%s\n' "$second" | awk -F= '$1 == "RUN_ID" {print $2}')
[[ "$second_id" != "$run_id" ]]
if "$ROOT_DIR/hardcore-test.sh" finalize "$second_id" completed $'done\nstatus=running' 2>/dev/null; then
  echo 'finalize accepted a line break' >&2
  exit 1
fi
"$ROOT_DIR/hardcore-test.sh" finalize "$second_id" completed "done"
[[ $("$ROOT_DIR/hardcore-test.sh" list | wc -l) -eq 2 ]]
echo 'Hardcore test infrastructure: PASS'
