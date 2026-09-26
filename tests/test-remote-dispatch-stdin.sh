#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154 # literal harness code; the extracted printf assigns remote_command.
set -euo pipefail

# Remote node updates and checks used to stream their script into `bash -s`.
# A shell that reads its script from stdin shares that stream with its
# children, so an ssh to a VM or a package prompt swallowed the rest of the
# script (including the final status) and failures came back as success. The
# script is now staged on the node and run with stdin closed.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# --- update.sh: node update dispatch -----------------------------------------
cat > "$WORK_DIR/update-harness.sh" <<HARNESS
#!/bin/bash
if [[ "\${1:-}" == -c || "\${1:-}" == -s ]]; then
  # Stand-in for the staged update.sh on the node.
  printf '%s\n' "\$*" > "$WORK_DIR/update-args"
  if read -r _; then echo open; else echo closed; fi > "$WORK_DIR/update-stdin"
  exit 7
fi
source <(sed -n '/^UPDATE_HOST () {/,/^}/p' "$ROOT_DIR/update.sh")
hostname() { echo 192.0.2.1; }
ssh() { bash -c "\${!#}"; }
HEADLESS=true WELCOME_SCREEN=false SSH_PORT=22
rc=0
UPDATE_HOST 192.0.2.1 || rc=\$?
printf '%s\n' "\$rc" > "$WORK_DIR/update-rc"
HARNESS
bash "$WORK_DIR/update-harness.sh"
[[ "$(cat "$WORK_DIR/update-rc")" == 7 ]]          # the node's status reaches the caller
[[ "$(cat "$WORK_DIR/update-args")" == '-s -c host' ]]
[[ "$(cat "$WORK_DIR/update-stdin")" == closed ]]

# --- ultimate-updater: remote node and guest checks --------------------------
extract_command() {
  awk -v marker="$1" '
    /^  printf -v remote_command .cat > %q \|\| exit 90; LOCAL_FILES=%q/ && index($0, marker) { copy = 1 }
    copy { print }
    copy && /"\$remote_check_dir" "\$remote_status_file" "\$remote_check_dir"$/ { exit }
  ' "$ROOT_DIR/ultimate-updater"
}
extract_command STATUS_MODEL_NODE > "$WORK_DIR/node-command.sh"
extract_command QGA_EXEC_SCRIPT > "$WORK_DIR/guest-command.sh"
[[ -s "$WORK_DIR/node-command.sh" && -s "$WORK_DIR/guest-command.sh" ]]

run_remote_check() {
  local kind="$1"
  remote_check_dir="$WORK_DIR/remote-$kind" remote_config=config remote_tag_filter=tag
  remote_cluster_target=cluster remote_runtime=runtime node=pve2 remote_qga=qga
  remote_internal_ssh=internal remote_internal_conf=internal.conf mode=cvm target=105
  remote_status_model="$remote_check_dir/status-model.sh" remote_status_file="$remote_check_dir/status.json"
  mkdir -p "$remote_check_dir"
  # shellcheck disable=SC1090
  source "$WORK_DIR/$kind-command.sh"
  cat > "$WORK_DIR/fake-check.sh" <<FAKE
printf '%s\n' "\$*" > "$WORK_DIR/$kind-args"
if read -r _; then echo open; else echo closed; fi > "$WORK_DIR/$kind-stdin"
printf '{"targets": []}\n' > "\$STATUS_MODEL_FILE"
FAKE
  bash -c "$remote_command" < "$WORK_DIR/fake-check.sh" > "$WORK_DIR/$kind-output"
}
run_remote_check node
[[ "$(cat "$WORK_DIR/node-args")" == node-host && "$(cat "$WORK_DIR/node-stdin")" == closed ]]
grep -Fq '"targets"' "$WORK_DIR/node-output"
run_remote_check guest
[[ "$(cat "$WORK_DIR/guest-args")" == 'cvm 105' && "$(cat "$WORK_DIR/guest-stdin")" == closed ]]
[[ ! -e "$WORK_DIR/remote-guest" ]]                  # the work directory is cleaned up

# --- no dispatch streams a script into bash -s anymore -----------------------
if grep -nE "bash -s( |'|$)" "$ROOT_DIR/update.sh" "$ROOT_DIR/check-updates.sh" "$ROOT_DIR/ultimate-updater" |
  grep -v '^[^:]*:[0-9]*: *#'; then
  echo 'a remote dispatch still reads its script from stdin' >&2
  exit 1
fi

echo 'remote dispatch stdin isolation: PASS'
