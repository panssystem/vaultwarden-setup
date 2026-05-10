#!/usr/bin/env bash
# Deploy Vaultwarden infrastructure to Azure.
# Prerequisites: Azure CLI (az) installed and logged in, ssh-keygen available.
# Usage: ./azure/deploy.sh [resource-group-name] [azure-region]
set -euo pipefail

RESOURCE_GROUP="${1:-vaultwarden-rg}"
LOCATION="${2:-eastus}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Preflight checks ──────────────────────────────────────────────────────────

command -v az  >/dev/null 2>&1 || { echo "ERROR: Azure CLI not found. Install from https://aka.ms/installazurecli"; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "ERROR: ssh-keygen not found."; exit 1; }

echo "Ensuring Bicep CLI is installed..."
az bicep install 2>/dev/null || az bicep upgrade 2>/dev/null || true
echo "Bicep version: $(az bicep version 2>/dev/null || echo 'unknown')"
echo ""

echo "Checking Azure login..."
az account show --output none 2>/dev/null || { echo "Not logged in. Running 'az login'..."; az login; }

SUBSCRIPTION=$(az account show --query name -o tsv)
echo "Using subscription: $SUBSCRIPTION"
echo ""

# ── SSH key ───────────────────────────────────────────────────────────────────

SSH_KEY_PATH="$HOME/.ssh/vaultwarden_azure"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "Generating SSH key pair at $SSH_KEY_PATH ..."
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "vaultwarden-azure"
fi
SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
echo "SSH public key: ${SSH_KEY_PATH}.pub"
echo ""

# ── Parameters ────────────────────────────────────────────────────────────────

PARAMETERS_FILE="$SCRIPT_DIR/parameters.json"
if [[ ! -f "$PARAMETERS_FILE" ]]; then
  echo "parameters.json not found. Copying from example..."
  cp "$SCRIPT_DIR/parameters.example.json" "$PARAMETERS_FILE"
  echo ""
  echo ">>> Edit $PARAMETERS_FILE then re-run this script."
  echo "    At minimum set: allowSshFromIP to your public IP."
  echo "    Your public IP: $(curl -s https://api.ipify.org || echo 'unknown')"
  exit 0
fi

# ── Cloud-init script ─────────────────────────────────────────────────────────
# customData is immutable on existing VMs — ARM rejects any change to it.
# We skip the parameter on re-deployments; Bicep sets customData to null when
# cloudInitScript is empty, and ARM treats null as "leave unchanged" in
# incremental mode, so the existing cloud-init payload is preserved.

SETUP_SCRIPT="$REPO_ROOT/scripts/setup-server.sh"
CLOUD_INIT_B64=$(base64 -w 0 "$SETUP_SCRIPT")

# Read namePrefix from parameters.json (fall back to Bicep default)
NAME_PREFIX=$(python3 -c "
import json, sys
d = json.load(open('$PARAMETERS_FILE'))
print(d.get('parameters', {}).get('namePrefix', {}).get('value', 'vaultwarden'))
" 2>/dev/null || echo "vaultwarden")
VM_EXISTS=false
if az vm show --resource-group "$RESOURCE_GROUP" --name "${NAME_PREFIX}-vm" --output none 2>/dev/null; then
  VM_EXISTS=true
  echo "Existing VM detected — cloud-init will not be re-applied (immutable after first boot)."
fi

# ── Resource group ────────────────────────────────────────────────────────────

echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ── Deploy Bicep ──────────────────────────────────────────────────────────────

echo "Deploying Bicep template..."
CLOUD_INIT_ARGS=()
if [[ "$VM_EXISTS" == "false" ]]; then
  CLOUD_INIT_ARGS=(--parameters "cloudInitScript=$CLOUD_INIT_B64")
fi

DEPLOY_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters "@$PARAMETERS_FILE" \
  --parameters sshPublicKey="$SSH_PUBLIC_KEY" \
  "${CLOUD_INIT_ARGS[@]}" \
  --output json)

VM_IP=$(echo "$DEPLOY_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs']['vmPublicIP']['value'])" 2>/dev/null || echo "unknown")
VM_NAME=$(echo "$DEPLOY_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs']['vmName']['value'])" 2>/dev/null || echo "vaultwarden-vm")
PRINCIPAL_ID=$(echo "$DEPLOY_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs']['vmPrincipalId']['value'])" 2>/dev/null || echo "")
STORAGE_ACCOUNT=$(echo "$DEPLOY_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs']['backupStorageAccount']['value'])" 2>/dev/null || echo "")

# ── Write backup config to the VM ─────────────────────────────────────────────
# Cloud-init may still be running — run-command executes independently and the
# backup script reads this file at runtime, so ordering doesn't matter.

if [[ -n "$STORAGE_ACCOUNT" && -n "$VM_NAME" ]]; then
  echo "Writing backup storage config to VM..."
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "echo 'BACKUP_STORAGE_ACCOUNT=${STORAGE_ACCOUNT}' > /etc/vaultwarden-backup.conf && chmod 600 /etc/vaultwarden-backup.conf" \
    --output none
  echo "Backup config written: storage account = $STORAGE_ACCOUNT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deployment complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VM public IP :  $VM_IP"
echo "  SSH command  :  ssh -i $SSH_KEY_PATH azureuser@$VM_IP"
echo "  VM identity  :  $PRINCIPAL_ID"
echo "  Backup store :  $STORAGE_ACCOUNT (container: vw-backups)"
echo ""
echo "  Cloud-init is running in the background on the VM."
echo "  Wait ~2 minutes, then SSH in and check progress:"
echo "    tail -f /var/log/cloud-init-output.log"
echo ""
echo "  Next steps:"
echo "  1. Complete Cloudflare Tunnel setup (see docs/cloudflare-setup.md)"
echo "  2. SSH in and edit /opt/vaultwarden-setup/.env"
echo "  3. docker compose --profile prod up -d"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Save connection info locally
cat > "$REPO_ROOT/.azure-vm-info" << EOF
VM_IP=$VM_IP
VM_NAME=$VM_NAME
RESOURCE_GROUP=$RESOURCE_GROUP
SSH_KEY=$SSH_KEY_PATH
SSH_COMMAND=ssh -i $SSH_KEY_PATH azureuser@$VM_IP
PRINCIPAL_ID=$PRINCIPAL_ID
BACKUP_STORAGE_ACCOUNT=$STORAGE_ACCOUNT
EOF
echo "  Connection info saved to .azure-vm-info"
