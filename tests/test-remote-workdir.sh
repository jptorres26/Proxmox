#!/usr/bin/env bash
# shellcheck disable=SC2016 # the patterns match literal shell code.
set -euo pipefail

# Remote work directories in /tmp are created exclusively (mkdir without -p
# fails on an existing name or symlink), and the central check keeps its
# local copies of remote results in a private mktemp directory.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/ultimate-updater" CHECK="$ROOT_DIR/check-updates.sh"

if grep -En "mkdir -p (-- )?('[^']*' )*'\\\$remote_(check|update)_dir'" "$CLI" "$CHECK"; then
  echo 'a remote work directory is created with mkdir -p' >&2
  exit 1
fi
[[ $(grep -c "mkdir -m 0700 -- '\$remote_\(check\|update\)_dir'" "$CLI") -eq 3 ]]
grep -Fq "mkdir -m 0700 '\$remote_check_dir'" "$CHECK"

# The exclusive create really fails on a prepared name.
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/target"
ln -s "$work/target" "$work/link"
if mkdir -m 0700 -- "$work/link" 2>/dev/null || mkdir -m 0700 -- "$work/target" 2>/dev/null; then
  echo 'mkdir -m 0700 accepted an existing name' >&2
  exit 1
fi

check_host=$(sed -n '/^CHECK_HOST () {/,/^}/p' "$CHECK")
grep -Fq 'remote_local_dir=$(mktemp -d /tmp/ultimate-updater-remote.XXXXXX)' <<< "$check_host"
grep -Fq 'remote_status_file="$remote_local_dir/status.json"' <<< "$check_host"
grep -Fq 'remote_diagnostics_local_file="$remote_local_dir/diagnostics.log"' <<< "$check_host"
if grep -Eq '"/tmp/ultimate-updater-remote-(status|diagnostics)-' <<< "$check_host"; then
  echo 'the central check still writes predictable /tmp files' >&2
  exit 1
fi
# Every return after the local directory exists removes it (the final one
# after the shared cleanup).
awk '
  /remote_status_file="\$remote_local_dir\/status.json"/ { created = 1; next }
  created && /rm -rf -- "\$remote_local_dir"/ { cleaned = 1 }
  created && /^[[:space:]]+return/ { if (!cleaned) { print "return without cleanup at line " NR; bad = 1 } cleaned = 0 }
  END { exit bad }
' <<< "$check_host"

echo 'remote work directories: PASS'
