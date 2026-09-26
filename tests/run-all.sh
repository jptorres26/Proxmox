#!/usr/bin/env bash
# Run the complete regression suite (or a subset) and report a summary.
#
# Usage: tests/run-all.sh [PATTERN...]
#   PATTERN  optional substrings; only test files whose name contains one of
#            them are run (for example: tests/run-all.sh web qga).
#
# Environment:
#   UU_TEST_TIMEOUT  per-test timeout in seconds (default: 300)
set -uo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TIMEOUT="${UU_TEST_TIMEOUT:-300}"

missing=()
for tool in python3 shellcheck ss timeout; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
  printf 'Missing required test tools: %s\n' "${missing[*]}" >&2
  exit 2
fi

selected() {
  local name="$1" pattern
  (($# == 1)) && return 0
  shift
  for pattern in "$@"; do
    [[ "$name" == *"$pattern"* ]] && return 0
  done
  return 1
}

passed=0
failed=()
shopt -s nullglob
for test_file in "$ROOT_DIR"/tests/test-*.sh "$ROOT_DIR"/tests/test-*.py; do
  name=${test_file##*/}
  selected "$name" "$@" || continue
  case "$name" in
    *.sh) runner=(bash) ;;
    *.py) runner=(python3) ;;
  esac
  started=$SECONDS
  if output=$(timeout "$TEST_TIMEOUT" "${runner[@]}" "$test_file" 2>&1); then
    passed=$((passed + 1))
    printf 'PASS  %-50s %3ss\n' "$name" "$((SECONDS - started))"
  else
    rc=$?
    failed+=("$name")
    printf 'FAIL  %-50s %3ss (exit %s)\n' "$name" "$((SECONDS - started))" "$rc"
    printf '%s\n' "$output" | tail -n 25 | sed 's/^/      /'
  fi
done

total=$((passed + ${#failed[@]}))
if ((total == 0)); then
  echo 'No tests matched.' >&2
  exit 2
fi
printf '\n%d/%d tests passed.\n' "$passed" "$total"
if ((${#failed[@]})); then
  printf 'Failed: %s\n' "${failed[*]}"
  exit 1
fi
