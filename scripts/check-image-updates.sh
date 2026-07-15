#!/usr/bin/env bash
# Checks every image referenced in docker-compose.yml for an available
# update and notifies — does NOT pull/recreate any running container.
# Review and apply updates yourself with:
#   docker compose --profile caddy pull && docker compose --profile caddy up -d
#
# Installed by scripts/install-update-check.sh.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

if [[ -f .env ]]; then
  # shellcheck source=/dev/null
  set -a; source .env; set +a
fi

# COMPOSE_PROFILES makes `config --images` list every service regardless of
# which profile is actually running.
IMAGES=$(COMPOSE_PROFILES=caddy,tunnel,matrix docker compose config --images | sort -u)

UPDATES=()
for image in $IMAGES; do
  pull_output=$(docker pull "$image" 2>&1) || {
    echo "WARN: failed to pull $image"
    continue
  }
  if echo "$pull_output" | grep -q "Downloaded newer image"; then
    UPDATES+=("$image")
  fi
done

if [[ ${#UPDATES[@]} -eq 0 ]]; then
  echo "$(date -u +%FT%TZ) — all images up to date."
  exit 0
fi

MSG="vaultwarden-setup: update available for: $(printf '%s, ' "${UPDATES[@]}" | sed 's/, $//')"
echo "$MSG"

if [[ -n "${NTFY_TOPIC:-}" ]]; then
  curl -fsS -d "$MSG" "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}" >/dev/null \
    || echo "WARN: ntfy notification failed"
fi
