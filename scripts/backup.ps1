#!/usr/bin/env pwsh
# Backup Vaultwarden data volume to a timestamped tar.gz in ./backups/
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path $PSScriptRoot -Parent
$backupDir = Join-Path $projectRoot "backups"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$backupFile = Join-Path $backupDir "vaultwarden-backup-$timestamp.tar.gz"

Write-Host "Backing up vaultwarden data to $backupFile ..."

# Use a temporary alpine container to tar the named volume
docker run --rm `
    -v vaultwarden-setup_vw-data:/data:ro `
    -v "${backupDir}:/backup" `
    alpine `
    tar czf "/backup/vaultwarden-backup-$timestamp.tar.gz" -C /data .

Write-Host "Backup complete: $backupFile"
