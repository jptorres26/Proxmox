#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329 # harness code runs in a separate shell.
set -euo pipefail

# Host "reboot required" from the kernel the next boot uses: a pinned kernel
# if one is set and installed, otherwise the newest installed kernel.
# Manually selected kernels (proxmox-boot-tool kernel add) are extra ESP
# entries, not the boot choice.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
sed -n '/^HOST_KERNEL_REBOOT_REQUIRED () {/,/^}/p' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/function.sh"
grep -q 'HOST_KERNEL_REBOOT_REQUIRED' "$WORK_DIR/function.sh"

# case <expected: reboot|none> <running> <installed...> -- <boot-tool list or "-"> [pin] [next-boot pin]
check() {
  local expected="$1" running="$2" list pin next
  shift 2
  rm -rf "${WORK_DIR:?}/boot" "${WORK_DIR:?}/pins" "${WORK_DIR:?}/bin"
  mkdir -p "$WORK_DIR/boot" "$WORK_DIR/pins" "$WORK_DIR/bin"
  while [[ "$1" != -- ]]; do touch "$WORK_DIR/boot/vmlinuz-$1"; shift; done
  shift
  list="$1" pin="${2:-}" next="${3:-}"
  [[ -z "$pin" ]] || printf '%s\n' "$pin" > "$WORK_DIR/pins/proxmox-boot-pin"
  [[ -z "$next" ]] || printf '%s\n' "$next" > "$WORK_DIR/pins/next-boot-pin"
  printf '#!/bin/sh\necho %s\n' "$running" > "$WORK_DIR/bin/uname"
  if [[ "$list" != - ]]; then
    printf '%s\n' "$list" > "$WORK_DIR/list"
    printf '#!/bin/sh\ncat "%s"\n' "$WORK_DIR/list" > "$WORK_DIR/bin/proxmox-boot-tool"
  fi
  chmod +x "$WORK_DIR"/bin/*
  local result=none
  if PATH="$WORK_DIR/bin:$PATH" UU_BOOT_DIR="$WORK_DIR/boot" UU_KERNEL_PIN_DIR="$WORK_DIR/pins" \
    bash -c 'source "$1"; HOST_KERNEL_REBOOT_REQUIRED' _ "$WORK_DIR/function.sh"; then
    result=reboot
  fi
  if [[ "$result" != "$expected" ]]; then
    echo "running $running, list [$list], pin [$pin], next [$next]: expected $expected, got $result" >&2
    exit 1
  fi
}

AUTO=$'Manually selected kernels:\nNone.\n\nAutomatically selected kernels:\n6.8.12-4-pve\n6.8.12-5-pve'
# The newest automatic kernel is running / a newer one was installed.
check none 6.8.12-5-pve 6.8.12-4-pve 6.8.12-5-pve -- "$AUTO"
check reboot 6.8.12-4-pve 6.8.12-4-pve 6.8.12-5-pve -- "$AUTO"
# An extra kept kernel does not make an older kernel the boot choice...
KEPT=$'Manually selected kernels:\n6.5.13-6-pve\n\nAutomatically selected kernels:\n6.8.12-4-pve\n6.8.12-5-pve'
check none 6.8.12-5-pve 6.5.13-6-pve 6.8.12-4-pve 6.8.12-5-pve -- "$KEPT"
# ...and does not hide a reboot after a kernel update.
check reboot 6.8.12-4-pve 6.5.13-6-pve 6.8.12-4-pve 6.8.12-5-pve -- "$KEPT"
# A pinned older kernel is what boots: running it needs no reboot.
check none 6.8.12-4-pve 6.8.12-4-pve 6.8.12-5-pve -- "$AUTO" 6.8.12-4-pve
check reboot 6.8.12-5-pve 6.8.12-4-pve 6.8.12-5-pve -- "$AUTO" 6.8.12-4-pve
# A one-time next-boot pin wins over the permanent pin.
check reboot 6.8.12-4-pve 6.8.12-4-pve 6.8.12-5-pve -- "$AUTO" 6.8.12-4-pve 6.8.12-5-pve
# A pin to a removed kernel is ignored.
check none 6.8.12-5-pve 6.8.12-4-pve 6.8.12-5-pve -- "$AUTO" 6.2.16-1-pve
# Without proxmox-boot-tool, the installed kernels in /boot decide.
check reboot 6.8.12-4-pve 6.8.12-4-pve 6.14.8-2-pve -- -
check none 6.14.8-2-pve 6.8.12-4-pve 6.14.8-2-pve -- -

echo 'host kernel reboot detection: PASS'
