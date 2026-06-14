#!/usr/bin/env bash
# Installs/updates the daily backup script and its cron job.
# Safe to re-run any time — e.g. after `git pull` to pick up changes to
# vaultwarden-backup.sh — without re-running the full server setup.
#
# Usage: sudo bash scripts/install-backup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p /opt/backups
install -m 755 "$SCRIPT_DIR/vaultwarden-backup.sh" /opt/vaultwarden-backup.sh

echo "30 2 * * * root /opt/vaultwarden-backup.sh >> /var/log/vw-backup.log 2>&1" \
  > /etc/cron.d/vaultwarden-backup

echo "Installed /opt/vaultwarden-backup.sh"
echo "Installed /etc/cron.d/vaultwarden-backup (runs daily at 02:30 UTC)"
echo ""
echo "Run a backup now with: sudo /opt/vaultwarden-backup.sh"
