#!/bin/bash

#################
# Update-Extras #
#################

# shellcheck disable=SC2034

VERSION="3.1"

# Variables
LOCAL_FILES="${LOCAL_FILES:-/etc/ultimate-updater}"
CONFIG_FILE="${UU_UPDATE_CONFIG_FILE:-$LOCAL_FILES/update.conf}"
PIHOLE=$(awk -F'"' '/^PIHOLE=/ {print $2; exit}' "$CONFIG_FILE")
IOBROKER=$(awk -F'"' '/^IOBROKER=/ {print $2; exit}' "$CONFIG_FILE")
PTERODACTYL=$(awk -F'"' '/^PTERODACTYL=/ {print $2; exit}' "$CONFIG_FILE")
OCTOPRINT=$(awk -F'"' '/^OCTOPRINT=/ {print $2; exit}' "$CONFIG_FILE")
DOCKER_COMPOSE=$(awk -F'"' '/^DOCKER_COMPOSE=/ {print $2; exit}' "$CONFIG_FILE")
COMPOSE_PATH=$(awk -F'"' '/^COMPOSE_PATH=/ {print $2; exit}' "$CONFIG_FILE")
INCLUDE_HELPER_SCRIPTS=$(awk -F'"' '/^INCLUDE_HELPER_SCRIPTS=/ {print $2; exit}' "$CONFIG_FILE")

# PiHole
if [[ -f "/usr/local/bin/pihole" && $PIHOLE == true ]]; then
  echo -e "\n*** Updating PiHole ***\n"
  /usr/local/bin/pihole -up
fi

# ioBroker
if [[ -d "/opt/iobroker" && $IOBROKER == true ]]; then
  echo -e "\n*** Updating ioBroker ***\n"
  echo "*** Stop ioBroker ***" &&  sudo -u iobroker bash -c "iob stop" && echo
  echo "*** Update/Upgrade ioBroker ***" && sudo -u iobroker bash -c "iob update" && sudo -u iobroker bash -c "iob upgrade -y" && sudo -u iobroker bash -c "iob upgrade self -y" && echo
  echo "*** Start ioBroker ***" && sudo -u iobroker bash -c "iob start" && echo
  if [[ -d "/opt/iobroker/iobroker-data/radar2.admin" ]]; then
    for tool in arp-scan node arp hcitool hciconfig l2ping; do
      tool_path=$(command -v -- "$tool") || continue
      tool_path=$(readlink -f -- "$tool_path") || continue
      setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "$tool_path"
    done
  fi
fi

# Pterodactyl
if [[ -d "/var/www/pterodactyl" && $PTERODACTYL == true ]]; then
  echo -e "\n*** Updating Pterodactyl ***\n"
  cd /var/www/pterodactyl || exit
  # Download and verify the release before taking the panel down: piping an
  # HTTP error page into tar used to leave a half-extracted panel behind.
  panel_archive=$(mktemp) || exit 1
  if curl -fsSL -o "$panel_archive" https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz &&
    tar -tzf "$panel_archive" >/dev/null; then
    php artisan down
    tar -xzvf "$panel_archive"
    chmod -R 755 storage/* bootstrap/cache
    composer install --no-dev --optimize-autoloader
    php artisan view:clear
    php artisan config:clear
    php artisan migrate --seed --force
  else
    echo "Pterodactyl panel download failed; the panel was left unchanged." >&2
  fi
  rm -f -- "$panel_archive"
  # hostnamectl is unavailable in most containers; os-release always exists.
  # shellcheck disable=SC1091 # system file, read in a subshell
  os=$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
  if [[ " $os " == *" centos "* || " $os " == *" rhel "* ]]; then
    # If using NGINX on CentOS:
    if id -u "nginx" >/dev/null 2>&1; then
      chown -R nginx:nginx /var/www/pterodactyl/*
    # If using Apache on CentOS
    elif id -u "apache" >/dev/null 2>&1; then
      chown -R apache:apache /var/www/pterodactyl/*
    fi
  else
    # If using NGINX or Apache (not on CentOS):
    chown -R www-data:www-data /var/www/pterodactyl/*
  fi
  php artisan queue:restart
  php artisan up
  # Upgrade Wings only with a verified download; curl without -f used to
  # replace the binary with an HTTP error page.
  wings_arch=arm64
  [[ "$(uname -m)" == x86_64 ]] && wings_arch=amd64
  if wings_download=$(mktemp /usr/local/bin/.wings.XXXXXX) &&
    curl -fsSL -o "$wings_download" "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$wings_arch" &&
    chmod 0755 "$wings_download" && "$wings_download" --version >/dev/null 2>&1; then
    systemctl stop wings
    mv -f -- "$wings_download" /usr/local/bin/wings
    systemctl restart wings
  else
    rm -f -- "${wings_download:-}"
    echo "Wings download failed; the existing binary was kept." >&2
  fi
fi

# Octoprint
if [[ -d "/root/OctoPrint" && $OCTOPRINT == true ]]; then
  echo -e "\n*** Updating Octoprint ***\n"
  # find octoprint
  OPRINT=$(find /home -name "oprint" -type d -print -quit)
  if [[ -x "$OPRINT/bin/pip" ]]; then
    "$OPRINT"/bin/pip install -U --ignore-installed octoprint
    systemctl restart octoprint
  else
    echo "OctoPrint virtual environment (oprint) was not found below /home." >&2
  fi
fi

# Docker Compose detection
if [[ -f /usr/local/bin/docker-compose ]]; then DOCKER_COMPOSE_V1=true; fi
if docker compose version &>/dev/null; then DOCKER_COMPOSE_V2=true; fi

# Docker-Compose run
if [[ $DOCKER_COMPOSE_V1 == true || $DOCKER_COMPOSE_V2 == true ]] && [[ $DOCKER_COMPOSE == true ]]; then
  # Cleaning. Only remove the dangling images left behind by the pulls above.
  # The previous container/system/volume prunes also deleted unrelated stopped
  # containers and unused volumes (named volumes on Docker < 23): user data.
  DOCKER_EXIT () {
    echo -e "\n*** Cleaning ***"
    docker image prune -f
  }
  COMPOSEFILES=("docker-compose.y*ml" "compose.y*ml")
  DIRLIST=()
  for COMPOSEFILE in "${COMPOSEFILES[@]}"; do
    while IFS= read -r line; do
      DIRLIST+=("$line")
    done < <(find "$COMPOSE_PATH" -name "$COMPOSEFILE" -exec dirname {} \; 2> >(grep -v 'Permission denied'))
  done

  # Docker-Compose v1
  if [[ $DOCKER_COMPOSE_V1 == true && ${#DIRLIST[@]} -gt 0 ]]; then
    echo -e "\n*** Updating Docker-Compose v1 (oldstable) ***\n"
    for dir in "${DIRLIST[@]}"; do
      echo "Updating $dir..."
      pushd "$dir" > /dev/null || continue
      /usr/local/bin/docker-compose pull
      /usr/local/bin/docker-compose up --force-recreate --build -d
      /usr/local/bin/docker-compose restart
      popd > /dev/null || exit 1
    done
    echo "All projects have been updated."
    DOCKER_EXIT
  fi
  # Docker-Compose v2
  if [[ $DOCKER_COMPOSE_V2 == true && ${#DIRLIST[@]} -gt 0 ]]; then
    echo -e "\n*** Updating Docker Compose ***"
    for dir in "${DIRLIST[@]}"; do
      echo "Updating $dir..."
      pushd "$dir" > /dev/null || continue
      docker compose pull && docker compose up -d
      popd > /dev/null || exit 1
    done
    echo "All projects have been updated."
    DOCKER_EXIT
  fi
fi

# Community / Helper Scripts
if grep -q "community-scripts" /usr/bin/update 2>/dev/null && [[ $INCLUDE_HELPER_SCRIPTS == true ]]; then
  echo -e "\n*** Updating Community-Scripts ***"
  COMMUNITY_UPDATE_LOG=$(mktemp)
  if timeout 1800s env PHS_SILENT=1 update >"$COMMUNITY_UPDATE_LOG" 2>&1; then
    echo -e "✅ Update process completed\n"
  else
    COMMUNITY_UPDATE_EXIT=$?
    if [[ $COMMUNITY_UPDATE_EXIT == 124 ]]; then
      echo -e "⚠️ Community-Scripts update timed out after 30 minutes"
    else
      echo -e "⚠️ Community-Scripts update failed with exit code $COMMUNITY_UPDATE_EXIT"
    fi
    echo -e "Community-Scripts output:\n"
    cat "$COMMUNITY_UPDATE_LOG"
    echo
  fi
  rm -f "$COMMUNITY_UPDATE_LOG"
fi
