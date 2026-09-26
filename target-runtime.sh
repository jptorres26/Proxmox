#!/bin/bash

# Small shared runtime helpers for the Target -> Transport -> Updater split.
# These wrappers only select an existing transport; they do not add retries,
# lifecycle handling, authentication, or update policy.

# Return success when the Proxmox VM configuration enables the QEMU Guest
# Agent.  Proxmox supports both the legacy shorthand (`agent: 1`) and the
# property form (`agent: enabled=1`), with optional comma-separated settings.
# This intentionally checks configuration only; runtime readiness is still
# established by the existing qm agent/guest-exec probes.
QGA_CONFIG_ENABLED() {
  local vmid="${1:-}" agent_value primary
  [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
  agent_value=$(qm config "$vmid" 2>/dev/null |
    awk -F: '$1 ~ /^[[:space:]]*agent[[:space:]]*$/ {
      value=$2
      sub(/^[[:space:]]*/, "", value)
      print value
      exit
    }') || return 1
  primary=${agent_value%%,*}
  case "$primary" in
    1|enabled=1) return 0 ;;
    *) return 1 ;;
  esac
}

RUN_LOCAL_COMMAND() {
  "$@"
}

# Print the configured internet check as a POSIX sh command for the host or a
# guest (run it with `sh -c`). Only ping and curl are supported and the
# address must be a host name or IP address: both values used to be pasted
# into `bash -c` strings on the host and in every guest, and curl was called
# as `curl -q -c1 URL`, which wrote a cookie jar named "1".
INTERNET_CHECK_COMMAND() {
  local executable="${CHECK_URL_EXE:-${EXE_FOR_INTERNET_CHECK:-ping}}" url="${CHECK_URL:-}"
  [[ "$url" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] || return 1
  case "${executable##*/}" in
    curl) printf 'curl -fsS -o /dev/null --max-time 10 %s >/dev/null 2>&1' "$url" ;;
    *) printf 'ping -q -c1 %s >/dev/null 2>&1' "$url" ;;
  esac
}

# Print PACMAN_ENVIRONMENT ("NAME=value NAME2=value") one assignment per line,
# or fail when it is anything else. It used to be run as shell code.
PACMAN_ENVIRONMENT_ASSIGNMENTS() {
  local assignment
  local -a assignments=()
  read -r -a assignments <<< "${PACMAN_ENVIRONMENT:-}"
  # The documented example used to start with "env".
  [[ "${assignments[0]:-}" == env ]] && assignments=("${assignments[@]:1}")
  for assignment in "${assignments[@]}"; do
    [[ "$assignment" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:@%+,=-]*$ ]] || return 1
    printf '%s\n' "$assignment"
  done
}

RUN_PCT_COMMAND() {
  local target_id="$1"
  shift
  timeout "${UU_CHECK_PCT_COMMAND_TIMEOUT:-120}" pct exec "$target_id" -- "$@"
}

RUN_SSH_COMMAND() {
  local host="$1" port="$2" user="$3"
  shift 3
  local identity_file="${RUN_SSH_IDENTITY_FILE:-}"
  # Keepalives detect a dead peer within about two minutes, independent of
  # the overall command timeout.
  local -a ssh_options=(-q -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
  if [[ -n "$identity_file" ]]; then
    ssh_options+=(-o IdentitiesOnly=yes -i "$identity_file")
  fi
  timeout "${UU_SSH_COMMAND_TIMEOUT:-120}" ssh "${ssh_options[@]}" -p "$port" "$user@$host" "$@"
}

READ_APT_UPDATE_COUNTS() {
  local apt_output="$1"
  local apt_total
  SECURITY_APT_UPDATES=$(printf '%s\n' "$apt_output" | grep -ci '^inst.*security' || true)
  apt_total=$(printf '%s\n' "$apt_output" | grep -ci '^inst.' || true)
  # The total install count includes security updates.  Keep the status
  # fields disjoint so normal + security never double-counts packages.
  # shellcheck disable=SC2034
  NORMAL_APT_UPDATES=$((apt_total - SECURITY_APT_UPDATES))
}

# Proxmox commands are noisy because the API prints task/UPID progress. Keep
# that implementation detail out of normal user logs while retaining the
# exact command output and return code for DEBUG and caller-side diagnostics.
RUN_PROXMOX_COMMAND() {
  if [[ "${DEBUG:-false}" == true ]]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

RUN_PROXMOX_CAPTURE() {
  local rc
  PROXMOX_CAPTURE_OUTPUT=$("$@" 2>&1)
  rc=$?
  if [[ "${DEBUG:-false}" == true && -n "$PROXMOX_CAPTURE_OUTPUT" ]]; then
    printf '%s\n' "$PROXMOX_CAPTURE_OUTPUT"
  fi
  return "$rc"
}
