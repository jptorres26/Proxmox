#!/usr/bin/env bash
set -euo pipefail

# Self-update copies every "*.* */*.*" file that survives the payload cleanup
# into /etc/ultimate-updater. Run the installer's real cleanup statements
# against a copy of the repository and make sure no repository-only file
# (documentation, tests, CI and lint configuration) would be installed.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cleanup_code=$(awk '
  /^    rm -f "\$TEMP_FILES"\/update.conf "\$TEMP_FILES"\/update.conf.dist$/ { active = 1 }
  active { print }
  active && /^    remove_non_runtime_payload "\$TEMP_FILES"$/ { exit }
' "$INSTALLER")
grep -Fq 'remove_non_runtime_payload() {' <<< "$cleanup_code"
# shellcheck disable=SC2016 # literal installer code is the assertion target.
grep -Fq 'rm -rf "$TEMP_FILES"/tests' <<< "$cleanup_code"

payload="$WORK_DIR/payload"
mkdir -p "$payload"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT_DIR" ls-files -z | (cd "$ROOT_DIR" && xargs -0 cp --parents -t "$payload")
else
  cp -a "$ROOT_DIR/." "$payload/"
fi

# shellcheck disable=SC2034 # consumed by the evaluated installer code.
TEMP_FILES="$payload"
# shellcheck disable=SC2034
WEB_SERVICE_NAME="ultimate-updater-web.service"
eval "$cleanup_code"

# Run the installer's own loop, with CHECK_DIFF listing what it would install.
sed -n '/^INSTALL_PAYLOAD_FILES () {/,/^}/p' "$INSTALLER" > "$WORK_DIR/install-loop.sh"
grep -q '^INSTALL_PAYLOAD_FILES () {' "$WORK_DIR/install-loop.sh"
mkdir -p "$WORK_DIR/etc"
installed=()
(
  cd "$payload"
  # shellcheck disable=SC1091
  source "$WORK_DIR/install-loop.sh"
  # shellcheck disable=SC2034 # read by INSTALL_PAYLOAD_FILES.
  LOCAL_FILES="$WORK_DIR/etc"
  # shellcheck disable=SC2153,SC2329 # called by INSTALL_PAYLOAD_FILES, which sets FILE.
  CHECK_DIFF() { printf '%s\n' "$FILE"; }
  INSTALL_PAYLOAD_FILES
) > "$WORK_DIR/installed"
mapfile -t installed < "$WORK_DIR/installed"

((${#installed[@]} > 0))
for file in "${installed[@]}"; do
  case "$file" in
    *.md | tests/* | docs/* | .github/* | ruff.toml | requirements-dev.txt | *.png | targets.conf)
      printf 'repository-only file would be installed: %s\n' "$file" >&2
      exit 1
      ;;
  esac
done
# Core runtime files must still be installed.
for runtime in update.sh check-updates.sh job-runner.sh status-model.sh tag-filter.sh; do
  printf '%s\n' "${installed[@]}" | grep -Fxq "$runtime"
done

echo 'installer payload cleanup: PASS'
