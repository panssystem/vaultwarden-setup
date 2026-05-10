#!/usr/bin/env pwsh
# Start Vaultwarden locally with HTTPS via Caddy (self-signed cert for localhost)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path $PSScriptRoot -Parent

# Create .env if it doesn't exist
$envFile = Join-Path $projectRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Host "Creating .env from .env.example for local use..."
    $exampleEnv = Join-Path $projectRoot ".env.example"
    Copy-Item $exampleEnv $envFile
    # Ensure DOMAIN is set to localhost for local runs
    (Get-Content $envFile) -replace '^DOMAIN=.*', 'DOMAIN=localhost' | Set-Content $envFile
    Write-Host ".env created. Edit it to customize settings."
}

Set-Location $projectRoot

Write-Host "Starting Vaultwarden + Caddy..."
docker compose up -d

Write-Host ""
Write-Host "Waiting for services to be healthy..."
$timeout = 60
$elapsed = 0
while ($elapsed -lt $timeout) {
    $status = docker compose ps --format json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $healthy = $status | ConvertFrom-Json | Where-Object { $_.Health -eq "healthy" -or $_.State -eq "running" }
        if ($healthy.Count -ge 2) { break }
    }
    Start-Sleep 3
    $elapsed += 3
}

Write-Host ""
Write-Host "Vaultwarden is running!"
Write-Host ""
Write-Host "  Web vault:   https://localhost"
Write-Host "  Admin panel: https://localhost/admin"
Write-Host ""
Write-Host "If your browser warns about the certificate, trust the Caddy local CA:"
Write-Host "  docker exec vaultwarden-caddy caddy trust"
Write-Host ""
Write-Host "To follow logs:  docker compose logs -f"
Write-Host "To stop:         docker compose down"
