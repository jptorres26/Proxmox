#!/usr/bin/env bash
# shellcheck disable=SC2016 # the bash -c body expands in the child shell.
set -euo pipefail

# state_fields reads several keys in one pass with the same semantics as
# state_value: the first occurrence wins, values may contain "=", and empty
# or missing values stay empty fields.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
{
  sed -n '/^state_value() {/,/^}/p' "$ROOT_DIR/job-runner.sh"
  sed -n '/^state_fields() {/,/^}/p' "$ROOT_DIR/job-runner.sh"
} > "$WORK_DIR/functions.sh"
grep -q '^state_fields() {' "$WORK_DIR/functions.sh"

printf 'unit=u1\ntarget=\nstate=completed\nmessage=a=b c\\d\nstate=failed\nexit_code=0\n' > "$WORK_DIR/job.state"

bash -c '
  source "$1"
  file="$2"
  IFS=$'"'"'\x1f'"'"' read -r unit target state message missing exit_code \
    < <(state_fields "$file" unit target state message missing exit_code)
  [[ "$unit" == u1 && -z "$target" && "$state" == completed ]]
  [[ "$message" == "a=b c\\d" && -z "$missing" && "$exit_code" == 0 ]]
  for key in unit target state message missing exit_code; do
    [[ "$(state_value "$file" "$key")" == "${!key}" ]]
  done
  # A vanished file fails, so callers skip it.
  if state_fields "$file.gone" unit > /dev/null; then exit 1; fi
' _ "$WORK_DIR/functions.sh" "$WORK_DIR/job.state"

# The listing loops read each file once.
list_body=$(sed -n '/^list_jobs() {/,/^}/p' "$ROOT_DIR/job-runner.sh")
if grep -q 'state_value' <<< "$list_body"; then
  echo 'list_jobs still reads one key per process' >&2
  exit 1
fi

echo 'job state fields: PASS'
