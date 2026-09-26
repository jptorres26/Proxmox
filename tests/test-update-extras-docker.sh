#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies are literal.
set -euo pipefail

# Compose updates may only remove the dangling images their pulls leave
# behind. Pruning stopped containers or volumes destroys unrelated user data.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/compose/app" "$WORK_DIR/compose/other"
printf 'services: {}\n' > "$WORK_DIR/compose/app/compose.yaml"
printf 'services: {}\n' > "$WORK_DIR/compose/other/docker-compose.yml"

cat > "$WORK_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$DOCKER_LOG"
exit 0
STUB
chmod 755 "$WORK_DIR/bin/docker"

cat > "$WORK_DIR/update.conf" <<CONFIG
PIHOLE="false"
IOBROKER="false"
PTERODACTYL="false"
OCTOPRINT="false"
DOCKER_COMPOSE="true"
COMPOSE_PATH="$WORK_DIR/compose"
INCLUDE_HELPER_SCRIPTS="false"
CONFIG

DOCKER_LOG="$WORK_DIR/docker.log" PATH="$WORK_DIR/bin:$PATH" UU_UPDATE_CONFIG_FILE="$WORK_DIR/update.conf" \
  bash "$ROOT_DIR/update-extras.sh" > "$WORK_DIR/output" 2>&1

grep -Fxq "$WORK_DIR/compose/app|compose pull" "$WORK_DIR/docker.log"
grep -Fxq "$WORK_DIR/compose/app|compose up -d" "$WORK_DIR/docker.log"
grep -Fxq "$WORK_DIR/compose/other|compose up -d" "$WORK_DIR/docker.log"
grep -Fq '|image prune -f' "$WORK_DIR/docker.log"
if grep -Eq '\|(container prune|system prune)|--volumes' "$WORK_DIR/docker.log"; then
  echo 'Docker cleanup pruned containers, the whole system, or volumes' >&2
  cat "$WORK_DIR/docker.log" >&2
  exit 1
fi

echo 'update extras docker cleanup: PASS'
