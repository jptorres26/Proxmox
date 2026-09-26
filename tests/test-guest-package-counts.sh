#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies are literal.
set -euo pipefail

# The package-count commands run inside guests through sh -c (pct exec, SSH,
# or QGA). Execute them with a strict POSIX sh against stubbed package
# managers.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"

eval "$(grep -E '^(RPM_COUNT_AWK|DNF_COUNT_COMMAND|YUM_COUNT_COMMAND|PACMAN_COUNT_COMMAND)=' "$ROOT_DIR/check-updates.sh")"
POSIX_SH=$(command -v dash || command -v sh)

stub() {
  printf '#!/bin/sh\n%s\n' "$2" > "$WORK_DIR/bin/$1"
  chmod 755 "$WORK_DIR/bin/$1"
}
count() {
  local rc=0 output
  output=$(PATH="$WORK_DIR/bin:/usr/bin:/bin" "$POSIX_SH" -c "$1" 2>&1) || rc=$?
  printf '%s:%s' "$rc" "${output//[[:space:]]/}"
}

# dnf: packages from several repositories, a wrapped long name, and an
# obsoletes section that must not be counted twice.
stub dnf 'cat <<EOF

bash.x86_64                              5.2.26-3.fc40               updates
kernel-core.x86_64                       6.9.5-200.fc40              updates-testing
a-really-long-package-name-that-wraps.noarch
                                         1.0-1.fc40                  fedora-cisco
Obsoleting Packages
grub2-tools.x86_64                       1:2.06-120.fc40             updates
    grub2-tools.x86_64                   1:2.06-118.fc40             @updates
EOF
exit 100'
[[ "$(count "$DNF_COUNT_COMMAND")" == 0:3 ]]
stub dnf 'exit 0'
[[ "$(count "$DNF_COUNT_COMMAND")" == 0:0 ]]
stub dnf 'echo "Error: Failed to download metadata" >&2; exit 1'
[[ "$(count "$DNF_COUNT_COMMAND")" == 1:* ]]

stub yum 'printf "\nopenssl.x86_64   1:1.0.2k-26.el7   updates\nzlib.x86_64   1.2.7-21.el7   base\n"; exit 100'
[[ "$(count "$YUM_COUNT_COMMAND")" == 0:2 ]]
rm "$WORK_DIR/bin/yum"
[[ "$(count "$YUM_COUNT_COMMAND")" == 127:* ]]  # a missing updater is an error, not "0 updates"

# pacman: prefer checkupdates (exit 2 means "no updates").
stub checkupdates 'printf "linux 6.9.1-1 -> 6.9.5-1\nbash 5.2.026-2 -> 5.2.032-1\n"'
[[ "$(count "$PACMAN_COUNT_COMMAND")" == 0:2 ]]
stub checkupdates 'exit 2'
[[ "$(count "$PACMAN_COUNT_COMMAND")" == 0:0 ]]
stub checkupdates 'echo "==> ERROR: Cannot fetch updates" >&2; exit 1'
[[ "$(count "$PACMAN_COUNT_COMMAND")" == 1:* ]]
rm "$WORK_DIR/bin/checkupdates"
stub pacman 'if [ "$1" = -Qu ]; then printf "a 1 -> 2\nb 1 -> 2\nc 1 -> 2\n"; fi'
[[ "$(count "$PACMAN_COUNT_COMMAND")" == 0:3 ]]
stub pacman 'exit 1'  # pacman -Qu exits 1 when nothing is upgradable
[[ "$(count "$PACMAN_COUNT_COMMAND")" == 0:0 ]]

# Updates must refresh the sync database; -Su alone upgrades nothing.
if grep -nE 'pacman -Su( |$)' "$ROOT_DIR/update.sh"; then
  echo 'pacman update without -y (stale sync database)' >&2
  exit 1
fi

echo 'guest package counts: PASS'
