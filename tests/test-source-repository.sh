#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329 # literal fragments; stubs and variables are used by evaluated code.
set -euo pipefail

# The download source is configurable for forks (UU_REPOSITORY=owner/name),
# recorded in build-metadata, and validated before it is used in any URL.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
UPSTREAM="BassT23/Proxmox"
FORK="example-user/Proxmox"
SHA="0123456789abcdef0123456789abcdef01234567"

# --- Shared resolver (tag-filter.sh, used by update.sh and version checks) --
resolve() {
  env -u UU_REPOSITORY "$@" bash -c 'source "$1"; UU_SOURCE_REPOSITORY' _ "$ROOT_DIR/tag-filter.sh" 2>"$WORK_DIR/stderr"
}
metadata="$WORK_DIR/build-metadata"
[[ "$(resolve UU_BUILD_METADATA_FILE="$metadata")" == "$UPSTREAM" ]]
[[ "$(resolve UU_BUILD_METADATA_FILE="$metadata" UU_REPOSITORY="$FORK")" == "$FORK" ]]
printf 'schema_version=1\nbranch="master"\ncommit="%s"\ntag=""\nrepository="%s"\n' "$SHA" "$FORK" > "$metadata"
[[ "$(resolve UU_BUILD_METADATA_FILE="$metadata")" == "$FORK" ]]
[[ "$(resolve UU_BUILD_METADATA_FILE="$metadata" UU_REPOSITORY="other/Repo.name")" == "other/Repo.name" ]]
for invalid in 'owner/..' 'owner/.' 'no-slash' '-owner/repo' 'owner/re po' 'a/b/c' 'owner/repo;id' '../x'; do
  [[ "$(resolve UU_BUILD_METADATA_FILE="$metadata" UU_REPOSITORY="$invalid")" == "$UPSTREAM" ]]
  grep -Fq 'Ignoring invalid source repository' "$WORK_DIR/stderr"
done

# --- Installer resolution: env > recorded metadata > upstream; invalid exits.
resolution=$(sed -n '/^# Source repository (owner\/name)/,/^SERVER_URL=/p' "$ROOT_DIR/install.sh")
grep -Fq 'export UU_REPOSITORY="$REPOSITORY"' <<< "$resolution"
installer_repository() {
  env -u UU_REPOSITORY "$@" bash -c 'BRANCH=master; BUILD_METADATA_FILE=$1; eval "$2"; printf "%s %s\n" "$REPOSITORY" "$SERVER_URL"' \
    _ "$metadata" "$resolution"
}
[[ "$(installer_repository)" == "$FORK https://raw.githubusercontent.com/$FORK/master" ]]
[[ "$(installer_repository UU_REPOSITORY="$UPSTREAM")" == "$UPSTREAM https://raw.githubusercontent.com/$UPSTREAM/master" ]]
rm -f "$metadata"
[[ "$(installer_repository)" == "$UPSTREAM https://raw.githubusercontent.com/$UPSTREAM/master" ]]
if UU_REPOSITORY='owner/..' TERM=dumb bash "$ROOT_DIR/install.sh" --help >"$WORK_DIR/out" 2>&1; then
  echo 'installer accepted an invalid repository' >&2
  exit 1
fi
grep -Fq 'Unsupported source repository' "$WORK_DIR/out"

# --- Archive download: forks without releases fall back to master only. ----
eval "$(sed -n '/^DOWNLOAD_ARCHIVE() {/,/^}/p' "$ROOT_DIR/install.sh")"
eval "$(sed -n '/^WRITE_BUILD_METADATA() {/,/^}/p' "$ROOT_DIR/install.sh")"
TEMP_FOLDER="$WORK_DIR/temp"
mkdir -p "$TEMP_FOLDER" "$WORK_DIR/archive/fork-Proxmox-0123456"
touch "$WORK_DIR/archive/fork-Proxmox-0123456/update.sh"
tar -czf "$WORK_DIR/fixture.tar.gz" -C "$WORK_DIR/archive" fork-Proxmox-0123456
DOWNLOAD_FILE() {
  printf '%s\n' "$1" >> "$WORK_DIR/urls"
  case "$1" in
    */releases/latest) return 1 ;;
    */tarball/*) cp "$WORK_DIR/fixture.tar.gz" "$2" ;;
    *) return 1 ;;
  esac
}
curl() { printf '{"sha": "%s"}\n' "$SHA"; }

REPOSITORY=$FORK UPSTREAM_REPOSITORY=$UPSTREAM BRANCH=master
: > "$WORK_DIR/urls"
DOWNLOAD_ARCHIVE 2>"$WORK_DIR/stderr"
grep -Fqx "https://api.github.com/repos/$FORK/releases/latest" "$WORK_DIR/urls"
grep -Fqx "https://github.com/$FORK/tarball/master" "$WORK_DIR/urls"
grep -Fq "No release is published in $FORK" "$WORK_DIR/stderr"
[[ "$ARCHIVE_COMMIT" == "$SHA" ]]

REPOSITORY=$UPSTREAM
: > "$WORK_DIR/urls"
if DOWNLOAD_ARCHIVE 2>/dev/null; then
  echo 'upstream master must not fall back to a branch archive' >&2
  exit 1
fi
if grep -Fq '/tarball/' "$WORK_DIR/urls"; then
  echo 'upstream master downloaded a branch archive' >&2
  exit 1
fi

REPOSITORY=$FORK BRANCH=beta
: > "$WORK_DIR/urls"
DOWNLOAD_ARCHIVE
grep -Fqx "https://github.com/$FORK/tarball/beta" "$WORK_DIR/urls"

# --- The installer records the repository for later self-updates. ---------
BUILD_METADATA_FILE="$WORK_DIR/written-metadata"
install() { cp "$3" "$4"; }  # install -m MODE SOURCE DESTINATION
WRITE_BUILD_METADATA master "$SHA" v5.1.2
grep -Fqx "repository=\"$FORK\"" "$BUILD_METADATA_FILE"
grep -Fqx "commit=\"$SHA\"" "$BUILD_METADATA_FILE"

# --- update.sh uses the resolved repository for every self-update URL. -----
if grep -En 'https://(raw\.githubusercontent\.com|api\.github\.com/repos|github\.com)/BassT23/Proxmox/(refs|commits|tarball|releases|[a-z]+/[a-z-]+\.sh)' \
  "$ROOT_DIR/update.sh" "$ROOT_DIR/install.sh" "$ROOT_DIR/tag-filter.sh"; then
  echo 'a download URL still hard-codes the upstream repository' >&2
  exit 1
fi
eval "$(sed -n '/^FETCH_REMOTE_COMMIT() {/,/^}/p' "$ROOT_DIR/update.sh")"
curl() { printf '%s\n' "$*" > "$WORK_DIR/curl-args"; printf '{"sha": "%s"}\n' "$SHA"; }
UU_REPOSITORY=$FORK
[[ "$(FETCH_REMOTE_COMMIT master)" == "$SHA" ]]
grep -Fq "https://api.github.com/repos/$FORK/commits/master" "$WORK_DIR/curl-args"

echo 'source repository tests: PASS'
