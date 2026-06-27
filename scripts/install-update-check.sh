#!/usr/bin/env bash
# Installs/updates the daily image-update-check cron job.
# Safe to re-run any time — e.g. after `git pull` to pick up changes to
# check-image-updates.sh — without re-running the full server setup.
#
# Usage: sudo bash scripts/install-update-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

chmod +x "$SCRIPT_DIR/check-image-updates.sh"

echo "15 8 * * * root $SCRIPT_DIR/check-image-updates.sh >> /var/log/vw-image-updates.log 2>&1" \
  > /etc/cron.d/vaultwarden-update-check

echo "Installed /etc/cron.d/vaultwarden-update-check (runs daily at 08:15 UTC)"
echo ""
echo "Run a check now with: bash $SCRIPT_DIR/check-image-updates.sh"
echo "Set NTFY_TOPIC in .env for a push notification when updates are found:"
echo "  https://ntfy.sh/ — pick any topic name, then on your phone/desktop:"
echo "  ntfy subscribe <topic>, or use the app."
