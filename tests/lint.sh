#!/usr/bin/env bash
# Run the static checks enforced by CI: ShellCheck for every shell
# script, Ruff for the Python web UI and tests, and actionlint for workflows.
# Install the pinned tool versions with:
#   python3 -m pip install -r requirements-dev.txt
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$ROOT_DIR"

missing=()
for tool in git shellcheck ruff actionlint; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
  printf 'Missing lint tools: %s\n' "${missing[*]}" >&2
  printf 'Install them with: python3 -m pip install -r requirements-dev.txt\n' >&2
  exit 2
fi

# Same selection rule as the previous ShellCheck action: shell extensions or a
# shell shebang, regardless of file name. New files count before they are
# committed (tracked plus untracked, minus .gitignore).
shell_files=()
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] || continue
  if [[ "$file" == *.sh || "$file" == *.bash ]] ||
    head -n 1 -- "$file" | grep -Eq '^#! */[^ ]*/(env *)?[abkd]*sh'; then
    shell_files+=("$file")
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

rc=0
printf '==> ShellCheck (%d files)\n' "${#shell_files[@]}"
shellcheck -- "${shell_files[@]}" || rc=1
printf '==> Ruff\n'
ruff check || rc=1
printf '==> actionlint\n'
actionlint || rc=1
exit "$rc"
