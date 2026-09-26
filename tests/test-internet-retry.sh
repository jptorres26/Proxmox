#!/usr/bin/env bash
# shellcheck disable=SC2016 # the bash -c bodies expand in the child shell.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

{
  sed -n '/^INTERNET_CHECK_COMMAND() {/,/^}/p' "$ROOT_DIR/target-runtime.sh"
  sed -n '/^CHECK_INTERNET () {/,/^}/p' "$ROOT_DIR/update.sh"
} > "$WORK_DIR/check.sh"
mkdir -p "$WORK_DIR/bin"
# Stand-in for ping and curl: counts calls and records its arguments.
cat > "$WORK_DIR/probe" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$RETRY_COUNT_FILE" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$RETRY_COUNT_FILE"
printf '%s %s\n' "${0##*/}" "$*" >> "$RETRY_COUNT_FILE.args"
if [[ -n "${PROBE_FAIL_FIRST:-}" ]]; then
  [[ "$count" -eq 1 ]] && exit 1
  exit 0
fi
exit "${PROBE_RESULT:-0}"
EOF
chmod +x "$WORK_DIR/probe"
ln -s ../probe "$WORK_DIR/bin/ping"
ln -s ../probe "$WORK_DIR/bin/curl"

run_check() {
  printf '0\n' > "$WORK_DIR/count"
  rm -f "$WORK_DIR/count.args"
  set +e
  env PATH="$WORK_DIR/bin:$PATH" RETRY_COUNT_FILE="$WORK_DIR/count" "$@" \
    bash -c 'source "$1"; sleep(){ :; }; CHECK_INTERNET' _ "$WORK_DIR/check.sh" \
    >"$WORK_DIR/output" 2>"$WORK_DIR/error"
  rc=$?
  set -e
}

# Immediate success: no retry.
run_check PROBE_RESULT=0 CHECK_URL_EXE=ping CHECK_URL=example.test
[[ "$rc" -eq 0 && "$(cat "$WORK_DIR/count")" -eq 1 ]]
grep -Fxq 'ping -q -c1 example.test' "$WORK_DIR/count.args"

# A transient failure is retried and then succeeds.
run_check PROBE_FAIL_FIRST=1 CHECK_URL_EXE=ping CHECK_URL=example.test
[[ "$rc" -eq 0 && "$(cat "$WORK_DIR/count")" -eq 2 ]]

# All attempts fail with the historical exit code.
run_check PROBE_RESULT=1 CHECK_URL_EXE=ping CHECK_URL=example.test
[[ "$rc" -eq 2 && "$(cat "$WORK_DIR/count")" -eq 3 ]]

# curl is called with a timeout; it used to be `curl -q -c1 URL`, which wrote
# a cookie jar named "1".
run_check PROBE_RESULT=0 CHECK_URL_EXE=/usr/bin/curl CHECK_URL=example.test
grep -Fxq 'curl -fsS -o /dev/null --max-time 10 example.test' "$WORK_DIR/count.args"

# Configured values are never run as shell code.
touch "$WORK_DIR/marker-absent"
run_check PROBE_RESULT=0 CHECK_URL_EXE='touch /tmp/owned;ping' CHECK_URL='example.test;rm -f '"$WORK_DIR/marker-absent"
[[ "$rc" -ne 0 && "$(cat "$WORK_DIR/count")" -eq 0 ]]
[[ -e "$WORK_DIR/marker-absent" ]]
grep -Fq 'URL_FOR_INTERNET_CHECK must be a host name or IP address' "$WORK_DIR/output"
run_check PROBE_RESULT=0 CHECK_URL_EXE='sh' CHECK_URL=example.test   # anything else means ping
grep -Fxq 'ping -q -c1 example.test' "$WORK_DIR/count.args"

echo 'internet retry tests: PASS'
