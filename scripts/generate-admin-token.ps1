#!/usr/bin/env pwsh
# Generate an Argon2id admin token for Vaultwarden
Set-StrictMode -Version Latest

Write-Host "Generating Vaultwarden admin token..."
Write-Host ""

$password = Read-Host -Prompt "Enter your desired admin password" -AsSecureString
$plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
)

Write-Host ""
Write-Host "Running hash generator..."
$hash = docker run --rm -it vaultwarden/server /vaultwarden hash --preset owasp 2>&1
# The above is interactive; fall back to a simpler method:
$hash = docker run --rm vaultwarden/server sh -c "echo '$plainPassword' | /vaultwarden hash --preset owasp" 2>&1

Write-Host ""
Write-Host "Add this to your .env file:"
Write-Host "ADMIN_TOKEN=$hash"
Write-Host ""
Write-Host "Or update docker-compose.yml / k8s/secret.yaml with this value."
