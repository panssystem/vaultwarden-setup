#!/usr/bin/env bash
# Cloud-init compatible setup script — runs once on first boot of the Azure VM.
# Installs Docker, clones the repo, and configures automatic OS updates.
# This script is base64-encoded and passed to the VM via the Bicep customData field.
set -euo pipefail

echo "==> [1/5] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -y -q

echo "==> [2/5] Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

# Allow the default user to run docker without sudo
ADMIN_USER=$(getent passwd 1000 | cut -d: -f1 || echo "azureuser")
usermod -aG docker "$ADMIN_USER"

echo "==> [3/5] Configuring automatic security updates..."
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades-vw << 'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> [4/5] Cloning vaultwarden-setup repo..."
REPO_DIR="/opt/vaultwarden-setup"
git clone https://github.com/YOUR_GITHUB_USERNAME/vaultwarden-setup.git "$REPO_DIR" || {
  # If repo isn't public yet, create the directory and rsync files manually
  mkdir -p "$REPO_DIR"
  echo "NOTE: Repo not cloned — copy files manually or push to GitHub and re-run."
}
chown -R "$ADMIN_USER:$ADMIN_USER" "$REPO_DIR"

echo "==> [5/5] Configuring Docker log rotation..."
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

echo ""
echo "==> Setup complete!"
echo "    Next steps:"
echo "    1. SSH into the VM: ssh azureuser@<VM_PUBLIC_IP>"
echo "    2. cd $REPO_DIR"
echo "    3. cp .env.example .env && nano .env   (fill in DOMAIN, CLOUDFLARE_TUNNEL_TOKEN, etc.)"
echo "    4. docker compose --profile prod up -d"
