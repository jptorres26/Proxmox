#!/bin/bash

##########
# Update #
##########

VERSION="5.1.2"

# A protection failure must make the overall update job fail, even when the
# configured continue-on-error mode allows other guests to be processed.
SAFETY_FAILURE=false
# Continue-on-error keeps processing later targets, but real target failures
# must still produce a non-zero final update result.
UPDATE_FAILURE=false

# Variable / Function
LOCAL_FILES="${UU_LOCAL_FILES:-/etc/ultimate-updater}"
TEMP_FOLDER="/root/Ultimate-Updater-Temp"
TEMP_STATE_DIR="${UU_TEMP_STATE_DIR:-$LOCAL_FILES/temp}"
CONFIG_FILE="$LOCAL_FILES/update.conf"
CHECK_SCRIPT="${UU_CHECK_SCRIPT:-$LOCAL_FILES/check-updates.sh}"
USER_SCRIPTS="${USER_SCRIPTS:-$LOCAL_FILES/scripts.d}"
TARGET_RUNTIME_FILE="${TARGET_RUNTIME_FILE:-$LOCAL_FILES/target-runtime.sh}"
if [[ -f "$TARGET_RUNTIME_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$TARGET_RUNTIME_FILE"
else
  # These indirect transport calls are used by the legacy-compatible paths
  # below when an older installation has no shared runtime helper yet.
  # shellcheck disable=SC2317,SC2329
  RUN_LOCAL_COMMAND() { "$@"; }
  RUN_PCT_COMMAND() { local target_id="$1"; shift; pct exec "$target_id" -- "$@"; }
  RUN_SSH_COMMAND() { local host="$1" port="$2" user="$3"; shift 3; ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$user@$host" "$@"; }
  RUN_PROXMOX_COMMAND() { if [[ "${DEBUG:-false}" == true ]]; then "$@"; else "$@" >/dev/null 2>&1; fi; }
  RUN_PROXMOX_CAPTURE() { local rc; PROXMOX_CAPTURE_OUTPUT=$("$@" 2>&1); rc=$?; [[ "${DEBUG:-false}" == true && -n "$PROXMOX_CAPTURE_OUTPUT" ]] && printf '%s\n' "$PROXMOX_CAPTURE_OUTPUT"; return "$rc"; }
  INTERNET_CHECK_COMMAND() { [[ "${CHECK_URL:-}" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] && printf 'ping -q -c1 %s >/dev/null 2>&1' "$CHECK_URL"; }
  PACMAN_ENVIRONMENT_ASSIGNMENTS() { [[ -z "${PACMAN_ENVIRONMENT:-}" ]]; }
  VM_IS_HIBERNATED() { qm config "$1" 2>/dev/null | grep -Eq '^(lock: suspend(ed|ing)|vmstate:)'; }
fi
CLUSTER_TARGET_FILE="${CLUSTER_TARGET_FILE:-$LOCAL_FILES/cluster-target.sh}"
if [[ -f "$CLUSTER_TARGET_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$CLUSTER_TARGET_FILE"
fi
INTERNAL_SSH_FILE="${INTERNAL_SSH_FILE:-$LOCAL_FILES/internal-ssh.sh}"
if [[ -f "$INTERNAL_SSH_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$INTERNAL_SSH_FILE"
else
  INTERNAL_SSH_ARGS=()
  INTERNAL_SSH_USE_IDENTITY() { :; }
  INTERNAL_SSH_RESOLVE_NODE() { INTERNAL_SSH_HOST="$2"; INTERNAL_SSH_USER=root; INTERNAL_SSH_PORT="${3:-22}"; }
  INTERNAL_SSH_RESOLVE_VM() { INTERNAL_SSH_HOST="$2"; INTERNAL_SSH_USER="$3"; INTERNAL_SSH_PORT="${4:-22}"; }
fi
ssh() { command ssh "${INTERNAL_SSH_ARGS[@]}" "$@"; }
scp() { command scp "${INTERNAL_SSH_ARGS[@]}" "$@"; }
WINDOWS_UPDATE_FILE="${WINDOWS_UPDATE_FILE:-$LOCAL_FILES/windows-update.sh}"
if [[ -f "$WINDOWS_UPDATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$WINDOWS_UPDATE_FILE"
fi
if [[ -f "$LOCAL_FILES/status-model.sh" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$LOCAL_FILES/status-model.sh"
fi
if ! declare -F UU_SEND_MAIL >/dev/null; then
  # Installations without status-model.sh; called from the EXIT trap.
  # shellcheck disable=SC2329
  UU_SEND_MAIL() {
    local from="$2"
    [[ "$from" == "\$USER" ]] && from=$(id -un)
    mail -s "$3" -r "$from" -- "$1"
  }
fi
INSTALLED_BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "$CONFIG_FILE")
case "$INSTALLED_BRANCH" in
  master|beta|develop) ;;
  *) INSTALLED_BRANCH=master ;;
esac
BUILD_METADATA_FILE="${UU_BUILD_METADATA_FILE:-$LOCAL_FILES/build-metadata}"
INSTALLED_COMMIT=""
INSTALLED_TAG=""
if [[ -r "$BUILD_METADATA_FILE" ]]; then
  INSTALLED_COMMIT=$(awk -F'"' '/^commit=/ {print $2; exit}' "$BUILD_METADATA_FILE")
  INSTALLED_TAG=$(awk -F'"' '/^tag=/ {print $2; exit}' "$BUILD_METADATA_FILE")
fi
[[ "$INSTALLED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || INSTALLED_COMMIT="unknown"
[[ "$INSTALLED_TAG" =~ ^[A-Za-z0-9._/-]+$ ]] || INSTALLED_TAG=""
# USED_BRANCH describes the installed source only. A bare -up is always the
# stable master target; beta/develop require an explicit selector.
BRANCH=master
DPKG_OPTIONS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
DPKG_OPTIONS_STRING="${DPKG_OPTIONS[*]}"
# Upper bound (seconds) for one package-manager step run through the QEMU
# Guest Agent. qm's default of 30 seconds (120 for the old APT upgrade) ended
# the wait while dpkg/dnf was still working, and a VM that had been started
# only for the update was then shut down in the middle of the transaction.
QGA_UPDATE_TIMEOUT="${UU_QGA_UPDATE_TIMEOUT:-3600}"
[[ "$QGA_UPDATE_TIMEOUT" =~ ^[1-9][0-9]{0,5}$ ]] || QGA_UPDATE_TIMEOUT=3600

# Tag filter
# shellcheck disable=SC1091
. "$LOCAL_FILES/tag-filter.sh"

# Source repository for self-updates (see UU_SOURCE_REPOSITORY in
# tag-filter.sh). Exported so a downloaded installer keeps using it.
if declare -F UU_SOURCE_REPOSITORY >/dev/null; then
  UU_REPOSITORY=$(UU_SOURCE_REPOSITORY)
else
  UU_REPOSITORY="BassT23/Proxmox"
fi
export UU_REPOSITORY
SERVER_URL="https://raw.githubusercontent.com/$UU_REPOSITORY/$INSTALLED_BRANCH"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

DOWNLOAD_SHELL_FILE() {
  local url="$1" temporary headers http_code retry_after
  mkdir -p "$TEMP_FOLDER" || return 1
  temporary=$(mktemp "$TEMP_FOLDER/download.sh.XXXXXX") || return 1
  headers=$(mktemp "$TEMP_FOLDER/download.headers.XXXXXX") || { rm -f -- "$temporary"; return 1; }
  http_code=$(curl -4 -sS -fSL --retry 0 --connect-timeout 5 --max-time 120 \
    -D "$headers" -o "$temporary" -w '%{http_code}' "$url" 2>/dev/null) || {
    if [[ "$http_code" == 429 ]]; then
      retry_after=$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$headers")
      if [[ -n "$retry_after" ]]; then
        echo "GitHub temporarily rate-limited the download (Retry-After: $retry_after). Please retry later." >&2
      else
        echo "GitHub temporarily rate-limited the download. Please retry later." >&2
      fi
    else
      echo "Download failed (HTTP ${http_code:-unavailable})." >&2
    fi
    rm -f -- "$temporary" "$headers"
    return 1
  }
  if [[ ! -s "$temporary" ]] || ! [[ "$(head -n 1 "$temporary")" =~ ^#!.*(bash|sh) ]] || ! bash -n "$temporary"; then
    echo "Downloaded installer failed shell validation." >&2
    rm -f -- "$temporary" "$headers"
    return 1
  fi
  rm -f -- "$headers"
  printf '%s\n' "$temporary"
}

RUN_DOWNLOADED_INSTALLER() {
  local installer_path rc command
  local -a environment=()
  installer_path=$(DOWNLOAD_SHELL_FILE "$1") || return 1
  shift
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    environment+=("$1")
    shift
  done
  command=${1:-}
  shift || true
  env "${environment[@]}" bash "$installer_path" "$command" "$@"
  rc=$?
  rm -f -- "$installer_path"
  return "$rc"
}



# Header
HEADER_INFO () {
  clear 2>/dev/null || true
  echo -e "\n \
    https://github.com/BassT23/Proxmox\n"
  cat <<'EOF'
 The __  ______  _                 __
    / / / / / /_(_)___ ___  ____ _/ /____
   / / / / / __/ / __ `__ \/ __ `/ __/ _ \
  / /_/ / / /_/ / / / / / / /_/ / /_/  __/
  \____/_/\__/_/_/ /_/ /_/\____/\__/\___/
     __  __          __      __
    / / / /___  ____/ /___ _/ /____  ____
   / / / / __ \/ __  / __ `/ __/ _ \/ __/
  / /_/ / /_/ / /_/ / /_/ / /_/  __/ /
  \____/ ____/\____/\____/\__/\___/_/
      /_/                for Proxmox VE
EOF
  if [[ "$INFO" != false ]]; then
    echo -e "\n \
          ***  Mode: $MODE***"
    if [[ "$HEADLESS" == true ]]; then
      echo -e "           ***    Headless    ***"
    else
      echo -e "           ***   Interactive  ***"
    fi
  fi
  CHECK_ROOT
  CHECK_INTERNET
  if [[ "$INFO" != false && "$CHECK_VERSION" == true ]]; then VERSION_CHECK; else echo; fi
  # Print tag selection summary captured during config parse
  [[ "${TAG_LOG:-}" == "true" ]] && type print_tag_log >/dev/null 2>&1 && { print_tag_log; echo; } || true
}

# Check root
CHECK_ROOT () {
  if [[ "$RICM" != true && "$EUID" -ne 0 ]]; then
      echo -e "\n${RD:-} ⚠ --- Please run this as root --- ⚠${CL:-}\n"
      exit 2
  fi
}

START_INITIAL_INVENTORY () {
  local job_runner="$LOCAL_FILES/job-runner.sh" cli="$LOCAL_FILES/ultimate-updater" output
  [[ "$EUID" -eq 0 ]] || { echo -e "${RD:-}❌ Initial inventory requires root.${CL:-}" >&2; return 2; }
  [[ -x "$job_runner" && -x "$cli" ]] || {
    echo -e "${RD:-}❌ Initial inventory infrastructure is unavailable.${CL:-}" >&2
    return 1
  }
  if ! output=$(UU_JOB_SOURCE=initial-inventory timeout 15 "$job_runner" start-check all-systems "$cli" all 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
  INITIAL_INVENTORY_CLI=true
  echo 'Initial inventory started.'
  printf '%s\n' "$output"
}

# Check internet status
CHECK_INTERNET () {
  local attempt delay command
  if ! command=$(INTERNET_CHECK_COMMAND); then
    echo -e "${RD:-}❌ URL_FOR_INTERNET_CHECK must be a host name or IP address${CL:-}"
    return 1
  fi
  for attempt in 1 2 3; do
    if sh -c "$command"; then
      [[ "$attempt" -gt 1 ]] && echo -e "${GN:-}✅ Internet connection available${CL:-}"
      return 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
      delay=$((attempt + 1))
      echo "Internet check failed (attempt $attempt/3), retrying..." >&2
      sleep "$delay"
    fi
  done
  echo -e "\n${OR:-} ❌ Internet check fail - Can't update without internet${CL:-}\n"
  exit 2
}

ARGUMENTS () {
  while [[ $# -gt 0 ]]; do
    local ARGUMENT="$1"
    case "$ARGUMENT" in
      [0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9])
        COMMAND=true
        SINGLE_UPDATE=true
        MODE=" Single "
        ONLY=$ARGUMENT
        if declare -f cluster_target_resolve >/dev/null 2>&1 &&
          { [[ -n "${UU_CLUSTER_RESOURCES_JSON:-}" ]] || command -v pvesh >/dev/null 2>&1; }; then
          if cluster_target_resolve "$ARGUMENT"; then
            if [[ "$CLUSTER_TARGET_LOCAL" == false ]]; then
              local remote_command
              printf -v remote_command 'exec %q start %q %q' \
                "/etc/ultimate-updater/job-runner.sh" "/etc/ultimate-updater/update.sh" "$ARGUMENT"
              echo -e "ℹ ${OR:-} Target $ARGUMENT resolved to $CLUSTER_TARGET_NODE; starting remote update job${CL:-}\n"
              local remote_output remote_job_unit
              if ! remote_output=$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "${SSH_PORT:-22}" \
                "$CLUSTER_TARGET_HOST" "$remote_command"); then
                echo -e "${RD:-}❌ Could not start update job on $CLUSTER_TARGET_NODE${CL:-}" >&2
                return 6
              fi
              printf '%s\n' "$remote_output"
              remote_job_unit=$(printf '%s\n' "$remote_output" | sed -n 's/^Job:[[:space:]]*//p' | head -n 1)
              if [[ ! "$remote_job_unit" =~ ^ultimate-updater-update-[A-Za-z0-9_.-]+$ ]] ||
                ! "$LOCAL_FILES/job-runner.sh" record-remote "$remote_job_unit" "$ARGUMENT" \
                  "$CLUSTER_TARGET_NODE" "$CLUSTER_TARGET_HOST" "${SSH_PORT:-22}"; then
                echo -e "${RD:-}❌ Remote job started but could not be referenced locally${CL:-}" >&2
                return 7
              fi
              REMOTE_TARGET_DISPATCHED=true
              shift
              continue
            fi
          else
            local cluster_result=$?
            case "$cluster_result" in
              1) echo -e "${RD:-}❌ Target $ARGUMENT not found in Proxmox cluster${CL:-}" >&2 ;;
              2) echo -e "${RD:-}❌ Target ID must be numeric: $ARGUMENT${CL:-}" >&2 ;;
              4) echo -e "${RD:-}❌ Target ID $ARGUMENT is ambiguous across the cluster${CL:-}" >&2 ;;
              *) echo -e "${RD:-}❌ Could not read the Proxmox cluster inventory${CL:-}" >&2 ;;
            esac
            return "$cluster_result"
          fi
        fi
        HEADER_INFO
        if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Continue after errors: enabled${CL:-}\n"; else echo -e "ℹ ${OR:-} Continue after errors: disabled${CL:-}\n"; fi
        echo -e "ℹ ${OR:-} Updating only LXC/VM $ARGUMENT${CL:-}\n"
        CONTAINER_UPDATE_START
        VM_UPDATE_START
        ;;
      -h|--help) USAGE; exit 0 ;;
      -v|--version) VERSION_CHECK; exit 0 ;;
      -s|--silent) HEADLESS=true ;;
      -c) RICM=true ;;
      -w) WELCOME_SCREEN=true ;;
      host)
        COMMAND=true
        TAG_LOG=true
        if [[ "$RICM" != true ]]; then
          MODE="  Host  "
          HEADER_INFO
          if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Continue after errors: enabled${CL:-}\n"; else echo -e "ℹ ${OR:-} Continue after errors: disabled${CL:-}\n"; fi
        fi
        echo -e "🔄${GN:-} Updating Host${CL:-} : ${GN:-}$IP | ($HOSTNAME)${CL:-}\n"
        if [[ "$WITH_HOST" == true ]]; then
          UPDATE_HOST_ITSELF
        else
          echo -e "⏩${BL:-} Skipped host itself by the user${CL:-}\n\n"
        fi
        if [[ "${UU_UPDATE_SCOPE:-}" == host ]]; then
          echo -e "⏩${BL:-} Skipped all containers and VMs: host-only update${CL:-}\n"
        elif [[ "$WITH_LXC" == true ]]; then
          CONTAINER_UPDATE_START
        else
          echo -e "⏩${BL:-} Skipped all containers by the user${CL:-}\n"
        fi
        if [[ "${UU_UPDATE_SCOPE:-}" != host && "$WITH_VM" == true ]]; then
          VM_UPDATE_START
        elif [[ "${UU_UPDATE_SCOPE:-}" != host ]]; then
          echo -e "⏩${BL:-} Skipped all VMs by the user${CL:-}\n"
        fi
        ;;
      cluster)
        COMMAND=true
        MODE="Cluster "
        HEADER_INFO
        HOST_UPDATE_START
        ;;
      uninstall)
        COMMAND=true
        UNINSTALL
        # shellcheck disable=SC2317
        exit 2
        ;;
      master|beta|develop)
        if [[ "$2" != -up ]]; then
          echo -e "\n${OR:-}  Wrong usage! Use branch update like this:${CL:-}"
          echo -e "  update $ARGUMENT -up\n"
          exit 2
        fi
        BRANCH=$ARGUMENT
        EXPLICIT_BRANCH=true
        ;;
      -up)
        COMMAND=true
        # BRANCH is initialized to master. An explicit selector above is the
        # only way to target beta or develop.
        UPDATE
        exit $?
        ;;
      -dist-upgrade)
        INFO=false
        HEADER_INFO
        COMMAND=true
        READ_CONFIG
        CHECK_DIST=true
        CONTAINER_UPDATE_START
        exit 2
        ;;
      -check)
        "$LOCAL_FILES/check-updates.sh"
        exit $?
        ;;
      inventory)
        COMMAND=true
        START_INITIAL_INVENTORY
        exit $?
        ;;
      status)
        INFO=false
        HEADER_INFO
        COMMAND=true
        STATUS
        exit 2
        ;;
      *)
        echo -e "\n${RD:-} ❌ Error: Got an unexpected argument \"$ARGUMENT\"${CL:-}";
        USAGE;
        exit 2;
        ;;
    esac
    shift
  done
}

# Usage
USAGE () {
  if [[ "$HEADLESS" != true ]]; then
    echo -e "Usage: $0 [OPTIONS...] {COMMAND}\n"
    echo -e "[OPTIONS] Manages the Ultimate Updater:"
    echo -e "======================================"
    echo -e "  master               Use master branch"
    echo -e "  beta                 Use beta branch (pre-release)"
    echo -e "  develop              Use develop branch\n"
    echo -e "{COMMAND}:"
    echo -e "========="
    echo -e "  -s --silent          Silent / Headless Mode"
    echo -e "  -h --help            Show help menu"
    echo -e "  -v --version         Show The Ultimate Updater version"
    echo -e "  -dist-upgrade        Run distribution upgrade (Debian 12 -> 13)"
    echo -e "  -check               Run check-updates.sh"
    echo -e "  inventory            Start a read-only initial inventory job"
    echo -e "  -up                  Update/install the stable master branch"
    echo -e "  master -up           Explicitly install/update master"
    echo -e "  beta -up             Explicitly install/update beta"
    echo -e "  develop -up          Explicitly install/update develop"
    echo -e "  status               Show Status (Version Infos)"
    echo -e "  uninstall            Uninstall The Ultimate Updater\n"
    echo -e "  host                 Host-Mode"
    echo -e "  cluster              Cluster-Mode\n"
    echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

# Version Check / Update Message in Header
RUN_BRANCH_UPDATE () {
  local target_branch=$1 installer cache_buster
  cache_buster=$(date +%s)

  if ! installer=$(DOWNLOAD_SHELL_FILE "https://raw.githubusercontent.com/$UU_REPOSITORY/refs/heads/$target_branch/install.sh?uu_cache=$cache_buster"); then
    echo -e "${RD:-}Unable to download the $target_branch installer.${CL:-}"
    return 1
  fi
  env UU_TARGET_BRANCH="$target_branch" bash "$installer" update
  local rc=$?
  rm -f -- "$installer"
  return "$rc"
}

SHOW_UPDATE_NOTICE () {
  local target_branch=$1 remote_version=$2

  echo -e "${OR:-}*** A newer version is available ***${CL:-}\n\
       Installed: $LOCAL_VERSION / $target_branch: $remote_version"
  if [[ "$HEADLESS" != true ]]; then
    echo -e "${OR:-}Want to update The Ultimate Updater first?${CL:-}"
    read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
    if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
      RUN_BRANCH_UPDATE "$target_branch"
    fi
    echo
  fi
}

VERSION_CHECK () {
  local candidate remote_version remote_available=false
  local -a candidates
  local branch_for_status=${INSTALLED_BRANCH:-master}

  LOCAL_VERSION=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$LOCAL_FILES/update.sh")
  case "$branch_for_status" in
    master) candidates=(master) ;;
    beta) candidates=(master beta) ;;
    develop) candidates=(master beta develop) ;;
    *)
      echo -e "${OR:-}The configured branch '$branch_for_status' is not active; use master, beta, or develop.${CL:-}"
      echo -e "                 Version: $VERSION"
      return 0
      ;;
  esac

  if [[ "$branch_for_status" == develop ]]; then
    echo -e "${OR:-}*** The Ultimate Updater is on develop branch ***${CL:-}"
  elif [[ "$branch_for_status" == beta ]]; then
    echo -e "${OR:-}*** The Ultimate Updater is on beta branch (pre-release) ***${CL:-}"
  fi
  VERSION_NOT_SHOW=false
  for candidate in "${candidates[@]}"; do
    if ! remote_version=$(FETCH_REMOTE_VERSION "$candidate" update.sh); then
      echo -e "${OR:-}Unable to read the $candidate version from GitHub.${CL:-}"
      continue
    fi
    remote_available=true
    if version_is_less "$LOCAL_VERSION" "$remote_version"; then
      SHOW_UPDATE_NOTICE "$candidate" "$remote_version"
      VERSION_NOT_SHOW=true
      break
    fi
  done
  if [[ "$VERSION_NOT_SHOW" != true && "$remote_available" == true ]]; then
    echo -e "${GN:-}       The Ultimate Updater is UpToDate${CL:-}"
    echo -e "                 Version: $VERSION"
  elif [[ "$VERSION_NOT_SHOW" != true ]]; then
    echo -e "${OR:-}       Unable to verify the remote version${CL:-}"
    echo -e "                 Version: $VERSION"
  fi
}

# Update The Ultimate Updater
UPDATE () {
  SELF_UPDATE_RUN=true
  local installed_version target_version target_commit installed_commit cache_buster
  cache_buster=$(date +%s)
  installed_version=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$LOCAL_FILES/update.sh" 2>/dev/null || true)
  if ! target_version=$(FETCH_REMOTE_VERSION "$BRANCH" update.sh); then
    echo -e "${RD:-}Unable to determine the target version for branch $BRANCH; update aborted before mutation.${CL:-}" >&2
    return 2
  fi
  installed_commit=$(awk -F'"' '/^commit=/ {print $2; exit}' "$BUILD_METADATA_FILE" 2>/dev/null || true)
  target_commit=$(FETCH_REMOTE_COMMIT "$BRANCH" || true)
  if [[ "$installed_commit" =~ ^[0-9a-f]{40}$ && "$target_commit" == "$installed_commit" ]]; then
    echo -e "${GN:-}       The Ultimate Updater is UpToDate${CL:-}"
    echo -e "                 Version: $installed_version"
    return 0
  fi
  if version_is_less "$target_version" "$installed_version"; then
    echo -e "\n${OR:-}⚠ Downgrade notice${CL:-}\n"
    echo -e "You are currently running Ultimate Updater $installed_version."
    echo -e "The $BRANCH branch currently provides version $target_version."
    echo -e "Running this command will downgrade Ultimate Updater to version $target_version.\n"
    echo -e "The downgrade is not performed automatically. Continue with downgrade? [y/N]"
    if [[ "${UU_NONINTERACTIVE:-false}" == true || ! -t 0 ]]; then
      echo -e "${RD:-}Interactive confirmation required for a downgrade; update aborted before mutation.${CL:-}" >&2
      return 2
    fi
    read -r -p "Continue with downgrade? [y/N] " downgrade_reply
    if [[ ! "$downgrade_reply" =~ ^[Yy]$ ]]; then
      echo "Downgrade cancelled by user."
      return 0
    fi
  fi
  if [[ "${EXPLICIT_BRANCH:-false}" == true && "$BRANCH" != "$INSTALLED_BRANCH" ]]; then
    PRINT_BRANCH_PROMPT
    if [[ "${UU_NONINTERACTIVE:-false}" != true && -t 0 ]]; then
      read -r -p "Type [Y/y] or [Enter] for yes - anything else will exit: " branch_reply
      if [[ "$branch_reply" =~ ^[Nn] || ( -n "$branch_reply" && ! "$branch_reply" =~ ^[Yy]$ ) ]]; then
        return 2
      fi
    fi
  fi
  if [[ "${UU_NONINTERACTIVE:-false}" == true || ! -t 0 ]]; then
    RUN_DOWNLOADED_INSTALLER "https://raw.githubusercontent.com/$UU_REPOSITORY/refs/heads/$BRANCH/install.sh?uu_cache=$cache_buster" \
      UU_TARGET_BRANCH="$BRANCH" UU_NONINTERACTIVE=true update
    return $?
  fi
  RUN_DOWNLOADED_INSTALLER "https://raw.githubusercontent.com/$UU_REPOSITORY/refs/heads/$BRANCH/install.sh?uu_cache=$cache_buster" \
    UU_TARGET_BRANCH="$BRANCH" UU_UPGRADE_INTERACTIVE=true UU_NONINTERACTIVE=true update
  return $?
}

PRINT_BRANCH_PROMPT () {
  local branch_color=""
  case "$BRANCH" in
    beta) branch_color="$OR" ;;
    develop) branch_color="$RD" ;;
  esac
  if [[ -n "$branch_color" ]]; then
    printf 'Update to %b%s%b branch?\n' "$branch_color" "$BRANCH" "$CL"
  else
    printf 'Update to %s branch?\n' "$BRANCH"
  fi
}

# Uninstall
UNINSTALL () {
  echo -e "\n⚠ ${OR:-} Uninstall The Ultimate Updater${CL:-}\n"
  echo -e "${RD:-}Really want to remove The Ultimate Updater?${CL:-}"
  read -p "Type [Y/y] for yes - anything else will exit: " -r
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    RUN_DOWNLOADED_INSTALLER "$SERVER_URL/install.sh" uninstall
    exit 2
  else
    exit 2
  fi
}

# Get the exact commit currently served by the installed branch.  This is
# metadata for comparison only; the installer writes the installed commit.
FETCH_REMOTE_COMMIT() {
  local branch="$1"
  [[ "$branch" =~ ^(master|beta|develop)$ ]] || return 1
  curl -4 -sS --connect-timeout 5 --max-time 15 \
    "https://api.github.com/repos/$UU_REPOSITORY/commits/$branch" 2>/dev/null |
    awk -F'"' '/"sha"[[:space:]]*:/ {print $4; exit}'
}

# Get Server Versions
STATUS () {
  local branch_for_status=${INSTALLED_BRANCH:-master} component label local_file local_version remote_version remote_commit
  local -a components=(
    "Updater|update.sh|$LOCAL_FILES/update.sh"
    "Extras|update-extras.sh|$LOCAL_FILES/update-extras.sh"
    "Config|update.conf|$LOCAL_FILES/update.conf"
  )

  if [[ "$WELCOME_SCREEN" == true ]]; then
    components+=("Welcome|welcome-screen.sh|/etc/update-motd.d/01-welcome-screen")
    components+=("Check|check-updates.sh|$LOCAL_FILES/check-updates.sh")
  fi
  if [[ "$branch_for_status" != master && "$branch_for_status" != beta && "$branch_for_status" != develop ]]; then
    echo -e "${RD:-}Unknown branch '$branch_for_status'; status cannot be retrieved.${CL:-}"
    return 1
  fi

  echo -e "${OR:-}  Version overview ($branch_for_status)${CL:-}\n"
  printf 'Installed commit: %s\n' "${INSTALLED_COMMIT:-unknown}"
  remote_commit=$(FETCH_REMOTE_COMMIT "$branch_for_status" || true)
  [[ "$remote_commit" =~ ^[0-9a-f]{40}$ ]] || remote_commit="unavailable"
  printf 'Available commit: %s\n' "$remote_commit"
  printf 'Installed tag: %s\n\n' "${INSTALLED_TAG:-—}"
  printf '%-12s %-9s %-9s\n' "Component" "Local" "Server"
  printf '%-12s %-9s %-9s\n' "---------" "-----" "------"
  for component in "${components[@]}"; do
    IFS='|' read -r label component local_file <<< "$component"
    local_version=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$local_file" 2>/dev/null || true)
    remote_version=$(FETCH_REMOTE_VERSION "$branch_for_status" "$component" 5 || true)
    if [[ -z "$local_version" ]]; then local_version="unknown"; fi
    if [[ -z "$remote_version" ]]; then remote_version="unavailable"; fi
    if [[ "$local_version" == "$remote_version" ]]; then
      printf '%-12s %b%-9s%b %-9s\n' "$label" "${GN:-}" "$local_version" "${CL:-}" "$remote_version"
    else
      printf '%-12s %-9s %b%-9s%b\n' "$label" "$local_version" "${OR:-}" "$remote_version" "${CL:-}"
    fi
  done
  echo
}

# Read Config File
READ_CONFIG () {
  LOG_FILE=$(awk -F'"' '/^LOG_FILE=/ {print $2}' "$CONFIG_FILE")
  ERROR_LOG_FILE=$(awk -F'"' '/^ERROR_LOG_FILE=/ {print $2}' "$CONFIG_FILE")
  CHECK_VERSION=$(awk -F'"' '/^VERSION_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL=$(awk -F'"' '/^URL_FOR_INTERNET_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL_EXE=$(awk -F'"' '/^EXE_FOR_INTERNET_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL_EXE="${CHECK_URL_EXE:-ping}"
  SSH_PORT=$(awk -F'"' '/^SSH_PORT=/ {print $2}' "$CONFIG_FILE")
  EXIT_ON_ERROR=$(awk -F'"' '/^EXIT_ON_ERROR=/ {print $2}' "$CONFIG_FILE")
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' "$CONFIG_FILE")
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' "$CONFIG_FILE")
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' "$CONFIG_FILE")
  RUNNING_CONTAINER=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  STOPPED_CONTAINER=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  RUNNING_VM=$(awk -F'"' '/^RUNNING_VM=/ {print $2}' "$CONFIG_FILE")
  STOPPED_VM=$(awk -F'"' '/^STOPPED_VM=/ {print $2}' "$CONFIG_FILE")
  FREEBSD_UPDATES=$(awk -F'"' '/^FREEBSD_UPDATES=/ {print $2}' "$CONFIG_FILE")
  SNAPSHOT=$(awk -F'"' '/^SNAPSHOT/ {print $2}' "$CONFIG_FILE")
  KEEP_SNAPSHOT=$(awk -F'"' '/^KEEP_SNAPSHOTS=/ {print $2}' "$CONFIG_FILE")
  KEEP_SNAPSHOT="${KEEP_SNAPSHOT:-$(awk -F'"' '/^KEEP_SNAPSHOT=/ {print $2}' "$CONFIG_FILE")}"
  KEEP_SNAPSHOT="${KEEP_SNAPSHOT:-3}"
  # Rotation keeps this many Update_* snapshots, including the one taken for
  # the current run. Zero ("head -n -0" prints everything) would delete that
  # protection before the update even starts.
  [[ "$KEEP_SNAPSHOT" =~ ^[0-9]{1,6}$ ]] || KEEP_SNAPSHOT=3
  KEEP_SNAPSHOT=$((10#$KEEP_SNAPSHOT))
  ((KEEP_SNAPSHOT >= 1)) || KEEP_SNAPSHOT=1
  BACKUP=$(awk -F'"' '/^BACKUP=/ {print $2}' "$CONFIG_FILE")
  BACKUP_LXC_MP=$(awk -F'"' '/^BACKUP_LXC_MP=/ {print $2}' "$CONFIG_FILE")
  BACKUP_MODE=$(awk -F'"' '/^BACKUP_MODE=/ {print $2}' "$CONFIG_FILE")
  BACKUP_STORAGE=$(awk -F'"' '/^BACKUP_STORAGE=/ {print $2}' "$CONFIG_FILE")
  BACKUP_LXC_MP="${BACKUP_LXC_MP:-true}"
  BACKUP_MODE="${BACKUP_MODE:-stop}"
  BACKUP_STORAGE="${BACKUP_STORAGE-}"
  LXC_START_DELAY=$(awk -F'"' '/^LXC_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  LXC_START_DELAY="${LXC_START_DELAY:-5}"
  EXTRA_GLOBAL=$(awk -F'"' '/^EXTRA_GLOBAL=/ {print $2}' "$CONFIG_FILE")
  EXTRA_IN_HEADLESS=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' "$CONFIG_FILE")
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' "$CONFIG_FILE")
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_PHASED_UPDATES=$(awk -F'"' '/^INCLUDE_PHASED_UPDATES=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_FSTRIM=$(awk -F'"' '/^INCLUDE_FSTRIM=/ {print $2}' "$CONFIG_FILE")
  FSTRIM_WITH_MOUNTPOINT=$(awk -F'"' '/^FSTRIM_WITH_MOUNTPOINT=/ {print $2}' "$CONFIG_FILE")
  PACMAN_ENVIRONMENT=$(awk -F'"' '/^PACMAN_ENVIRONMENT=/ {print $2}' "$CONFIG_FILE")
  if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
    export UU_FILTER_SCOPE=update
    apply_only_exclude_tags ONLY EXCLUDED
  fi
  EMAIL_USER=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' "$CONFIG_FILE")
  EMAIL_USER="${EMAIL_USER:-root}"
  EMAIL_ONLY_ERROR=$(awk -F'"' '/^EMAIL_ONLY_ERROR=/ {print $2}' "$CONFIG_FILE")
  EMAIL_SENDER=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2; exit}' "$CONFIG_FILE")
  EMAIL_ONLY_ERROR="${EMAIL_ONLY_ERROR:-false}"
  EMAIL_SENDER="${EMAIL_SENDER:-\$USER}"
  if declare -f STATUS_MODEL_EXPAND_SENDER >/dev/null 2>&1; then
    EMAIL_SENDER=$(STATUS_MODEL_EXPAND_SENDER "$EMAIL_SENDER")
  fi
}

GET_BACKUP_STORAGE () {
  local configured_storage storage_status backup_storage

  configured_storage="$BACKUP_STORAGE"
  if [[ -n "$configured_storage" ]]; then
    storage_status=$(pvesm status -content backup 2>/dev/null |
      awk -v storage="$configured_storage" '$1 == storage {print $3; exit}')
    if [[ -z "$storage_status" ]]; then
      echo -e "❌${RD:-} Configured backup storage '$configured_storage' does not exist or does not support backups${CL:-}" >&2
      return 1
    elif [[ "$storage_status" != active ]]; then
      echo -e "❌${RD:-} Configured backup storage '$configured_storage' is not active${CL:-}" >&2
      return 1
    fi
    printf '%s\n' "$configured_storage"
    return 0
  fi

  backup_storage=$(pvesm status -content backup 2>/dev/null |
    awk 'NR > 1 && $3 == "active" {print $1; exit}')
  if [[ -z "$backup_storage" ]]; then
    echo -e "❌${RD:-} No active backup storage is available${CL:-}" >&2
    return 1
  fi
  printf '%s\n' "$backup_storage"
}

# Snapshot/Backup
CAPTURE_POST_UPDATE_STATUS() {
  local target="$1" kind="$2" refresh_rc=0 artifact_dir
  [[ "${UU_POST_UPDATE_STATUS_CAPTURE:-false}" == true ]] || return 0
  artifact_dir="${UU_REMOTE_WORK_DIR:-$TEMP_STATE_DIR}"
  if ! mkdir -p -- "$artifact_dir" "$TEMP_STATE_DIR"; then
    printf '%s\n' "$refresh_rc" > "$TEMP_STATE_DIR/post-update-status.rc"
    return 0
  fi
  if [[ -x "$CHECK_SCRIPT" && -f "$LOCAL_FILES/status-model.sh" ]]; then
    # A post-update capture observes one target while the global status model
    # remains authoritative for the whole inventory.  Keep the existing
    # records and merge this fresh target observation into them.
    STATUS_MODEL_SCRIPT="$LOCAL_FILES/status-model.sh" \
    STATUS_MODEL_FILE="$LOCAL_FILES/status.json" \
    STATUS_MODEL_RECORD_FILE="$TEMP_STATE_DIR/post-update-status.records" \
    STATUS_MODEL_DIAGNOSTICS_FILE="$artifact_dir/post-update-status.diagnostics" \
    STATUS_MODEL_PARTIAL=true UU_REMOTE_DEFER_STATUS_FINISH=false TAG_OUTPUT=false \
    UU_DEFER_NOTIFICATION=true UU_EXPLICIT_TARGET_CHECK=true \
    "$CHECK_SCRIPT" "$kind" "$target" </dev/null || refresh_rc=$?
    if [[ "$refresh_rc" -eq 0 ]]; then
      if declare -F STATUS_MODEL_VALIDATE_TARGET_FILE >/dev/null 2>&1; then
        STATUS_MODEL_VALIDATE_TARGET_FILE "$LOCAL_FILES/status.json" "$target" || refresh_rc=$?
      else
        refresh_rc=87
        printf 'POST_UPDATE_CAPTURE_STATUS_VALIDATOR_UNAVAILABLE\n' >&2
      fi
    fi
  elif [[ ! -x "$CHECK_SCRIPT" ]]; then
    refresh_rc=127
    printf 'POST_UPDATE_CAPTURE_HELPER_NOT_EXECUTABLE: %s\n' "$CHECK_SCRIPT" >&2
  else
    refresh_rc=87
    printf 'POST_UPDATE_CAPTURE_STATUS_HELPER_MISSING: %s/status-model.sh\n' "$LOCAL_FILES" >&2
  fi
  printf '%s\n' "$refresh_rc" > "$artifact_dir/post-update-status.rc"
  return 0
}

# Delete this updater's Update_<date>_<time> snapshots beyond KEEP_SNAPSHOT,
# oldest first. Snapshots created by users ("UpdateTest", "pre-Update", ...)
# never match.
ROTATE_UPDATE_SNAPSHOTS () {
  local tool="$1" guest="$2" snapshot
  local -a old_snapshots=()
  mapfile -t old_snapshots < <("$tool" listsnapshot "$guest" 2>/dev/null |
    awk '$2 ~ /^Update_[0-9]+_[0-9]+$/ {print $2}' | sort | head -n -"$KEEP_SNAPSHOT")
  for snapshot in "${old_snapshots[@]}"; do
    RUN_PROXMOX_COMMAND "$tool" delsnapshot "$guest" "$snapshot" ||
      echo -e "${OR:-}⚠ Could not delete old snapshot $snapshot of $guest${CL:-}"
  done
}

CONTAINER_BACKUP () {
  local snapshot_requested="$SNAPSHOT" snapshot_output
  local backup_requested="$BACKUP"

  if [[ "$snapshot_requested" == true || "$backup_requested" == true ]]; then
    if [[ "$snapshot_requested" == true ]]; then
      if RUN_PROXMOX_CAPTURE pct snapshot "$CONTAINER" "Update_$(date '+%Y%m%d_%H%M%S')"; then
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        echo -e "✅${GN:-} Snapshot created${CL:-}"
        echo -e "ℹ ${GN:-} Delete old snapshots${CL:-}"
        ROTATE_UPDATE_SNAPSHOTS pct "$CONTAINER"
      echo -e "✅${GN:-} Done${CL:-}"
      else
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        if grep -Eqi 'snapshot feature is not available|snapshot[^[:alnum:]]*(feature )?(is )?(not available|unsupported|not supported)|not supported[^[:alnum:]]*snapshot' <<< "$snapshot_output"; then
          echo -e "⚠️${OR:-} Snapshot not supported for LXC $CONTAINER; continuing without snapshot${CL:-}"
          snapshot_requested=false
        elif [[ "$backup_requested" == true ]]; then
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Attempting configured backup fallback${CL:-}"
        elif [[ "$BACKUP_LXC_MP" == true ]] && pct config "$CONTAINER" | grep -q '^mp'; then
          backup_requested=true
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Changed to backup, because of mount points${CL:-}"
        else
          echo -e "❌${RD:-} Snapshot creation failed for LXC $CONTAINER${CL:-}"
          echo -e "❌${RD:-} Guest update aborted: configured snapshot protection was not created${CL:-}"
          return 1
        fi
      fi
    fi
    if [[ "$backup_requested" == true ]]; then
      # Use BACKUP_MODE from config, default to 'stop' if not set
      MODE=${BACKUP_MODE:-stop}
      if ! STORAGE=$(GET_BACKUP_STORAGE); then
        echo -e "❌${RD:-} Backup of LXC $CONTAINER failed - no usable backup storage${CL:-}\n"
        return 1
      fi
      echo -e "💾${OR:-} Create a backup for LXC (this will take some time - please wait)${CL:-}"
      if RUN_PROXMOX_COMMAND vzdump "$CONTAINER" --mode "$MODE" --notes-template "{{guestname}} - Ultimate-Updater" --storage "$STORAGE" --compress zstd; then
        echo -e "✅${GN:-} Backup created${CL:-}\n"
      else
        echo -e "❌${RD:-} Backup of LXC $CONTAINER failed - skipping update${CL:-}\n"
        return 1
      fi
    fi
  else
    echo -e "⏩${OR:-} Snapshot and Backup skipped by the user${CL:-}"
  fi
}
VM_BACKUP () {
  local snapshot_requested="$SNAPSHOT" snapshot_output
  local backup_requested="$BACKUP"

  if [[ "$snapshot_requested" == true || "$backup_requested" == true ]]; then
    if [[ "$snapshot_requested" == true ]]; then
      if RUN_PROXMOX_CAPTURE qm snapshot "$VM" "Update_$(date '+%Y%m%d_%H%M%S')"; then
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        echo -e "✅${GN:-} Snapshot created${CL:-}"
        echo -e "ℹ ${GN:-} Delete old snapshot(s)${CL:-}"
        ROTATE_UPDATE_SNAPSHOTS qm "$VM"
      echo -e "✅${GN:-} Done${CL:-}"
      else
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        if grep -Eqi 'snapshot feature is not available|snapshot[^[:alnum:]]*(feature )?(is )?(not available|unsupported|not supported)|not supported[^[:alnum:]]*snapshot' <<< "$snapshot_output"; then
          echo -e "⚠️${OR:-} Snapshot not supported for VM $VM; continuing without snapshot${CL:-}"
          snapshot_requested=false
        elif [[ "$backup_requested" == true ]]; then
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Attempting configured backup fallback${CL:-}"
        else
          echo -e "❌${RD:-} Snapshot creation failed for VM $VM${CL:-}"
          echo -e "❌${RD:-} Guest update aborted: configured snapshot protection was not created${CL:-}"
          return 1
        fi
      fi
    fi
    if [[ "$backup_requested" == true ]]; then
      # Use BACKUP_MODE from config, default to 'stop' if not set
      MODE=${BACKUP_MODE:-stop}
      if ! STORAGE=$(GET_BACKUP_STORAGE); then
        echo -e "❌${RD:-} Backup of VM $VM failed - no usable backup storage${CL:-}"
        return 1
      fi
      echo -e "💾${OR:-} Create a backup for the VM (this will take some time - please wait)${CL:-}"
      if RUN_PROXMOX_COMMAND vzdump "$VM" --mode "$MODE" --storage "$STORAGE" --compress zstd; then
        echo -e "✅${GN:-} Backup created${CL:-}"
      else
        echo -e "❌${RD:-} Backup of VM $VM failed - skipping update${CL:-}"
        return 1
      fi
    fi
  else
    echo -e "⏩${OR:-} Snapshot and/or Backup skipped by the user${CL:-}"
  fi
}

# Guest file transport for extras and user scripts. Files go to a private
# temporary directory in the guest. They used to go to $LOCAL_FILES, and the
# cleanup `rm -rf $LOCAL_FILES` wiped an Ultimate Updater installed in the
# guest (for example a nested Proxmox VE); SSH guests also needed root.
# The transport is lxc ($CONTAINER), ssh ($USER@$IP, $SSH_VM_PORT) or qga ($VM).
GUEST_WORK_DIR_RE='^/tmp/ultimate-updater\.[A-Za-z0-9]+$'

GUEST_WORKDIR () {  # GUEST_WORKDIR <transport>: create and print a work directory
  local directory=""
  case "$1" in
    lxc) directory=$(pct exec "$CONTAINER" -- mktemp -d /tmp/ultimate-updater.XXXXXX) || return 1 ;;
    ssh) directory=$(ssh -q -p "$SSH_VM_PORT" "$USER@$IP" 'mktemp -d /tmp/ultimate-updater.XXXXXX' </dev/null) || return 1 ;;
    qga)
      RUN_QEMU_COMMAND "$VM" -- mktemp -d /tmp/ultimate-updater.XXXXXX >/dev/null || return 1
      directory=$QEMU_EXEC_STDOUT
      ;;
    *) return 1 ;;
  esac
  directory=${directory//[$'\r\n']/}
  [[ "$directory" =~ $GUEST_WORK_DIR_RE ]] || return 1
  printf '%s\n' "$directory"
}

# shellcheck disable=SC2016 # the sh -c scripts expand $1/$2 in the guest
GUEST_COPY () {  # GUEST_COPY <transport> <local file> <guest file>
  local host="$IP" data
  case "$1" in
    lxc) pct push "$CONTAINER" "$2" "$3" ;;
    ssh)
      [[ "$host" == *:* ]] && host="[$host]"
      # scp takes the port as -P and needs the user; both were missing.
      scp -q -P "$SSH_VM_PORT" "$2" "$USER@$host:$3"
      ;;
    qga)
      data=$(base64 -w0 "$2") || return 1
      RUN_QEMU_COMMAND "$VM" -- sh -c 'printf "%s" "$1" | base64 -d > "$2"' sh "$data" "$3" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC2016 # the sh -c scripts expand $1/$2 in the guest
GUEST_EXEC () {  # GUEST_EXEC <transport> <work dir> <script>: run with LOCAL_FILES=<work dir>
  local quoted_dir quoted_script
  case "$1" in
    # Paths are passed as arguments, never re-parsed inside a command string.
    lxc) pct exec "$CONTAINER" -- env LOCAL_FILES="$2" sh -c 'chmod +x "$1" && exec "$1"' sh "$3" ;;
    ssh)
      printf -v quoted_dir '%q' "$2"
      printf -v quoted_script '%q' "$3"
      ssh -q -p "$SSH_VM_PORT" -tt "$USER@$IP" "chmod +x $quoted_script && LOCAL_FILES=$quoted_dir $quoted_script"
      ;;
    qga)
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- \
        env LOCAL_FILES="$2" sh -c 'chmod +x "$1" && exec "$1"' sh "$3"
      ;;
    *) return 1 ;;
  esac
}

GUEST_REMOVE () {  # GUEST_REMOVE <transport> <work dir>
  [[ "$2" =~ $GUEST_WORK_DIR_RE ]] || return 1
  case "$1" in
    lxc) pct exec "$CONTAINER" -- rm -rf -- "$2" ;;
    ssh) ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "rm -rf -- $2" </dev/null ;;
    qga) RUN_QEMU_COMMAND "$VM" -- rm -rf -- "$2" >/dev/null ;;
    *) return 1 ;;
  esac
}

# The user scripts of a guest: regular files in $USER_SCRIPTS/<id>, sorted,
# without hidden files such as the .script-only marker.
SCRIPT_ONLY_FILES () {
  SCRIPT_FILES=()
  while IFS= read -r -d '' SCRIPT_FILE; do
    SCRIPT_FILES+=("$SCRIPT_FILE")
  done < <(find "$1" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null | sort -z)
}

# RUN_USER_SCRIPTS <transport> <guest id> <label>: copy and run every user
# script; stops at the first failure and describes it in USER_SCRIPT_ERROR.
RUN_USER_SCRIPTS () {
  local transport="$1" id="$2" label="$3" work script_file script status=0
  USER_SCRIPT_ERROR=""
  SCRIPT_ONLY_FILES "$USER_SCRIPTS/$id"
  [[ ${#SCRIPT_FILES[@]} -gt 0 ]] || return 0
  if ! work=$(GUEST_WORKDIR "$transport"); then
    USER_SCRIPT_ERROR="Could not prepare a user-script directory in $label"
    return 1
  fi
  for script_file in "${SCRIPT_FILES[@]}"; do
    script="$work/${script_file##*/}"
    if ! GUEST_COPY "$transport" "$script_file" "$script"; then
      status=1
      USER_SCRIPT_ERROR="Could not transfer user script ${script_file##*/} to $label"
      break
    fi
    GUEST_EXEC "$transport" "$work" "$script"
    status=$?
    if [[ $status -ne 0 ]]; then
      USER_SCRIPT_ERROR="User script ${script_file##*/} in $label failed (exit code $status)"
      break
    fi
  done
  GUEST_REMOVE "$transport" "$work" || true
  return "$status"
}

# User scripts after a regular update (and its extras).
USER_SCRIPTS_RUN () {  # USER_SCRIPTS_RUN <transport> <guest id> <label>
  [[ -d "$USER_SCRIPTS/$2" ]] || return 0
  echo -e "\n*** Run user scripts now ***\n"
  if ! RUN_USER_SCRIPTS "$@"; then
    ERROR_CODE=1
    ID=$2
    ERROR_MSG=$USER_SCRIPT_ERROR
    ERROR
  fi
  echo -e "\n*** User scripts finished ***\n"
}

# Script-only mode is enabled by placing a .script-only marker next to the
# guest's user scripts. The hidden marker is ignored by the normal script path.
SCRIPT_ONLY_ENABLED () {
  [[ -f "$USER_SCRIPTS/$1/.script-only" ]]
}

SCRIPT_ONLY_RUN () {  # SCRIPT_ONLY_RUN <transport> <guest id> <label> <transport label>
  local status
  SCRIPT_ONLY_FILES "$USER_SCRIPTS/$2"
  if [[ ${#SCRIPT_FILES[@]} -eq 0 ]]; then
    echo -e "⚠ ${OR:-}Script-only mode enabled for $3, but no user scripts were found.${CL:-}"
    SCRIPT_ONLY_ERROR="No user scripts found for $3"
    return 2
  fi
  echo -e "\n${OR:-}Script-only mode enabled for $3$4${CL:-}"
  echo -e "${OR:-}Skipping built-in OS update; running user scripts${CL:-}\n"
  RUN_USER_SCRIPTS "$1" "$2" "$3"
  status=$?
  if [[ $status -ne 0 ]]; then
    SCRIPT_ONLY_ERROR=$USER_SCRIPT_ERROR
    return "$status"
  fi
  echo -e "\n${GN:-}Script-only user scripts finished${CL:-}\n"
}
SCRIPT_ONLY_LXC () { SCRIPT_ONLY_RUN lxc "$CONTAINER" "LXC $CONTAINER" ""; }
SCRIPT_ONLY_SSH_VM () { SCRIPT_ONLY_RUN ssh "$VM" "VM $VM" " via SSH"; }
SCRIPT_ONLY_QEMU_VM () { SCRIPT_ONLY_RUN qga "$VM" "VM $VM" " via QEMU Guest Agent"; }
SCRIPT_ONLY_VM () {
  SCRIPT_ONLY_FILES "$USER_SCRIPTS/$VM"
  if [[ ${#SCRIPT_FILES[@]} -eq 0 ]]; then
    echo -e "⚠ ${OR:-}Script-only mode enabled for VM $VM, but no user scripts were found.${CL:-}"
    SCRIPT_ONLY_ERROR="No user scripts found for VM $VM"
    return 2
  fi
  if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER=$(awk -F'"' '/^USER=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER="${USER:-root}"
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    SSH_VM_PORT="${SSH_VM_PORT:-22}"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -q -p "$SSH_VM_PORT" "$USER@$IP" exit </dev/null >/dev/null 2>&1; then
      SCRIPT_ONLY_SSH_VM
      return
    fi
  fi
  QGA_ERROR=""
  if WAIT_FOR_QGA && CHECK_QGA_EXEC; then
    SCRIPT_ONLY_QEMU_VM
    return
  fi
  SCRIPT_ONLY_ERROR="${QGA_ERROR:-Neither SSH nor QEMU Guest Agent is available for VM $VM}"
  echo -e "⚠ ${OR:-}Script-only mode enabled for VM $VM, but the QEMU path is unavailable: ${SCRIPT_ONLY_ERROR}${CL:-}"
  return 1
}

# Extras
EXTRAS () {
  if [[ "$EXTRA_GLOBAL" != true ]]; then
    echo -e "\n${OR:-}--- Skip Extra Updates because of the user settings ---${CL:-}\n"
  elif [[ "$HEADLESS" == true && "$EXTRA_IN_HEADLESS" == false ]]; then
    echo -e "\n${OR:-}--- Skip Extra Updates because of Headless Mode or user settings ---${CL:-}\n"
  else
    echo -e "\n${OR:-}--- Searching for extra updates ---${CL:-}"
    local transport=lxc guest_id="$CONTAINER" label="LXC $CONTAINER" work
    if [[ "$SSH_CONNECTION" == true ]]; then
      transport=ssh guest_id="$VM" label="VM $VM"
    fi
    if [[ "$transport" == ssh && "$USER" != root ]]; then
      echo -e "${RD:-}--- Extra updates need the root user ---${CL:-}"
    elif ! work=$(GUEST_WORKDIR "$transport"); then
      ERROR_CODE=1
      ID=$guest_id
      ERROR_MSG="Could not prepare a directory for extra updates in $label"
      ERROR
    else
      if GUEST_COPY "$transport" "$LOCAL_FILES/update-extras.sh" "$work/update-extras.sh" &&
        GUEST_COPY "$transport" "$LOCAL_FILES/update.conf" "$work/update.conf"; then
        GUEST_EXEC "$transport" "$work" "$work/update-extras.sh" || true
      else
        ERROR_CODE=1
        ID=$guest_id
        ERROR_MSG="Could not copy extra updates to $label"
        ERROR
      fi
      GUEST_REMOVE "$transport" "$work" || true
    fi
    USER_SCRIPTS_RUN "$transport" "$guest_id" "$label"
    echo -e "${GN:-}---   Finished extra updates    ---${CL:-}"
    if [[ $WILL_STOP != true && $WELCOME_SCREEN != true ]]; then
      echo
    elif [[ "$WELCOME_SCREEN" == true ]]; then
      echo
    fi
  fi
}

# Trim Filesystem
TRIM_FILESYSTEM() {
  if [[ "$INCLUDE_FSTRIM" == true ]]; then
    local ROOT_FS ignore_mountpoints=1
    ROOT_FS=$(df -Th "/" | awk 'NR==2 {print $2}')
    # FSTRIM_WITH_MOUNTPOINT=true includes mount points ("Include mount
    # points in fstrim"); it used to be passed as --ignore-mountpoints.
    [[ "${FSTRIM_WITH_MOUNTPOINT:-true}" == true ]] && ignore_mountpoints=0
    local LVS
    # Only this container's disks: /vm-101/ also matched vm-1010-disk-0.
    mapfile -t LVS < <(lvs | awk -F '[[:space:]]+' -v id="$CONTAINER" 'NR>1 && $2 ~ ("^vm-" id "-disk-") {gsub(/%/, "", $7); print $7}')
    if [[ ${#LVS[@]} -gt 0 ]] && [[ "$ROOT_FS" == "ext4" ]]; then
      echo -e "${OR:-}--- Trimming filesystem ---${CL:-}"
      echo -e "${RD:-}Data before trim: ${LVS[*]}%${CL:-}"
      pct fstrim "$CONTAINER" --ignore-mountpoints "$ignore_mountpoints"
      local LVS_AFTER
      mapfile -t LVS_AFTER < <(lvs | awk -F '[[:space:]]+' -v id="$CONTAINER" 'NR>1 && $2 ~ ("^vm-" id "-disk-") {gsub(/%/, "", $7); print $7}')
      echo -e "${GN:-}Data after trim: ${LVS_AFTER[*]}%${CL:-}\n"
      sleep 1.5
    fi
  fi
}

# Dist Upgrade
DIST_UPGRADE () {
  # The upgrade stops on the first error; `local -` restores the shell
  # options on return instead of leaving set -e on for the rest of the run.
  local -
  # debian 12 -> 13
  DEB_VERSION=$(pct exec "$CONTAINER" -- bash -c "grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '\"'")
  if [[ "$DEB_VERSION" == "12" ]]; then
    echo -e "${OR:-}✅ Debian 12 detected, want to upgrade to Debian 13?${CL:-}"
    read -p "Type [Y/y] for yes - anything else will skip: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      SNAPSHOT=
      BACKUP=true
      echo
      if ! CONTAINER_BACKUP; then
        SAFETY_FAILURE=true
        ERROR_CODE=1
        ID=$CONTAINER
        ERROR_MSG="Configured snapshot/backup protection failed; distribution upgrade aborted"
        ERROR
        return 1
      fi
      echo -e "${GR:-}⏩ Upgrade to Debian 13 (Trixie) now:${CL:-}"
      echo -e "${OR:-}--- Enable stop on error ---\n${CL:-}"
      set -e
      echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "apt-get update -y"
      echo -e "${OR:-}--- APT UPGRADE ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING dist-upgrade -y"
      echo -e "${OR:-}--- Cleaning ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y && apt-get autoclean -y"
      echo -e "\n${OR:-}--- Need 5Gig on root folder for upgrade - check it now ---${CL:-}"
      # Validate guest output before arithmetic: [[ -gt ]] would evaluate
      # array subscripts such as 'x[$(cmd)]' as root on the host.
      local available_gb
      available_gb=$(pct exec "$CONTAINER" -- sh -c "df --output=avail -BG / | tail -n 1" 2>/dev/null || true)
      available_gb=${available_gb//[[:space:]]/}
      available_gb=${available_gb%G}
      if [[ "$available_gb" =~ ^[0-9]{1,9}$ ]] && (( 10#$available_gb > 5 )); then
        echo -e "✅ OK\n"
        echo -e "${OR:-}⚠  This is the last step! !!! After all, check your repos !!!${CL:-}"
        echo -e "'sudo apt modernize-sources' could help you here."
        echo -e "Read and understand?"
        read -p "Type [Y/y] for yes - anything else will skip: " -r
        if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
          echo -e "${OR:-}--- Change Repo to Trixie ---\n${CL:-}"
          # deb822-only guests have no sources.list.
          pct exec "$CONTAINER" -- sh -c "[ ! -f /etc/apt/sources.list ] || sed -i 's/bookworm/trixie/g' /etc/apt/sources.list"
          pct exec "$CONTAINER" -- bash -c "find /etc/apt/sources.list.d -type f -exec sed -i 's/bookworm/trixie/g' {} \;"
          echo -e "${OR:-}--- APT UPDATE for Trixie ---${CL:-}"
          pct exec "$CONTAINER" -- bash -c "apt-get update -y"
          echo -e "${OR:-}--- APT UPGRADE for Trixie ---${CL:-}"
          pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING dist-upgrade -y"
          echo -e "\n${GR:-}✅ UPGRADE to Trixie done ${CL:-}"
          echo -e "\n${OR:-}--- Restart the container now for you ---${CL:-}"
          pct exec "$CONTAINER" -- bash -c "reboot"
          echo
          return 0
        else
          echo -e "❌${BL:-} skipped\n${CL:-}"
          return 0
        fi
      else
        echo -e "❌${RD:-} need more space, pls clean up or resize disk, by yourself\n${CL:-}"
        ERROR_CODE=1
        ID=$CONTAINER
        ERROR_MSG="Less than 5 GB free on / - distribution upgrade not started"
        ERROR
        return 1
      fi
    else
      echo -e "❌${BL:-} skipped\n${CL:-}"
      return 0
    fi
  else
    echo -e "❌${BL:-} no Debian 12 detected\n${CL:-}"
    return 0
  fi
}

# Check Updates for Welcome-Screen
UPDATE_CHECK () {
  if [[ "$WELCOME_SCREEN" == true ]]; then
    local status_target=""
    echo -e "${OR:-}--- Check Status for Welcome-Screen ---${CL:-}"
    if [[ "$CHOST" == true ]]; then
      STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u chost | tee -a "$LOCAL_FILES/check-output"
      status_target="host:$HOSTNAME"
    elif [[ "$CCONTAINER" == true ]]; then
      # Pass the ID: the check runs in a new process that does not know it.
      STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u ccontainer "$CONTAINER" | tee -a "$LOCAL_FILES/check-output"
      status_target="$CONTAINER"
    elif [[ "$CVM" == true ]]; then
      STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u cvm "$VM" | tee -a "$LOCAL_FILES/check-output"
      status_target="$VM"
    fi
    if [[ -n "$status_target" ]] && declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      STATUS_MODEL_UPDATE_RESULT "$status_target" success 0 || true
    fi
    echo -e "${GN:-}---          Finished check         ---${CL:-}\n"
    # Not `[[ ]] && echo`: that returns 1 for a started guest, and with
    # EXIT_ON_ERROR=true (set -e) the run ended before the guest was stopped.
    if [[ "$WILL_STOP" != true ]]; then echo; fi
  else
    echo
  fi
}

# Wait for bootup / reboot
# Container
WAIT_FOR_BOOTUP_LXC () {
  MAX_RETRIES=10
  COUNT=1
  BOOT_SHELL=bash
  [[ "$(pct config "$CONTAINER" | awk '/^ostype/ {print $2}')" == alpine ]] && BOOT_SHELL=ash
  sleep "$LXC_START_DELAY"
  while [ $COUNT -le $MAX_RETRIES ]; do
    if pct exec "$CONTAINER" -- "$BOOT_SHELL" -c "exit" >/dev/null 2>&1; then
      echo -e "✅${GN:-} $CONTAINER reachable (tryout $COUNT)\n${CL:-}"
      break
    else
      echo -e "ℹ  Tryout $COUNT/$MAX_RETRIES failed"
      sleep "$LXC_START_DELAY"
    fi
    COUNT=$((COUNT+1))
  done
  if [ $COUNT -gt $MAX_RETRIES ]; then
    echo -e "❌${RD:-} Connection to $CONTAINER after $MAX_RETRIES failed.${CL:-}\n"
    return 1
  fi
}
# VM-SSH
WAIT_FOR_BOOTUP_SSH () {
  MAX_RETRIES=10
  COUNT=1
  sleep "$SSH_START_DELAY_TIME"
  while [ $COUNT -le $MAX_RETRIES ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -q -p "$SSH_VM_PORT" "$USER@$IP" exit </dev/null >/dev/null 2>&1; then
      echo -e "✅${GN:-} $VM reachable (tryout $COUNT)\n${CL:-}"
      break
    else
      echo -e "ℹ  Tryout $COUNT/$MAX_RETRIES failed"
      sleep "$SSH_START_DELAY_TIME"
    fi
    COUNT=$((COUNT+1))
  done
  if [ $COUNT -gt $MAX_RETRIES ]; then
    echo -e "❌${RD:-} Connection to $VM after $MAX_RETRIES failed.${CL:-}\n"
    return 1
  fi
}

# QEMU Guest Agent readiness
WAIT_FOR_QGA () {
  local QGA_MAX_WAIT=180
  local QGA_INTERVAL=2
  local QGA_DEADLINE=$((SECONDS + QGA_MAX_WAIT))

  if [[ "$START_WAITING" == true ]]; then
    echo -e "⏳${OR:-} Wait for QEMU Guest Agent on VM $VM (up to ${QGA_MAX_WAIT}s)${CL:-}\n"
  fi
  while (( SECONDS < QGA_DEADLINE )); do
    if qm agent "$VM" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep "$QGA_INTERVAL"
  done
  QGA_ERROR="Timed out waiting for QEMU Guest Agent on VM $VM."
  return 1
}

QGA_EXEC_SCRIPT="${UU_QGA_EXEC_SCRIPT:-$LOCAL_FILES/qga-guest-exec.sh}"
[[ -f "$QGA_EXEC_SCRIPT" ]] || QGA_EXEC_SCRIPT="$(dirname -- "${BASH_SOURCE[0]}")/qga-guest-exec.sh"
if [[ -f "$QGA_EXEC_SCRIPT" ]]; then
  # shellcheck source=/dev/null
  source "$QGA_EXEC_SCRIPT"
else
  QEMU_GUEST_EXEC() {
    QEMU_EXEC_STDOUT=""
    QEMU_EXEC_STDERR=""
    QEMU_EXEC_OUTPUT="QGA guest-exec helper is missing"
    QEMU_EXEC_EXITCODE=""
    QEMU_EXEC_TRANSPORT_RC=1
  }
fi

# A guest process keeps running when the wait for it ends (timeout) or its
# status can no longer be read. Remember that, so a VM that was started for
# the update is not shut down in the middle of a package transaction.
QGA_NOTE_UNFINISHED_JOB () {
  case "$QEMU_EXEC_ERROR_CLASS" in
    QGA_TIMEOUT|QGA_GUEST_EXEC_STATUS) QGA_JOB_MAY_BE_RUNNING=true ;;
  esac
  return 0
}

# Run a QEMU command once, display its output, and return the guest exit code.
# A non-zero transport status is returned unchanged.
RUN_QEMU_COMMAND () {
  QEMU_GUEST_EXEC "$@"
  QGA_NOTE_UNFINISHED_JOB
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    [[ -n "$QEMU_EXEC_OUTPUT" ]] && printf '%s\n' "$QEMU_EXEC_OUTPUT"
    return "$QEMU_EXEC_TRANSPORT_RC"
  fi
  printf '%s' "$QEMU_EXEC_STDOUT"
  if [[ -n "$QEMU_EXEC_STDERR" ]]; then
    [[ -n "$QEMU_EXEC_STDOUT" && "${QEMU_EXEC_STDOUT: -1}" != $'\n' ]] && printf '\n'
    printf '%s' "$QEMU_EXEC_STDERR"
  fi
  return "$QEMU_EXEC_EXITCODE"
}

RUN_QEMU_DURABLE () {
  QEMU_GUEST_EXEC_DURABLE "$@"
  QGA_NOTE_UNFINISHED_JOB
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    [[ -n "$QEMU_EXEC_OUTPUT" ]] && printf '%s\n' "$QEMU_EXEC_OUTPUT"
    return "$QEMU_EXEC_TRANSPORT_RC"
  fi
  printf '%s' "$QEMU_EXEC_STDOUT"
  return "$QEMU_EXEC_EXITCODE"
}

CHECK_QGA_EXEC () {
  QEMU_GUEST_EXEC "$VM" -- true
  if [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 && "$QEMU_EXEC_EXITCODE" -eq 0 ]]; then
    return 0
  fi
  if grep -Eqi 'not allowed|disabled|not permitted|permission denied' <<< "$QEMU_EXEC_OUTPUT"; then
    QGA_ERROR="QEMU Guest Agent is reachable on VM $VM, but guest-exec is disabled or not allowed: $QEMU_EXEC_OUTPUT"
  elif [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 ]]; then
    QGA_ERROR="QEMU Guest Agent command failed on VM $VM (guest exit code $QEMU_EXEC_EXITCODE): $QEMU_EXEC_OUTPUT"
  else
    QGA_ERROR="QEMU Guest Agent guest-exec failed on VM $VM (transport exit code $QEMU_EXEC_TRANSPORT_RC): $QEMU_EXEC_OUTPUT"
  fi
  return 1
}

############################
########## HOST ############
############################

# Host Update Start
HOST_UPDATE_START () {
  # A node's Internal SSH port override applies to that node only; it used
  # to replace the global SSH_PORT for every following node.
  local default_ssh_port="$SSH_PORT" SSH_PORT
  if [[ "$RICM" != true ]]; then true > "$LOCAL_FILES/check-output"; fi
  for HOST in $HOSTS; do
    SSH_PORT="$default_ssh_port"
    if STOP_AFTER_FAILURE; then
      echo -e "⏩${OR:-} Skipped node $HOST: an earlier update failed and continuing after errors is disabled${CL:-}\n"
      continue
    fi
    HOST_NODE=$(awk -v address="$HOST" '/name[[:space:]]*:/ { name=$2 } /ring0_addr[[:space:]]*:/ && $2 == address { print name; found=1; exit } END { if (!found) print address }' /etc/pve/corosync.conf 2>/dev/null)
    INTERNAL_SSH_RESOLVE_NODE "$HOST_NODE" "$HOST" "$SSH_PORT" || { UPDATE_FAILURE=true; continue; }
    [[ "${INTERNAL_SSH_ENABLED:-true}" == true ]] || { UPDATE_FAILURE=true; continue; }
    HOST="${INTERNAL_SSH_HOST:-$HOST}"; SSH_PORT="${INTERNAL_SSH_PORT:-$SSH_PORT}"; INTERNAL_SSH_USE_IDENTITY
    # Check if Host/Node is available
    if ssh -q -p "$SSH_PORT" "$HOST" test >/dev/null 2>&1; [ $? -eq 255 ]; then
      echo -e "⏩ ${OR:-}Skip Host${CL:-} : ${GN:-}$HOST${CL:-} ${OR:-}- can't connect${CL:-}\n"
      UPDATE_FAILURE=true
    else
      if ! UPDATE_HOST "$HOST"; then
        UPDATE_FAILURE=true
      fi
    fi
  done
}

# Is a cluster node address this node? Corosync often uses a dedicated
# network, so `hostname -i` (the management address) is not enough; a
# node mistaken for remote copied the installation onto itself over scp.
UPDATE_HOST_IS_LOCAL () {
  local candidate="$1" address
  [[ "$candidate" == "$HOSTNAME" || "$candidate" == "$(hostname -s 2>/dev/null)" ||
    "$candidate" == "$(hostname -f 2>/dev/null)" ]] && return 0
  [[ -n "${HOST_NODE:-}" && "$HOST_NODE" == "$(hostname -s 2>/dev/null)" ]] && return 0
  for address in $(hostname -I 2>/dev/null) $(hostname -i 2>/dev/null); do
    [[ "$candidate" == "$address" ]] && return 0
  done
  return 1
}

# A VM is updated over SSH when it has a legacy profile in VMs/<id> or an
# enabled Internal SSH override; checks already used both, updates only the
# legacy file.
VM_HAS_SSH_PROFILE () {
  [[ -f "$LOCAL_FILES/VMs/$1" ]] && return 0
  declare -f INTERNAL_SSH_HAS_OVERRIDE >/dev/null 2>&1 && INTERNAL_SSH_HAS_OVERRIDE vm "$1"
}

# Host Update
UPDATE_HOST () {
  HOST=$1
  local local_node=false scp_host="$HOST" file
  UPDATE_HOST_IS_LOCAL "$HOST" && local_node=true
  [[ "$HOST" == *:* ]] && scp_host="[$HOST]"   # IPv6 in scp host:path syntax
  if [[ "$local_node" != true ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" mkdir -p "$LOCAL_FILES/temp"
    ssh -q -p "$SSH_PORT" "$HOST" "if [[ -f $LOCAL_FILES/update.conf ]]; then cp -p $LOCAL_FILES/update.conf $LOCAL_FILES/update.conf.uu-backup; else rm -f $LOCAL_FILES/update.conf.uu-backup; fi"
    # scp takes the port as -P; without it every copy went to port 22.
    scp -P "$SSH_PORT" "$0" "$scp_host:$LOCAL_FILES/update"
    for file in update-extras.sh update.conf update.conf.dist tag-filter.sh target-runtime.sh \
      internal-ssh.sh cluster-target.sh qga-guest-exec.sh; do
      [[ -f "$LOCAL_FILES/$file" ]] || continue
      scp -P "$SSH_PORT" "$LOCAL_FILES/$file" "$scp_host:$LOCAL_FILES/$file"
    done
    if [[ "$WELCOME_SCREEN" == true ]]; then
      scp -P "$SSH_PORT" "$LOCAL_FILES/check-updates.sh" "$scp_host:$LOCAL_FILES/check-updates.sh"
      scp -P "$SSH_PORT" "$LOCAL_FILES/check-output" "$scp_host:$LOCAL_FILES/check-output"
    fi
    if [[ -d "$LOCAL_FILES/VMs" ]]; then
      scp -P "$SSH_PORT" -r "$LOCAL_FILES/VMs/" "$scp_host:$LOCAL_FILES/"
    fi
  fi
  local remote_mode="-c host"
  if [[ "$HEADLESS" == true ]]; then
    remote_mode="-s -c host"
  elif [[ "$WELCOME_SCREEN" == true ]]; then
    remote_mode="-c -w host"
  fi
  # Stage the script on the node instead of streaming it into `bash -s`.
  # A bash reading its script from stdin shares that stream with its
  # children: any ssh to a VM or package prompt consumed the rest of the
  # script, including the final status handling, so failed node updates
  # were reported as successful.
  ssh -q -p "$SSH_PORT" "$HOST" \
    "f=\$(mktemp /tmp/ultimate-updater-run.XXXXXX) || exit 1; cat > \"\$f\" || { rm -f -- \"\$f\"; exit 1; }; bash \"\$f\" $remote_mode </dev/null; rc=\$?; rm -f -- \"\$f\"; exit \"\$rc\"" < "$0"
  REMOTE_UPDATE_STATUS=$?
  if [[ "$local_node" != true ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" "if [[ -f $LOCAL_FILES/update.conf.uu-backup ]]; then mv -f $LOCAL_FILES/update.conf.uu-backup $LOCAL_FILES/update.conf; else rm -f $LOCAL_FILES/update.conf; fi"
  fi
  return "${REMOTE_UPDATE_STATUS:-0}"
}

UPDATE_HOST_ITSELF () {
  NAME=$HOSTNAME
  echo -e "${OR:-}--- PVE UPDATE ---${CL:-}" && pveupdate || true
  if [[ "$HEADLESS" == true ]]; then
    echo -e "\n${OR:-}--- APT UPGRADE HEADLESS ---${CL:-}" && \
    RUN_STEP "$HOSTNAME" env DEBIAN_FRONTEND=noninteractive apt-get "${DPKG_OPTIONS[@]}" dist-upgrade -y
    if [[ $ERROR_CODE != "" ]]; then return; fi
  else
    if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}" && \
      RUN_STEP "$HOSTNAME" apt-get "${DPKG_OPTIONS[@]}" dist-upgrade -y
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}" && \
      RUN_STEP "$HOSTNAME" apt-get "${DPKG_OPTIONS[@]}" -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
      if [[ $ERROR_CODE != "" ]]; then return; fi
    fi
  fi
  echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}" && \
  RUN_STEP "$HOSTNAME" apt-get --purge autoremove -y
  if [[ $ERROR_CODE != "" ]]; then return; fi
  echo
  CHOST="true"
  UPDATE_CHECK
  CHOST=""
}

############################
######## CONTAINER #########
############################

# Container Update Start
# Per-target state must not leak from one guest to the next. Every update
# step returns early while ERROR_CODE is set, so one failed container used to
# turn every later VM update into a silent "apt-get update" only run, and a
# non-root SSH VM left "sudo " behind for the following VMs.
# EXIT_ON_ERROR=true ("Continue after errors: disabled"): once a target has
# failed, the remaining targets are skipped. Package failures are handled
# per target, so `set -e` alone never stopped the run.
STOP_AFTER_FAILURE () {
  [[ "$EXIT_ON_ERROR" != false && ( "$UPDATE_FAILURE" == true || "$SAFETY_FAILURE" == true ) ]]
}

RESET_TARGET_STATE () {
  ERROR_CODE="" ERROR_MSG="" ID="" UPDATE_USER=""
  CCONTAINER="" CVM="" SSH_CONNECTION="" UNIFI=""
  QGA_JOB_MAY_BE_RUNNING=false
}

CONTAINER_UPDATE_START () {
  local pct_list
  # A failed listing used to look like "no containers" and a successful run.
  if ! pct_list=$(pct list); then
    echo -e "❌${RD:-} Could not list the containers of this node${CL:-}\n"
    UPDATE_FAILURE=true
    return 0
  fi
  CONTAINERS=$(awk 'NR > 1 {print $1}' <<< "$pct_list")
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    RESET_TARGET_STATE
    if STOP_AFTER_FAILURE; then
      echo -e "⏩${OR:-} Skipped LXC $CONTAINER: an earlier update failed and continuing after errors is disabled${CL:-}\n"
    elif guest_id_matches "$EXCLUDED" "$CONTAINER"; then
      echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"
    elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$CONTAINER"; then
      if [[ "$SINGLE_UPDATE" != true ]]; then echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"; else continue; fi
    elif pct config "$CONTAINER" 2>/dev/null | grep -q '^template: 1$'; then
      echo -e "⏩ ${OR:-}LXC $CONTAINER is a template - skip update${CL:-}\n\n"
      continue
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" == true ]]; then
        # Start the container
        WILL_STOP="true"
        echo -e " ▶${GN:-} Starting LXC ${BL:-}$CONTAINER ${CL:-}"
        RUN_PROXMOX_COMMAND pct start "$CONTAINER"
        echo -e "⏳${GN:-} Waiting for LXC ${BL:-}$CONTAINER${CL:-}${GN:-} to start ${CL:-}"
#        sleep "$LXC_START_DELAY"
        if WAIT_FOR_BOOTUP_LXC; then
          UPDATE_CONTAINER "$CONTAINER"
          CAPTURE_POST_UPDATE_STATUS "$CONTAINER" ccontainer
        else
          ERROR_CODE=$?
          ID=$CONTAINER
          NAME="LXC $CONTAINER"
          ERROR_MSG="LXC $CONTAINER did not become reachable after the boot wait timeout"
          ERROR
        fi
        # Stop the container
        echo -e "⏹ ${GN:-} Shutting down LXC ${BL:-}$CONTAINER ${CL:-}\n\n"
        RUN_PROXMOX_COMMAND pct shutdown "$CONTAINER" &
        WILL_STOP="false"
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" != true ]]; then
        echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" == true ]]; then
        UPDATE_CONTAINER "$CONTAINER"
        CAPTURE_POST_UPDATE_STATUS "$CONTAINER" ccontainer
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" != true ]]; then
        echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"
      else
        echo -e "⚠ Can't find status, please report this issue${CL:-}\n\n"
        UPDATE_FAILURE=true
      fi
    fi
  done
}

# Container Update
UPDATE_CONTAINER () {
  CONTAINER=$1
  CCONTAINER="true"
  echo 'CONTAINER="'"$CONTAINER"'"' > "$TEMP_STATE_DIR/var"
  OS=$(pct config "$CONTAINER" | awk '/^ostype/' - | cut -d' ' -f2)
  NAME=$(pct exec "$CONTAINER" hostname)
#  if [[ "$OS" =~ centos ]]; then
#    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
#  else
#    NAME=$(pct exec "$CONTAINER" hostname)
#  fi
  if [[ "$CHECK_DIST" != true ]]; then
    echo -e "🔄${GN:-} Updating LXC ${BL:-}$CONTAINER${CL:-} : ${GN:-}$NAME${CL:-}\n"
  else
    echo -e "🔄${GN:-} Check dist upgrade for LXC ${BL:-}$CONTAINER${CL:-} : ${GN:-}$NAME${CL:-}"
  fi
  # Check Internet connection
  local internet_check
  if ! internet_check=$(INTERNET_CHECK_COMMAND) || ! RUN_PCT_COMMAND "$CONTAINER" sh -c "$internet_check"; then
    echo -e "${OR:-} ❌ Internet check fail - skip this container${CL:-}\n"
    UPDATE_FAILURE=true
    return
  fi
  # Backup
  if [[ "$CHECK_DIST" != true ]]; then
    echo -e "💾${OR:-} Start Snapshot and/or Backup${CL:-}"
    if ! CONTAINER_BACKUP; then
      SAFETY_FAILURE=true
      ERROR_CODE=1
      ID=$CONTAINER
      ERROR_MSG="Configured snapshot/backup protection failed; LXC update aborted"
      ERROR
      return 1
    fi
    echo
  fi
  if SCRIPT_ONLY_ENABLED "$CONTAINER"; then
    SCRIPT_ONLY_LXC || {
      ERROR_CODE=$?
      ID=$CONTAINER
      ERROR_MSG="${SCRIPT_ONLY_ERROR:-Script-only user scripts failed or were not found}"
      ERROR
    }
    if [[ -z "${ERROR_CODE:-}" ]] && declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      STATUS_MODEL_UPDATE_RESULT "$CONTAINER" success 0 || true
    fi
    CCONTAINER=""
    return
  fi
  # Run dist-upgrade
  if [[ $CHECK_DIST == true && $OS =~ debian ]]; then
    DIST_UPGRADE
    local dist_result=$?
    if declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      if [[ $dist_result -eq 0 ]]; then
        STATUS_MODEL_UPDATE_RESULT "$CONTAINER" success 0 || true
      else
        STATUS_MODEL_UPDATE_RESULT "$CONTAINER" failed "$dist_result" || true
      fi
    fi
    return "$dist_result"
  elif [[ "$CHECK_DIST" == true ]]; then
    echo -e "${OR:-} ❌ Distribution not supported\n${CL:-}"
    return 0
  fi
  # Run update
  if [[ "${OS,,}" =~ ubuntu|debian|devuan ]]; then
    echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
    # Check APT in Container for Unifi before update
    if pct exec "$CONTAINER" -- bash -c "grep -rnw /etc/apt -e unifi >/dev/null 2>&1"; then
      UNIFI="true"
      # --allow-releaseinfo-change needed because Unifi regularly changes repository metadata between versions
      RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "apt-get update --allow-releaseinfo-change"
    else
      RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "apt-get update"
    fi
    if [[ $ERROR_CODE != "" ]]; then return; fi
    # Check END
    if [[ "$HEADLESS" == true ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE HEADLESS ---${CL:-}"
      RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING dist-upgrade -y"
      UNIFI=""
      if [[ $ERROR_CODE != "" ]]; then return; fi
    elif [[ "$UNIFI" == true ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE HEADLESS (Unifi) ---${CL:-}"
      # Use --force-confdef/--force-confold to suppress Unifi interactive prompts
      RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING dist-upgrade -y"
      UNIFI=""
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING dist-upgrade -y"
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
    fi
      echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
      RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y"
      if [[ $ERROR_CODE != "" ]]; then return; fi
      RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "apt-get autoclean -y"
      if [[ $ERROR_CODE != "" ]]; then return; fi
      EXTRAS
      TRIM_FILESYSTEM
      UPDATE_CHECK
  elif [[ "$OS" =~ fedora ]]; then
    echo -e "\n${OR:-}--- DNF UPGRATE ---${CL:-}"
    RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "dnf -y upgrade"
    if [[ $ERROR_CODE != "" ]]; then return; fi
    echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
    RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "dnf -y autoremove"
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ archlinux ]]; then
    echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
    local pacman_assignments
    local -a pacman_environment=()
    if ! pacman_assignments=$(PACMAN_ENVIRONMENT_ASSIGNMENTS); then
      ERROR_CODE=1
      ID=$CONTAINER
      ERROR_MSG="PACMAN_ENVIRONMENT must be NAME=value assignments separated by spaces"
      ERROR
      return
    fi
    [[ -z "$pacman_assignments" ]] || mapfile -t pacman_environment <<< "$pacman_assignments"
    RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- env "${pacman_environment[@]}" pacman -Syu --noconfirm
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ alpine ]]; then
    echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
    RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- ash -c "apk -U upgrade"
    if [[ $ERROR_CODE != "" ]]; then return; fi
    if [[ "$WILL_STOP" != true ]]; then echo; fi
    echo
  elif [[ "$OS" =~ centos ]]; then
    echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
    RUN_STEP "$CONTAINER" pct exec "$CONTAINER" -- bash -c "yum -y update"
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  else
    echo -e "${OR:-}The system could not be identified.${CL:-}"
    # Not a success: nothing was updated.
    ERROR_CODE=2
    ID=$CONTAINER
    ERROR_MSG="No supported package manager for LXC ostype ${OS:-unknown}"
    ERROR
    return
  fi
  if declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
    STATUS_MODEL_UPDATE_RESULT "$CONTAINER" success 0 || true
  fi
  CCONTAINER=""
}

############################
########### VM #############
############################

# VM Update Start
VM_UPDATE_START () {
  local qm_list
  if ! qm_list=$(qm list); then
    echo -e "❌${RD:-} Could not list the VMs of this node${CL:-}\n"
    UPDATE_FAILURE=true
    return 0
  fi
  VMS=$(awk 'NR > 1 {print $1}' <<< "$qm_list")
  # Loop through the VMs
  for VM in $VMS; do
    RESET_TARGET_STATE
    PRE_OS=$(qm config "$VM" | grep ostype || true)
    if STOP_AFTER_FAILURE; then
      echo -e "⏩${OR:-} Skipped VM $VM: an earlier update failed and continuing after errors is disabled${CL:-}\n"
    elif guest_id_matches "$EXCLUDED" "$VM"; then
      echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"
    elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$VM"; then
      if [[ "$SINGLE_UPDATE" != true ]]; then echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"; else continue; fi
    elif qm config "$VM" 2>/dev/null | grep -q '^template: 1$'; then
      echo -e "⏩${BL:-} ${OR:-}VM $VM is a template - skip update${CL:-}\n\n"
      continue
    elif [[ "$PRE_OS" =~ w ]]; then
      echo -e "⚠ ${BL:-} Skipped VM $VM${CL:-}\n"
      echo -e "${OR:-}  Windows is not supported for now.\n  I'm working on it ;)${CL:-}\n\n"
    else
      STATUS=$(qm status "$VM")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]] && VM_IS_HIBERNATED "$VM"; then
        echo -e "⏩${BL:-} Skipped VM $VM because it is hibernated${CL:-}\n\n"
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]]; then
        # Check if update is possible
        if QGA_CONFIG_ENABLED "$VM" || VM_HAS_SSH_PROFILE "$VM"; then
          # Start the VM
          WILL_STOP="true"
          echo -e " ▶${GN:-} Starting VM${BL:-} $VM ${CL:-}"
          RUN_PROXMOX_COMMAND qm start "$VM"
          START_WAITING="true"
          UPDATE_VM "$VM"
          CAPTURE_POST_UPDATE_STATUS "$VM" cvm
          # Stop the VM, unless a guest-agent job outlived its wait: shutting
          # down now could interrupt a package transaction.
          if [[ "$QGA_JOB_MAY_BE_RUNNING" == true ]]; then
            echo -e "⚠ ${OR:-} VM $VM may still run a package job; it is left running${CL:-}\n\n"
          else
            echo -e "⏹ ${GN:-} Shutting down VM${BL:-} $VM ${CL:-}\n\n"
            RUN_PROXMOX_COMMAND qm shutdown "$VM" &
          fi
          WILL_STOP="false"
          START_WAITING="false"
        else
          echo -e "⏩${BL:-} Skipped VM $VM because, QEMU or SSH hasn't initialized${CL:-}\n\n"
        fi
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" != true ]]; then
        echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
        UPDATE_VM "$VM"
        CAPTURE_POST_UPDATE_STATUS "$VM" cvm
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" != true ]]; then
        echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"
      elif [[ "$STATUS" == "status: paused" ]]; then
        # Updating would need the paused (possibly hibernating) guest resumed.
        echo -e "⏩${BL:-} Skipped VM $VM because it is paused${CL:-}\n\n"
      else
        echo -e "⚠ Can't find status, please report this issue${CL:-}\n\n"
        UPDATE_FAILURE=true
      fi
    fi
  done
}

# VM Update
UPDATE_VM () {
  VM=$1
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  CVM="true"
  echo 'VM="'"$VM"'"' > "$TEMP_STATE_DIR/var"
  echo -e "🔄${GN:-} Updating VM ${BL:-}$VM${CL:-} : ${GN:-}$NAME${CL:-}\n"
  # Backup
  echo -e "💾${OR:-} Start Snapshot and/or Backup${CL:-}"
  if ! VM_BACKUP; then
    SAFETY_FAILURE=true
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Configured snapshot/backup protection failed; VM update aborted"
    ERROR
    return 1
  fi
  echo
  if SCRIPT_ONLY_ENABLED "$VM"; then
    SCRIPT_ONLY_VM || {
      ERROR_CODE=$?
      ID=$VM
      ERROR_MSG="${SCRIPT_ONLY_ERROR:-Script-only user scripts failed or were not found}"
      ERROR
    }
    CVM=""
    return
  fi
  # Read SSH config file - check how update is possible
  if VM_HAS_SSH_PROFILE "$VM"; then
    IP="" USER=root SSH_VM_PORT=22 SSH_START_DELAY_TIME=45
    if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
      IP=$(awk -F'"' '/^IP=/ {print $2; exit}' "$LOCAL_FILES/VMs/$VM")
      USER=$(awk -F'"' '/^USER=/ {print $2; exit}' "$LOCAL_FILES/VMs/$VM")
      USER="${USER:-root}"
      SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2; exit}' "$LOCAL_FILES/VMs/$VM")
      SSH_VM_PORT="${SSH_VM_PORT:-22}"
      SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2; exit}' "$LOCAL_FILES/VMs/$VM")
      SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-45}"
    fi
    # An unreadable internal-ssh.conf used to skip the VM without an error.
    if ! INTERNAL_SSH_RESOLVE_VM "$VM" "${IP:-}" "${USER:-root}" "${SSH_VM_PORT:-22}"; then
      ERROR_CODE=1
      ID=$VM
      ERROR_MSG="Internal SSH configuration is invalid: ${INTERNAL_SSH_ERROR:-unknown error}"
      ERROR
      CVM=""
      return 1
    fi
    # A disabled override means "do not use SSH" (see docs/ssh.md): update
    # through the guest agent instead of skipping the VM.
    if [[ "${INTERNAL_SSH_ENABLED:-true}" != true ]]; then
      UPDATE_VM_QEMU
      return
    fi
    IP="${INTERNAL_SSH_HOST:-$IP}"; USER="${INTERNAL_SSH_USER:-$USER}"; SSH_VM_PORT="${INTERNAL_SSH_PORT:-$SSH_VM_PORT}"; INTERNAL_SSH_USE_IDENTITY
    if [[ -z "$IP" ]]; then
      UPDATE_VM_QEMU
      return
    fi
    if [[ "$START_WAITING" == true ]]; then
      echo -e "⏳${OR:-} Wait for bootup${CL:-}"
      echo -e "ℹ ${OR:-} $SSH_START_DELAY_TIME seconds is set for sleep between tryouts in SSH-VM config file${CL:-}\n"
      if ! WAIT_FOR_BOOTUP_SSH; then
        START_WAITING=false
        UPDATE_VM_QEMU
        return
      fi
    fi
    if ! RUN_SSH_IDENTITY_FILE="${INTERNAL_SSH_IDENTITY_FILE:-}" RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" exit </dev/null >/dev/null 2>&1; then
      echo -e "${RD:-}  ❌ File for ssh connection found, but not correctly set?\n\
  ${BL:-}Please check SSH Key-Based Authentication${CL:-}\n\
  Infos can be found here:<https://github.com/BassT23/Proxmox/blob/${INSTALLED_BRANCH:-master}/ssh.md>
  Try to use QEMU instead\n"
      START_WAITING=false
      UPDATE_VM_QEMU
    else
      # Run SSH Update
      SSH_CONNECTION="true"
      KERNEL=$(qm guest cmd "$VM" get-osinfo 2>/dev/null | grep kernel-version || true)
      # FreeBSD/pfSense reachable only over SSH (no guest agent) and Alpine
      # (no hostnamectl) were never recognized here.
      if [[ "$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" 'uname -s' </dev/null 2>/dev/null)" == FreeBSD ]]; then
        KERNEL=FreeBSD
      fi
      OS=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" 'cat /etc/os-release' </dev/null 2>/dev/null |
        awk -F= '$1 == "PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2; exit}' || true)
      [[ -n "$OS" ]] || OS=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" hostnamectl </dev/null 2>/dev/null | grep System || true)
      # Free-BSD
      if [[ $KERNEL =~ FreeBSD && $FREEBSD_UPDATES == true ]]; then
        echo -e "${OR:-}--- PKG UPDATE ---${CL:-}"
        RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg update
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- PKG UPGRADE ---${CL:-}"
        RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg upgrade -y
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- PKG CLEANING ---${CL:-}"
        RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg autoremove -y
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo
        return
      elif [[ "$KERNEL" =~ FreeBSD ]]; then
        echo -e "${OR:-} Free BSD skipped by user${CL:-}\n"
        return
      # Debian Base
      elif [[ "${OS,,}" =~ debian|ubuntu|mint|kali|neon|devuan ]]; then
        # Check Internet connection
        local internet_check
        if ! internet_check=$(INTERNET_CHECK_COMMAND) || ! ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" "$internet_check" </dev/null; then
          echo -e "${OR:-} ❌ Internet check fail - skip this VM${CL:-}\n"
          UPDATE_FAILURE=true
          return
        fi
        UPDATE_USER=""
        if [[ "$USER" != root ]]; then
          UPDATE_USER="sudo "
        fi
        echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
        RUN_STEP "$VM" ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER"apt-get update -y
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
        if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
          RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" "$UPDATE_USER" apt-get "${DPKG_OPTIONS[@]}" --with-new-pkgs upgrade -y
          if [[ $ERROR_CODE != "" ]]; then return; fi
        else
          RUN_STEP "$VM" ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get "${DPKG_OPTIONS[@]}" -o APT::Get::Always-Include-Phased-Updates=true --with-new-pkgs upgrade -y
          if [[ $ERROR_CODE != "" ]]; then return; fi
        fi
        echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
        RUN_STEP "$VM" ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" "apt-get --purge autoremove -y"
        if [[ $ERROR_CODE != "" ]]; then return; fi
        RUN_STEP "$VM" ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" "apt-get autoclean -y"
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      # Fedora
      elif [[ "$OS" =~ Fedora ]]; then
        echo -e "\n${OR:-}--- DNF UPGRADE ---${CL:-}"
        RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y upgrade
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
        RUN_STEP "$VM" ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y --purge autoremove
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      # Arch
      elif [[ "$OS" =~ Arch ]]; then
        echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
        RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pacman -Syu --noconfirm
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      # Alpine
      elif [[ "$OS" =~ Alpine ]]; then
        echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
        RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" apk -U upgrade
        if [[ $ERROR_CODE != "" ]]; then return; fi
      # Cent OS
      elif [[ "$OS" =~ CentOS ]]; then
        echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
        RUN_STEP "$VM" ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" yum -y update
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      # Windows ( WindowsUpdate need admin rights, ...)
#      elif [[ $OS_BASE == "win10" || $OS_BASE == "win11" ]]; then
#        # check updates
#        ssh -p "$SSH_VM_PORT" "$USER@$IP" "powershell.exe -Command Get-WindowsUpdate"
#        # install updates
#        ssh -p "$SSH_VM_PORT" "$USER@$IP" "powershell.exe -Command Install-WindowsUpdate -AcceptAll -IgnoreReboot"
      else
        echo -e "${RD:-}  ❌ The system is not supported.\n  Maybe with later version ;)\n${CL:-}"
        echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
      fi
      return
    fi
  else
    UPDATE_VM_QEMU
  fi
}

# QEMU
UPDATE_VM_QEMU () {
  local qga_ready=false
  echo -e " ▶${GN:-} Try to connect via QEMU${CL:-}"
  QGA_ERROR=""
  if WAIT_FOR_QGA; then
    qga_ready=true
    KERNEL=$(qm guest cmd "$VM" get-osinfo | grep kernel-version || true)
    OS=$(qm guest cmd "$VM" get-osinfo | grep name || true)
    if [[ "${OS,,}" =~ windows ]]; then
      UPDATE_VM_QEMU_WINDOWS
      local windows_status=$?
      CVM=""
      return "$windows_status"
    fi
  fi
  if [[ "$qga_ready" == true ]] && CHECK_QGA_EXEC; then
    echo -e "${OR:-}  QEMU Guest Agent is available.${CL:-}\n"
    # Run Update
    if [[ $KERNEL =~ FreeBSD && $FREEBSD_UPDATES == true ]]; then
      echo -e "${OR:-}--- PKG UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- tcsh -c "pkg update" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- PKG UPGRADE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- tcsh -c "pkg upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- PKG CLEANING ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- tcsh -c "pkg autoremove -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
      return
    elif [[ "$KERNEL" =~ FreeBSD ]]; then
      echo -e "${OR:-} Free BSD skipped by user${CL:-}\n"
      return
    elif [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      # Check Internet connection
      local internet_check
      if ! internet_check=$(INTERNET_CHECK_COMMAND) || ! (RUN_QEMU_COMMAND "$VM" -- sh -c "$internet_check" >/dev/null); then
        # Same as the LXC and SSH paths: a skipped update is not a success.
        echo -e "${OR:-} ❌ Internet check fail - skip this VM${CL:-}\n"
        UPDATE_FAILURE=true
        return
      fi
      echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        RUN_QEMU_DURABLE "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING --with-new-pkgs upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        RUN_QEMU_DURABLE "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING -o APT::Get::Always-Include-Phased-Updates=true --with-new-pkgs upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
      echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get --purge autoremove -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get autoclean -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Fedora ]]; then
      echo -e "\n${OR:-}--- DNF UPGRADE ---${CL:-}"
      RUN_QEMU_DURABLE "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "dnf -y upgrade" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
      RUN_QEMU_DURABLE "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "dnf -y --purge autoremove" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Arch ]]; then
      echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
      RUN_QEMU_DURABLE "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "pacman -Syu --noconfirm" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Alpine ]]; then
      echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- ash -c "apk -U upgrade" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
    elif [[ "$OS" =~ CentOS ]]; then
      echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
      RUN_QEMU_DURABLE "$VM" --timeout "$QGA_UPDATE_TIMEOUT" -- bash -c "yum -y update" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "${OS,,}" =~ windows ]]; then
      UPDATE_VM_QEMU_WINDOWS
    else
      echo -e "${RD:-}  The system is not supported.\n  Maybe with later version ;)\n${CL:-}"
      echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
    fi
  else
    echo -e "${RD:-}  ❌ ${QGA_ERROR:-SSH or QEMU guest agent is not initialized on VM $VM}${CL:-}\n\
  ${OR:-}If you want to update VMs, you must set up it by yourself!${CL:-}\n\
  For ssh (harder, but nicer output), check this: <https://github.com/BassT23/Proxmox/blob/${INSTALLED_BRANCH:-master}/ssh.md>\n\
  For QEMU (easy connection), check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n"
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="${QGA_ERROR:-SSH or QEMU guest agent is not initialized on VM $VM}"
    ERROR
  fi
  CVM=""
}

UPDATE_VM_QEMU_WINDOWS () {
  local encoded result marker update_status processed reboot message

  if ! declare -f WINDOWS_POWERSHELL_ENCODE >/dev/null 2>&1; then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Windows update helper is not installed"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  if ! encoded=$(WINDOWS_POWERSHELL_ENCODE install); then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Could not encode the Windows Update PowerShell command"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  echo -e "${OR:-}--- WINDOWS UPDATE ---${CL:-}"
  QEMU_GUEST_EXEC "$VM" --timeout 180 -- powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded"
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    ERROR_CODE=${QEMU_EXEC_EXITCODE:-1}
    ID=$VM
    ERROR_MSG="${QEMU_EXEC_OUTPUT:-Windows Update command failed}"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  result=$(printf '%s\n' "$QEMU_EXEC_STDOUT" | tr -d '\r' | tail -n 1)
  # shellcheck disable=SC2034
  IFS='|' read -r marker update_status processed reboot message <<< "$result"
  if [[ "$marker" != UU_WINDOWS || "$update_status" != ok || ! "$processed" =~ ^[0-9]+$ || ("$reboot" != true && "$reboot" != false) ]]; then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Invalid Windows Update response: $result"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  echo "Windows updates processed: $processed"
  declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" success 0 || true
  if [[ "$reboot" == true ]]; then
    echo -e "${OR:-}Reboot required; no automatic reboot was performed.${CL:-}"
  fi
}

## General ##
READ_CONFIG

# Debug
DEBUG=$(awk -F'"' '/^DEBUG=/ {print $2; exit}' "$CONFIG_FILE")
if [[ "$DEBUG" == true ]]; then
  set -x
fi

# Logging
OUTPUT_TO_FILE () {
  if [[ "$RICM" != true ]]; then
    touch "$LOG_FILE"
    # Keep the terminal descriptors so CLEAN_LOGFILE can stop the tee.
    exec {UU_ORIG_STDOUT}>&1 {UU_ORIG_STDERR}>&2
    exec &> >(tee "$LOG_FILE")
    UU_LOG_TEE_PID=$!
  fi
  # Welcome-Screen
  if [[ -f "/etc/update-motd.d/01-welcome-screen" && -x "/etc/update-motd.d/01-welcome-screen" ]]; then
    WELCOME_SCREEN=true
    if [[ "$RICM" != true ]]; then
      touch "$LOCAL_FILES/check-output"
    fi
  fi
}
# Drop the first line and ANSI colors from the log once the run is over.
# The previous `cat log | sed | tee log` truncated the file while reading it
# (usually leaving it empty) and wrote a tmp.log into the working directory.
# shellcheck disable=SC2329
CLEAN_LOGFILE () {
  [[ "$RICM" != true ]] || return 0
  local cleaned
  if [[ -n "${UU_LOG_TEE_PID:-}" ]]; then
    # Detach from the logging tee so the file is complete before rewriting.
    # Backgrounded children (for example guest shutdowns) may still hold the
    # pipe, so only wait a few seconds for the tee to drain.
    exec 1>&"$UU_ORIG_STDOUT" 2>&"$UU_ORIG_STDERR"
    for _ in {1..50}; do
      kill -0 "$UU_LOG_TEE_PID" 2>/dev/null || break
      sleep 0.1
    done
    UU_LOG_TEE_PID=""
  fi
  cleaned=$(mktemp "${LOG_FILE}.XXXXXX") || return 1
  if tail -n +2 -- "$LOG_FILE" | sed -r 's/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g' > "$cleaned"; then
    chmod 640 -- "$cleaned" && mv -f -- "$cleaned" "$LOG_FILE"
  else
    rm -f -- "$cleaned"
  fi
}

# Error handling
# Run one update step for a target: RUN_STEP <target-id> <command...>
# The output is shown and logged once; on failure its last lines become the
# error message. Failed steps used to run a second time only to capture that
# message, repeating a failed dist-upgrade with its prompts hidden. Always
# returns 0 (callers test ERROR_CODE), so EXIT_ON_ERROR's set -e keeps its
# meaning.
RUN_STEP () {
  local id="$1" output rc=0
  shift
  output=$(mktemp "${TMPDIR:-/tmp}/ultimate-updater-step.XXXXXX" 2>/dev/null) || output=""
  { "$@" 2>&1 | tee -- "${output:-/dev/null}"; rc=${PIPESTATUS[0]}; } || true
  if [[ "$rc" -ne 0 ]]; then
    ERROR_CODE=$rc
    ID=$id
    ERROR_MSG=""
    [[ -n "$output" ]] && ERROR_MSG=$(tail -n 20 -- "$output" | tr -d '\r')
    ERROR_MSG=${ERROR_MSG:-"exit code $rc: $*"}
    ERROR
  fi
  [[ -z "$output" ]] || rm -f -- "$output"
  return 0
}

ERROR () {
  UPDATE_FAILURE=true
  if [[ "${CCONTAINER:-}" == true && "${ID:-}" =~ ^[0-9]+$ ]] &&
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
    STATUS_MODEL_UPDATE_RESULT "$ID" failed "${ERROR_CODE:-1}" || true
  fi
  # printf, not echo -e: names and messages come from guests.
  printf '%s : %s\nError code:   %s\nError output: %s\n\n' "$ID" "$NAME" "$ERROR_CODE" "$ERROR_MSG" >> "$ERROR_LOG_FILE" 2>/dev/null
  echo
}

UPDATE_FINAL_RC() {
  local command_rc="${1:-0}"
  if [[ "$command_rc" -ne 0 || "$UPDATE_FAILURE" == true || "$SAFETY_FAILURE" == true ]]; then
    return 1
  fi
  return 0
}

ERROR_LOGGING () {
  touch "$ERROR_LOG_FILE"
  true > "$ERROR_LOG_FILE"
}

# shellcheck disable=SC2329
UPDATE_MAIL_BODY() {
  if [[ "${SINGLE_UPDATE:-false}" != true && -f "$LOCAL_FILES/status.json" ]] &&
    declare -f STATUS_MODEL_RENDER_NOTIFICATION >/dev/null 2>&1; then
    local status_notification status_body
    if status_notification=$(STATUS_MODEL_RENDER_NOTIFICATION "$LOCAL_FILES/status.json" update 2>/dev/null) &&
      [[ "$status_notification" == STATE=* ]]; then
      status_body=${status_notification#*$'\n'}
      printf '%s\n' "$status_body"
      return 0
    fi
  fi
  local target="${ID:-${CONTAINER:-${VM:-$HOSTNAME}}}"
  local display_name="${NAME:-$target}" target_type="host" icon="🐧" package_count
  if [[ "${CVM:-}" == true || "${VM:-}" =~ ^[0-9]+$ ]]; then
    target_type="vm"
  elif [[ "${CCONTAINER:-}" == true || "${CONTAINER:-}" =~ ^[0-9]+$ || "${ID:-}" =~ ^[0-9]+$ ]]; then
    target_type="lxc"
  fi
  package_count=$(grep -Eo '[0-9]+ (upgraded|updated|processed)' "$LOG_FILE" 2>/dev/null | tail -n 1 || true)
  printf 'Ultimate Updater update summary\n\n'
  printf '🖥️ %s\n\n' "$HOSTNAME"
  if [[ "$target_type" != host && ! ( "$target" == "$HOSTNAME" && "$display_name" == "$HOSTNAME" ) ]]; then
    [[ "$display_name" == "$target" ]] && display_name=""
    if [[ -n "$display_name" ]]; then
      printf '%s %s · %s\n' "$icon" "$target" "$display_name"
    else
      printf '%s %s\n' "$icon" "$target"
    fi
  fi
  if [[ "${EXIT_CODE:-1}" -eq 0 && ! -s "$ERROR_LOG_FILE" ]]; then
    printf '✅ Update erfolgreich\n'
    [[ -n "$package_count" ]] && printf '⬆️ %s\n' "$package_count"
  else
    printf '⚠️ Update fehlgeschlagen\n'
    printf 'Exitcode: %s\n' "${EXIT_CODE:-1}"
    [[ -s "$ERROR_LOG_FILE" ]] && sed -n '1,4p' "$ERROR_LOG_FILE"
  fi
  if grep -Eqi 'reboot required|reboot needed' "$LOG_FILE" 2>/dev/null; then
    printf '🔄 Neustart erforderlich\n'
  fi
}

# The error log describes this run only; it used to be reset only with
# EXIT_ON_ERROR=false, so a single failure was reported again by every later
# successful run.
ERROR_LOGGING
[[ $EXIT_ON_ERROR == false ]] || set -e

# Exit
# shellcheck disable=SC2329
EXIT () {
  EXIT_CODE=$?
  if [[ "${INITIAL_INVENTORY_CLI:-false}" == true ]]; then
    rm -f -- "${TEMP_STATE_DIR:?}/var"
    rm -rf "$LOCAL_FILES"/update
    exit "$EXIT_CODE"
  fi
  # Exit without echo
  if [[ "$EXIT_CODE" == 2 ]]; then
    exit
  # Update Finish
  elif [[ "$EXIT_CODE" == 0 ]]; then
    if [[ "$RICM" != true ]]; then
      if [[ -f $ERROR_LOG_FILE && -s $ERROR_LOG_FILE ]]; then
        echo -e "${OR:-}❌ Finished, with errors.${CL:-}\n"
        echo -e "Please checkout $ERROR_LOG_FILE"
        echo
        CLEAN_LOGFILE
        if [[ "${SELF_UPDATE_RUN:-false}" != true && "${UU_DEFER_UPDATE_MAIL:-false}" != true ]]; then
          UPDATE_MAIL_BODY | UU_SEND_MAIL "$EMAIL_USER" "$EMAIL_SENDER" "Ultimate Updater summary - $HOSTNAME" 2>/dev/null || true
        fi
      else
        echo -e "${GN:-}✅ Finished.${CL:-}\n"
        "$LOCAL_FILES/exit/passed.sh"
        CLEAN_LOGFILE
        if [[ "$EMAIL_ONLY_ERROR" != true ]]; then
          if [[ "${SELF_UPDATE_RUN:-false}" != true && "${UU_DEFER_UPDATE_MAIL:-false}" != true ]]; then
            UPDATE_MAIL_BODY | UU_SEND_MAIL "$EMAIL_USER" "$EMAIL_SENDER" "Ultimate Updater" 2>/dev/null || true
          fi
        fi
      fi
    fi
  else
  # Update Error
    if [[ "$RICM" != true ]]; then
      echo -e "${RD:-}⚠  Error during update --- Exit Code: $EXIT_CODE${CL:-}\n"
      "$LOCAL_FILES/exit/error.sh"
      CLEAN_LOGFILE
      if [[ "${SELF_UPDATE_RUN:-false}" != true && "${UU_DEFER_UPDATE_MAIL:-false}" != true ]]; then
        UPDATE_MAIL_BODY | UU_SEND_MAIL "$EMAIL_USER" "$EMAIL_SENDER" "Ultimate Updater summary - $HOSTNAME" 2>/dev/null
      fi
    fi
  fi
  sleep 3
  rm -f -- "${TEMP_STATE_DIR:?}/var"
  rm -rf "$LOCAL_FILES"/update
  # Older releases left an exec_host marker that made this trap delete the
  # whole installation on a node that exited before rewriting it.
  rm -f -- "$TEMP_STATE_DIR/exec_host"
}
trap EXIT EXIT

# Check Cluster Mode
if [[ -f "/etc/corosync/corosync.conf" ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster "
else
  MODE="  Host  "
fi

# Run
export TERM=xterm-256color
if ! [[ -d "$TEMP_STATE_DIR" ]]; then mkdir -p "$TEMP_STATE_DIR"; fi
OUTPUT_TO_FILE
IP=$(hostname -i | cut -d ' ' -f1)
ARGUMENTS "$@"
ARGUMENT_RESULT=$?
if [[ "$ARGUMENT_RESULT" -ne 0 ]]; then
  exit "$ARGUMENT_RESULT"
fi
if [[ "$REMOTE_TARGET_DISPATCHED" == true ]]; then
  exit 0
fi

# Run without commands (Automatic Mode)
if [[ "$COMMAND" != true ]]; then
  TAG_LOG=true
  HEADER_INFO
  if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Continue after errors: enabled${CL:-}\n"; else echo -e "ℹ ${OR:-} Continue after errors: disabled${CL:-}\n"; fi
  if [[ "$MODE" =~ Cluster ]]; then
    HOST_UPDATE_START
  else
    echo -e "🔄${GN:-} Updating Host${CL:-} : ${GN:-}$IP | ($HOSTNAME)${CL:-}\n"
    if [[ "$WITH_HOST" == true ]]; then
      UPDATE_HOST_ITSELF
    else
      echo -e "⏩${BL:-} Skipped host itself by the user${CL:-}\n\n"
    fi
    if [[ "$WITH_LXC" == true ]]; then
      CONTAINER_UPDATE_START
    else
      echo -e "⏩${BL:-} Skipped all containers by the user${CL:-}\n"
    fi
    if [[ "$WITH_VM" == true ]]; then
      VM_UPDATE_START
    else
      echo -e "⏩${BL:-} Skipped all VMs by the user${CL:-}\n"
    fi
  fi
fi

if [[ "$SAFETY_FAILURE" == true ]]; then
  exit 1
fi

if ! UPDATE_FINAL_RC 0; then
  exit 1
fi

exit 0
