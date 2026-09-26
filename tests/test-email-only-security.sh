#!/usr/bin/env bash
set -euo pipefail

# EMAIL_ONLY_SECURITY="true" sends the check summary only when a target has
# security updates. The status-model path grepped check-output for "S",
# which every summary contains ("Security updates: 0"), and the legacy path
# sent the same mail in both branches.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"
printf '#!/bin/sh\ncat > /dev/null\necho sent >> "%s/mail.log"\n' "$WORK_DIR" > "$WORK_DIR/bin/mail"
chmod +x "$WORK_DIR/bin/mail"
printf 'Security updates: 0\nNormal updates: 3\n' > "$WORK_DIR/check-output"

write_status() {  # write_status <security updates>
  cat > "$WORK_DIR/status.json" <<JSON
{"schema_version": 1, "targets": [
  {"id": "101", "type": "lxc", "name": "web", "status": "updates_available", "reachable": true,
   "updates": 3, "normal_updates": 3, "security_updates": $1}
]}
JSON
}

send() {  # send <EMAIL_ONLY_SECURITY>
  printf 'EMAIL_USER="root"\nEMAIL_SENDER="root"\nEMAIL_NO_UPDATES="false"\nEMAIL_ONLY_SECURITY="%s"\n' "$1" \
    > "$WORK_DIR/update.conf"
  : > "$WORK_DIR/mail.log"
  PATH="$WORK_DIR/bin:$PATH" LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1/status-model.sh"
    STATUS_MODEL_SEND_NOTIFICATION "$2/status.json" "$2/update.conf"' _ "$ROOT_DIR" "$WORK_DIR"
  wc -l < "$WORK_DIR/mail.log"
}

write_status 0
[[ "$(send false)" -eq 1 ]]                        # normal policy: mail the updates
[[ "$(send true)" -eq 0 ]] || { echo 'security-only mail sent without security updates' >&2; exit 1; }
write_status 2
[[ "$(send true)" -eq 1 ]]

# Legacy fallback path in check-updates.sh.
grep -Fq 'if [[ "$EMAIL_ONLY_SECURITY" != true || "$SECURITY_UPDATES_AVALABLE" == true ]]; then' \
  "$ROOT_DIR/check-updates.sh"

echo 'EMAIL_ONLY_SECURITY: PASS'
