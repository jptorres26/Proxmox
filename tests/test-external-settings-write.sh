#!/usr/bin/env bash
set -euo pipefail

# external-settings.sh set: values with quotes or backslashes are rejected,
# escapes written by earlier versions do not grow on every round trip, and
# root SSH users do not need sudo for the privileged helper.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local" "$WORK_DIR/bin"
printf '[box]\nhost=192.0.2.5\ntransport=ssh\nuser=root\nport=22\n' > "$WORK_DIR/local/targets.conf"
cat > "$WORK_DIR/remote.conf" <<'CONF'
schema_version="1"
ONLY_UPDATE_CHECK=""
EXCLUDE_UPDATE_CHECK="old\\value"
ONLY=""
EXCLUDE=""
CONF
cat > "$WORK_DIR/bin/ssh" <<STUB
#!/bin/bash
command="\${!#}"
case "\$command" in
  '/bin/cat -- '*) cat "$WORK_DIR/remote.conf" ;;
  *config-write*) printf '%s\n' "\$command" > "$WORK_DIR/write-command"; cat > "$WORK_DIR/written.conf" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK_DIR/bin/ssh"

run_set() {
  PATH="$WORK_DIR/bin:$PATH" UU_LOCAL_FILES="$WORK_DIR/local" bash "$ROOT_DIR/external-settings.sh" set box "$@"
}

run_set 'ONLY=web' > /dev/null
grep -Fxq 'ONLY="web"' "$WORK_DIR/written.conf"
grep -Fxq 'EXCLUDE_UPDATE_CHECK="old\\value"' "$WORK_DIR/written.conf" ||
  { echo 'an existing escaped value changed on a round trip' >&2; cat "$WORK_DIR/written.conf" >&2; exit 1; }
# shellcheck disable=SC2016 # literal remote command
grep -Fq 'if [ "$(id -u)" -eq 0 ]; then /usr/local/sbin/ultimate-updater-external config-write; else sudo -n' \
  "$WORK_DIR/write-command"

for value in 'ONLY=a"b' 'ONLY=a\b'; do
  if run_set "$value" 2>/dev/null; then
    echo "accepted External setting $value" >&2
    exit 1
  fi
done

echo 'External settings write: PASS'
