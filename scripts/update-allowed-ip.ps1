#!/usr/bin/env pwsh
# Update the Azure NSG SSH rule and Vaultwarden's ADMIN_ALLOWED_IP to your
# current public IP. Run this whenever your home/office IP changes.
#
# Requires: Azure CLI (az), logged in (az login).
#
# Usage:
#   ./scripts/update-allowed-ip.ps1                  # auto-detect current public IP
#   ./scripts/update-allowed-ip.ps1 -NewIp 1.2.3.4   # use a specific IP

param(
    [string]$NewIp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$vmInfoPath = Join-Path $repoRoot ".azure-vm-info"
$parametersPath = Join-Path $repoRoot "azure/parameters.json"

if (-not (Test-Path $vmInfoPath)) {
    throw ".azure-vm-info not found at $vmInfoPath — run azure/deploy.sh first."
}

# ── Load VM info ─────────────────────────────────────────────────────────────
$vmInfo = @{}
Get-Content $vmInfoPath | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        $vmInfo[$Matches[1]] = $Matches[2]
    }
}
$resourceGroup = $vmInfo["RESOURCE_GROUP"]
$vmName = $vmInfo["VM_NAME"]
$nsgName = ($vmName -replace '-vm$', '') + "-nsg"

if (-not $resourceGroup -or -not $vmName) {
    throw "Could not read RESOURCE_GROUP / VM_NAME from $vmInfoPath"
}

# ── Determine new IP ──────────────────────────────────────────────────────────
if (-not $NewIp) {
    Write-Host "Detecting current public IP..."
    $NewIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
}
Write-Host "Using IP: $NewIp"
Write-Host ""

# ── 1. Update NSG SSH rule ───────────────────────────────────────────────────
Write-Host "Updating NSG rule 'AllowSSH' on '$nsgName'..."
az network nsg rule update `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name AllowSSH `
    --source-address-prefixes "$NewIp/32" `
    --output none

# ── 2. Update ADMIN_ALLOWED_IP in .env on the VM and reload Caddy ────────────
# Uses the Azure VM agent control-plane channel, so it works even if the NSG
# currently blocks this IP.
Write-Host "Updating ADMIN_ALLOWED_IP in .env on the VM..."
$script = "sed -i 's/^ADMIN_ALLOWED_IP=.*/ADMIN_ALLOWED_IP=$NewIp/' /opt/vaultwarden-setup/.env && cd /opt/vaultwarden-setup && docker compose --profile caddy up -d caddy"
az vm run-command invoke `
    --resource-group $resourceGroup `
    --name $vmName `
    --command-id RunShellScript `
    --scripts $script `
    --output none

# ── 3. Keep parameters.json in sync for future deploys ───────────────────────
if (Test-Path $parametersPath) {
    Write-Host "Updating azure/parameters.json (allowSshFromIP)..."
    $params = Get-Content $parametersPath -Raw | ConvertFrom-Json
    $params.parameters.allowSshFromIP.value = $NewIp
    $params | ConvertTo-Json -Depth 10 | Set-Content $parametersPath
}

Write-Host ""
Write-Host "Done. SSH and the /admin panel are now allowed from $NewIp."
