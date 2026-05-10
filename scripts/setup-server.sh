#!/usr/bin/env bash
# Cloud-init compatible setup script — runs once on first boot of the Azure VM.
# Installs Docker, clones the repo, and configures automatic OS updates.
# This script is base64-encoded and passed to the VM via the Bicep customData field.
set -euo pipefail

echo "==> [1/7] Configuring 1 GB swap file (recommended on B1ms/B1s)..."
if [[ ! -f /swapfile ]]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> [2/7] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -y -q

echo "==> [3/7] Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

# Allow the default user to run docker without sudo
ADMIN_USER=$(getent passwd 1000 | cut -d: -f1 || echo "azureuser")
usermod -aG docker "$ADMIN_USER"

echo "==> [4/7] Configuring automatic security updates..."
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades-vw << 'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> [5/7] Cloning vaultwarden-setup repo..."
REPO_DIR="/opt/vaultwarden-setup"
git clone https://github.com/panssystem/vaultwarden-setup.git "$REPO_DIR" || {
  # If repo isn't public yet, create the directory and rsync files manually
  mkdir -p "$REPO_DIR"
  echo "NOTE: Repo not cloned — copy files manually or push to GitHub and re-run."
}
chown -R "$ADMIN_USER:$ADMIN_USER" "$REPO_DIR"

echo "==> [6/7] Configuring Docker log rotation..."
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker

echo "==> [7/7] Installing daily Vaultwarden backup cron job..."
mkdir -p /opt/backups

cat > /opt/vaultwarden-backup.sh << 'BACKUP_SCRIPT'
#!/usr/bin/env bash
# Daily backup of vaultwarden data volume.
# Keeps 30 days of archives in /opt/backups.
set -euo pipefail
BACKUP_DIR=/opt/backups
mkdir -p "$BACKUP_DIR"

# Dump the live SQLite DB via vaultwarden's built-in backup API (safe mid-run)
# Fall back to a plain tar if the container isn't running
if docker inspect vaultwarden &>/dev/null; then
  docker exec vaultwarden sqlite3 /data/db.sqlite3 ".backup '/data/db.sqlite3.bak'"
fi

docker run --rm \
  -v vaultwarden-setup_vw-data:/data:ro \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf "/backup/vw-data-$(date +%F-%H%M).tar.gz" /data

# Prune archives older than 30 days
find "$BACKUP_DIR" -name "vw-data-*.tar.gz" -mtime +30 -delete
echo "Backup complete: /backup/vw-data-$(date +%F-%H%M).tar.gz"
BACKUP_SCRIPT

chmod +x /opt/vaultwarden-backup.sh

# Run at 02:30 UTC daily (off-peak)
echo "30 2 * * * root /opt/vaultwarden-backup.sh >> /var/log/vw-backup.log 2>&1" \
  > /etc/cron.d/vaultwarden-backup

echo ""
echo "==> Setup complete!"
echo "    Next steps:"
echo "    1. SSH into the VM: ssh azureuser@<VM_PUBLIC_IP>"
echo "    2. cd $REPO_DIR"
echo "    3. cp .env.example .env && nano .env   (set DOMAIN=https://vault.kaosklan.net, etc.)"
echo "    4. docker compose --profile caddy up -d"
