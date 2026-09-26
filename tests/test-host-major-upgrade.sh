#!/usr/bin/env bash
# shellcheck disable=SC2016 # the bash -c body expands in the child shell.
set -euo pipefail

# An unattended host update must not start a Proxmox VE major upgrade (for
# example 8 -> 9 after the repositories were switched): that needs the
# documented manual procedure.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
sed -n '/^HOST_MAJOR_UPGRADE_PENDING () {/,/^}/p' "$ROOT_DIR/update.sh" > "$WORK_DIR/function.sh"
grep -q HOST_MAJOR_UPGRADE_PENDING "$WORK_DIR/function.sh"

pending() {  # pending <apt-get -s output>
  printf '#!/bin/sh\ncat <<"EOF"\n%s\nEOF\n' "$1" > "$WORK_DIR/apt-get"
  chmod +x "$WORK_DIR/apt-get"
  PATH="$WORK_DIR:$PATH" bash -c 'source "$1"; HOST_MAJOR_UPGRADE_PENDING' _ "$WORK_DIR/function.sh"
}

pending $'Inst libc6 [2.36-9] (2.41-12 Debian:13 [amd64])\nInst pve-manager [8.4.1] (9.0.3 Proxmox:9.0/stable [amd64])'
if pending 'Inst pve-manager [8.4.1] (8.4.5 Proxmox:8.4/stable [amd64])'; then
  echo 'a minor pve-manager update was treated as a major upgrade' >&2
  exit 1
fi
if pending 'Inst proxmox-ve [8.4.0] (9.0.0 Proxmox [all])'; then
  echo 'only pve-manager decides' >&2
  exit 1
fi
if pending ''; then echo 'no updates is not a major upgrade' >&2; exit 1; fi

# The host update checks before its dist-upgrade and can be overridden.
host_update=$(sed -n '/^UPDATE_HOST_ITSELF () {/,/^}/p' "$ROOT_DIR/update.sh")
guard_line=$(grep -n 'HOST_MAJOR_UPGRADE_PENDING' <<< "$host_update" | head -1 | cut -d: -f1)
upgrade_line=$(grep -n 'dist-upgrade -y' <<< "$host_update" | head -1 | cut -d: -f1)
[[ -n "$guard_line" && -n "$upgrade_line" ]] && (( guard_line < upgrade_line ))
grep -Fq 'UU_ALLOW_MAJOR_UPGRADE:-false' <<< "$host_update"

echo 'host major upgrade guard: PASS'
