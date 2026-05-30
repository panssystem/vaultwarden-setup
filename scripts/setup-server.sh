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
# Daily backup of all service data volumes (Vaultwarden + Grocy).
# - VACUUM INTO for each SQLite database: compact, WAL-free, safe on live containers
# - tar archive of remaining volume data (RSA keys, attachments, config, etc.)
# - Local retention: 30 days in /opt/backups
# - Remote: Azure Blob Storage via VM managed identity (no credentials stored)
# Config: /etc/vaultwarden-backup.conf (written by deploy.sh)
set -euo pipefail

BACKUP_DIR=/opt/backups
TIMESTAMP=$(date +%F-%H%M)
mkdir -p "$BACKUP_DIR"

# ── backup_volume: back up one Docker volume ──────────────────────────────────
# Args:
#   $1  archive prefix   e.g. "vaultwarden" → vaultwarden-data-TIMESTAMP.tar.gz
#   $2  docker volume    e.g. "vaultwarden-setup_vw-data"
#   $3  db path in vol   e.g. "db.sqlite3" or "data/grocy.db" (relative to vol root)
#   $@  extra tar excludes (relative paths, no leading ./)
backup_volume() {
  local prefix="$1" volume="$2" db_relpath="$3"
  shift 3
  local archive="${BACKUP_DIR}/${prefix}-data-${TIMESTAMP}.tar.gz"
  local tmpdir
  tmpdir=$(mktemp -d "${BACKUP_DIR}/.tmp-${prefix}-XXXXX")

  echo "  Backing up ${prefix}..."

  # VACUUM INTO: write a compacted, WAL-free db snapshot into a mirrored path
  # inside tmpdir so it lands at the correct location when tar'd.
  mkdir -p "${tmpdir}/$(dirname "$db_relpath")"
  docker run --rm \
    -v "${volume}:/vol:ro" \
    -v "${tmpdir}:/tmp-backup" \
    alpine sh -c "apk add -q --no-cache sqlite \
      && sqlite3 /vol/${db_relpath} \"VACUUM INTO '/tmp-backup/${db_relpath}';\""

  # tar: vacuum'd db (correct relative path) + everything else from the volume,
  # excluding the live db files (replaced) and any caller-specified paths.
  docker run --rm \
    -v "${volume}:/vol:ro" \
    -v "${tmpdir}:/tmp-backup:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/${prefix}-data-${TIMESTAMP}.tar.gz" \
      -C /tmp-backup "${db_relpath}" \
      -C /vol \
      --exclude="./${db_relpath}" \
      --exclude="./${db_relpath}-wal" \
      --exclude="./${db_relpath}-shm" \
      $(printf -- '--exclude=./%s ' "$@") \
      .

  rm -rf "$tmpdir"
  echo "    ${archive} ($(du -sh "$archive" | cut -f1))"
}

# ── Vaultwarden ───────────────────────────────────────────────────────────────
backup_volume "vaultwarden" \
  "vaultwarden-setup_vw-data" \
  "db.sqlite3" \
  "icon_cache"

# ── Grocy ─────────────────────────────────────────────────────────────────────
# linuxserver/grocy stores its database at /config/data/grocy.db
backup_volume "grocy" \
  "vaultwarden-setup_grocy-data" \
  "data/grocy.db"

# ── Prune local archives older than 30 days ───────────────────────────────────
find "$BACKUP_DIR" -name "*-data-*.tar.gz" -mtime +30 -delete

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

# Upload helper: posts one archive to the blob container
upload_blob() {
  local file="$1"
  local blob_name
  blob_name=$(basename "$file")
  curl -sf -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-ms-version: 2020-04-08" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Type: application/gzip" \
    --data-binary @"${file}" \
    "https://${BACKUP_STORAGE_ACCOUNT}.blob.core.windows.net/vw-backups/${blob_name}"
  echo "  Uploaded: ${blob_name}"
}

echo "Uploading to Azure (${BACKUP_STORAGE_ACCOUNT}/vw-backups)..."
upload_blob "${BACKUP_DIR}/vaultwarden-data-${TIMESTAMP}.tar.gz"
upload_blob "${BACKUP_DIR}/grocy-data-${TIMESTAMP}.tar.gz"
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
