#!/usr/bin/env bash
# shellcheck disable=SC2016 # the harness body expands in the child shell.
set -euo pipefail

# CHECK_VM probes SSH before it queries the package manager. A failed pkg or
# apt query on the reachable guest is a check failure, not an offline guest;
# only ssh's own exit status 255 means the connection failed.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
cp "$ROOT_DIR/internal-ssh.sh" "$WORK_DIR/internal-ssh.sh"
printf 'schema_version=1\n\n[vm:100]\nhost=192.0.2.100\nuser=root\nport=22\nenabled=true\n' \
  > "$WORK_DIR/internal-ssh.conf"
# CHECK_VM and the helpers defined after it, up to CHECK_VM_QEMU.
awk '/^CHECK_VM \(\) \{/{copy=1} /^CHECK_VM_QEMU \(\) \{/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-vm.sh"
grep -q '^RECORD_SSH_CHECK_FAILURE () {' "$WORK_DIR/check-vm.sh"

run_check() {  # run_check <guest: freebsd|debian> <package query exit status>
  : > "$WORK_DIR/records"
  (cd "$WORK_DIR" && GUEST="$1" QUERY_RC="$2" bash -c '
    LOCAL_FILES="$PWD" INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
    INITIAL_INVENTORY=false RDU=false STATUS_MODEL_NODE=pve1
    GN="" BL="" CL="" OR=""
    SANITIZE_NUMBER() { printf "%s" "$1"; }
    PRINT_UPDATE_SPLIT() { :; }
    PRINT_UPDATE_TOTAL() { :; }
    READ_APT_UPDATE_COUNTS() { NORMAL_APT_UPDATES=0 SECURITY_APT_UPDATES=0; }
    INTERNAL_SSH_USE_IDENTITY() { :; }
    INTERNAL_SSH_RESOLVE_VM() { source "$PWD/internal-ssh.sh"; INTERNAL_SSH_RESOLVE vm "$1" "$2" "$3" "$4"; }
    CHECK_VM_QEMU() { echo qga-called >> "$PWD/records"; }
    STATUS_MODEL_RECORD() { printf "%s\n" "$*" >> "$PWD/records"; }
    qm() { [[ "$1" == config ]] && printf "ostype: other\nname: guest\n"; return 0; }
    RUN_SSH_COMMAND() {
      case "$GUEST:$4" in
        *:true) return 0 ;;
        freebsd:"uname -s") echo FreeBSD ;;
        freebsd:"uname -v") echo "FreeBSD pfSense" ;;
        freebsd:"pkg version -U -l '"'"'<'"'"'") return "$QUERY_RC" ;;
        debian:"cat /etc/os-release") echo "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"" ;;
        debian:"uname -s") echo Linux ;;
        debian:"apt-get -s --with-new-pkgs upgrade") return "$QUERY_RC" ;;
        debian:"apt-get update") return 0 ;;
        *) return 1 ;;
      esac
    }
    source "$PWD/internal-ssh.sh"
    source "$PWD/check-vm.sh"
    CHECK_VM 100 > /dev/null' && echo "rc=0" || echo "rc=$?") > "$WORK_DIR/result"
}

expect() {  # expect <fixed string in the record>
  if ! grep -Fq -- "$1" "$WORK_DIR/records"; then
    printf 'missing record: %s\ngot:\n' "$1" >&2
    cat "$WORK_DIR/records" >&2
    exit 1
  fi
}

run_check freebsd 1
expect '100 vm ssh true pfSense pkg null null error CHECK_COMMAND_FAILED pkg version failed for VM 100 (exit status 1) pve1'
grep -Fxq 'rc=1' "$WORK_DIR/result"

run_check freebsd 255
expect '100 vm ssh false pfSense pkg null null error SSH_TRANSPORT'

run_check debian 100
expect '100 vm ssh true Debian GNU/Linux 13 (trixie) apt null null error CHECK_COMMAND_FAILED apt-get simulation failed for VM 100 (exit status 100)'
grep -Fxq 'rc=1' "$WORK_DIR/result"

run_check debian 255
expect '100 vm ssh false Debian GNU/Linux 13 (trixie) apt null null error SSH_TRANSPORT'

# A working guest is still recorded normally.
run_check debian 0
expect '100 vm ssh true Debian GNU/Linux 13 (trixie) apt 0 false ok'
if grep -Fq qga-called "$WORK_DIR/records"; then
  echo 'an SSH guest fell back to QGA' >&2
  exit 1
fi

echo 'VM SSH check failures: PASS'
