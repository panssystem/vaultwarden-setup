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
# - Creates a local tar.gz in /opt/backups (keeps 30 days)
# - Uploads to Azure Blob Storage using the VM's managed identity (no credentials needed)
# Storage account name is read from /etc/vaultwarden-backup.conf (written by deploy.sh)
set -euo pipefail

BACKUP_DIR=/opt/backups
TIMESTAMP=$(date +%F-%H%M)
ARCHIVE="${BACKUP_DIR}/vw-data-${TIMESTAMP}.tar.gz"
mkdir -p "$BACKUP_DIR"

# Flush SQLite WAL to ensure a clean snapshot
if docker inspect vaultwarden &>/dev/null 2>&1; then
  docker exec vaultwarden sqlite3 /data/db.sqlite3 "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
fi

# Create local archive from the live volume (read-only mount)
docker run --rm \
  -v vaultwarden-setup_vw-data:/data:ro \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar czf "/backup/vw-data-${TIMESTAMP}.tar.gz" /data

echo "Local backup: ${ARCHIVE} ($(du -sh "$ARCHIVE" | cut -f1))"

# Prune local archives older than 30 days
find "$BACKUP_DIR" -name "vw-data-*.tar.gz" -mtime +30 -delete

# ── Upload to Azure Blob Storage ──────────────────────────────────────────────
# Reads storage account name from config written by deploy.sh.
# Uses the VM's managed identity via IMDS — no credentials stored anywhere.
CONF=/etc/vaultwarden-backup.conf
if [[ ! -f "$CONF" ]]; then
  echo "WARN: $CONF not found — skipping Azure upload. Run deploy.sh to configure."
  exit 0
fi
# shellcheck source=/dev/null
source "$CONF"

if [[ -z "${BACKUP_STORAGE_ACCOUNT:-}" ]]; then
  echo "WARN: BACKUP_STORAGE_ACCOUNT not set in $CONF — skipping Azure upload."
  exit 0
fi

# Get a short-lived bearer token from the Azure Instance Metadata Service
TOKEN=$(curl -sf \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

BLOB_NAME="vw-data-${TIMESTAMP}.tar.gz"
UPLOAD_URL="https://${BACKUP_STORAGE_ACCOUNT}.blob.core.windows.net/vw-backups/${BLOB_NAME}"

curl -sf -X PUT \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-ms-version: 2020-04-08" \
  -H "x-ms-blob-type: BlockBlob" \
  -H "Content-Type: application/gzip" \
  --data-binary @"${ARCHIVE}" \
  "${UPLOAD_URL}"

echo "Uploaded to Azure: ${UPLOAD_URL}"
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
