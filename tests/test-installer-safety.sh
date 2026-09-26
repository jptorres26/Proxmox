#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # harness code; stubs are called by extracted functions.
set -euo pipefail

# Installer safety:
# - crontab changes edit only our check entry (uninstall and legacy
#   migration restored an old snapshot, discarding later changes, and
#   uninstall could leave no /etc/crontab at all);
# - uninstall removes scheduler timers and CLI links;
# - downloaded archives with links, devices, absolute or ".." paths are
#   rejected, and extraction does not keep the archive's owner.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
INSTALL="$ROOT_DIR/install.sh"

# --- crontab entry --------------------------------------------------------------------
sed -n '/^CRONTAB_SET_CHECK_ENTRY () {/,/^}/p' "$INSTALL" | sed "s|/etc/crontab|$WORK_DIR/crontab|g" > "$WORK_DIR/cron.sh"
grep -q CRONTAB_SET_CHECK_ENTRY "$WORK_DIR/cron.sh"
cat > "$WORK_DIR/crontab" <<'CRON'
SHELL=/bin/sh
17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
00 07,19 * * *  root    /root/Proxmox-Updater/check-updates.sh
30 2    * * *   root    /usr/local/bin/backup-added-later
CRON
bash -c 'source "$1"; CRONTAB_SET_CHECK_ENTRY' _ "$WORK_DIR/cron.sh"
grep -Fq '/usr/local/bin/backup-added-later' "$WORK_DIR/crontab"     # later changes survive
if grep -Fq 'check-updates.sh' "$WORK_DIR/crontab"; then echo 'old check entry kept' >&2; exit 1; fi
[[ $(grep -c 'update -check' "$WORK_DIR/crontab") -eq 1 ]]
ls "$WORK_DIR"/crontab.bak.* >/dev/null                             # a dated backup exists

# --- uninstall and migration never restore a crontab snapshot ----------------------------
if grep -nE 'mv /etc/crontab\.bak /etc/crontab|cp /etc/crontab\.bak /etc/crontab' "$INSTALL"; then
  echo 'the installer still restores an old crontab snapshot' >&2
  exit 1
fi
uninstall=$(sed -n '/^UNINSTALL () {/,/^}/p' "$INSTALL")
grep -Fq 'ultimate-updater-schedule-*.timer' <<< "$uninstall"
grep -Fq '/usr/local/sbin/ultimate-updater /usr/local/sbin/ultimate-updater-web-auth' <<< "$uninstall"
grep -Fq "sed -i '\\|/usr/local/sbin/update -check|d; \\|check-updates\\.sh|d' /etc/crontab" <<< "$uninstall"

# --- archive validation --------------------------------------------------------------------
sed -n '/^DOWNLOAD_FILE() {/,/^}/p' "$INSTALL" > "$WORK_DIR/download.sh"
grep -q DOWNLOAD_FILE "$WORK_DIR/download.sh"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/src/good/ultimate-updater" "$WORK_DIR/src/link/ultimate-updater"
cat > "$WORK_DIR/bin/curl" <<'STUB'
#!/bin/bash
# Serve $SERVE_FILE: write it to the -o path and print the HTTP code.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) cp "$SERVE_FILE" "$2"; shift 2 ;;
    -D) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '200'
STUB
chmod +x "$WORK_DIR/bin/curl"
touch "$WORK_DIR/src/good/ultimate-updater/update.sh" "$WORK_DIR/src/link/ultimate-updater/update.sh"
ln -s /etc/shadow "$WORK_DIR/src/link/ultimate-updater/shadow"
tar -czf "$WORK_DIR/good.tar.gz" -C "$WORK_DIR/src/good" ultimate-updater
tar -czf "$WORK_DIR/link.tar.gz" -C "$WORK_DIR/src/link" ultimate-updater
tar -czf "$WORK_DIR/dotdot.tar.gz" -C "$WORK_DIR/src/good" ultimate-updater \
  --transform 's|^ultimate-updater/update.sh$|ultimate-updater/../update.sh|'

download() {
  SERVE_FILE="$WORK_DIR/$1.tar.gz" PATH="$WORK_DIR/bin:$PATH" \
    bash -c 'source "$1"; DOWNLOAD_FILE https://example.invalid/a.tar.gz "$2" archive' _ \
    "$WORK_DIR/download.sh" "$WORK_DIR/out-$1.tar.gz"
}
download good
for bad in link dotdot; do
  if download "$bad" 2>"$WORK_DIR/$bad.err"; then
    echo "archive with $bad entries accepted" >&2
    exit 1
  fi
  grep -Fq 'unsafe entries' "$WORK_DIR/$bad.err" || grep -Fq 'failed validation' "$WORK_DIR/$bad.err"
  [[ ! -e "$WORK_DIR/out-$bad.tar.gz" ]]
done

[[ $(grep -c 'tar --no-same-owner -zxf "$TEMP_FOLDER/ultimate-updater.tar.gz"' "$INSTALL") -eq 2 ]]
if grep -nE '^[^#]*tar -zxf' "$INSTALL"; then echo 'extraction keeps the archive owner' >&2; exit 1; fi

# --- web-auth keeps the password exactly as typed ------------------------------------
grep -Fq "IFS= read -r -s -p 'Password: ' PASSWORD" "$ROOT_DIR/web-auth.sh"
grep -Fq "IFS= read -r -s -p 'Repeat password: ' PASSWORD_REPEAT" "$ROOT_DIR/web-auth.sh"

# --- a targets.conf that is not a regular file is an error, not an empty inventory ---
mkdir "$WORK_DIR/targets.conf.d"
if bash -c 'source "$1/target-inventory.sh"; TARGET_INVENTORY_LOAD "$2"' _ "$ROOT_DIR" "$WORK_DIR/targets.conf.d" 2>/dev/null; then
  echo 'a directory was accepted as targets.conf' >&2
  exit 1
fi

echo 'installer safety: PASS'
