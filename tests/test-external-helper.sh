#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

bash -n "$ROOT_DIR/external-helper.sh" "$ROOT_DIR/external-bootstrap.sh"
shellcheck "$ROOT_DIR/external-helper.sh" "$ROOT_DIR/external-bootstrap.sh"

version=$("$ROOT_DIR/external-helper.sh" version)
[[ "$version" == 'ultimate-updater-external 1' ]]

if [ "$(id -u)" -ne 0 ]; then
  if "$ROOT_DIR/external-helper.sh" update >/dev/null 2>&1; then
    echo 'external helper unexpectedly allowed non-root update' >&2
    exit 1
  fi
fi
if "$ROOT_DIR/external-helper.sh" update extra >/dev/null 2>&1; then
  echo 'external helper unexpectedly accepted extra arguments' >&2
  exit 1
fi
if "$ROOT_DIR/external-helper.sh" shell >/dev/null 2>&1; then
  echo 'external helper unexpectedly accepted arbitrary action' >&2
  exit 1
fi

if grep -Eq '(^|[[:space:]])(eval|source)([[:space:]]|$)' "$ROOT_DIR/external-helper.sh"; then
  echo 'external helper contains unsafe source/eval' >&2
  exit 1
fi
if grep -Eq '\$[@*]' "$ROOT_DIR/external-helper.sh"; then
  echo 'external helper forwards arbitrary arguments' >&2
  exit 1
fi
# external-bootstrap.sh writes sudoers as root, so it is checked statically:
# one validated user name (a multi-line argument passed `printf | grep`), an
# exit after INT/TERM (sh resumes after a trap handler), and the helper
# probe runs through sh (noexec /tmp).
grep -Fq "''|ALL|[!A-Za-z_]*|*[!A-Za-z0-9_.-]*)" "$ROOT_DIR/external-bootstrap.sh"
grep -Fxq "trap 'exit 130' HUP INT TERM" "$ROOT_DIR/external-bootstrap.sh"
# shellcheck disable=SC2016 # literal source text
grep -Fxq 'sh "$temporary_helper" version >/dev/null' "$ROOT_DIR/external-bootstrap.sh"
echo 'external helper validation tests: PASS'
