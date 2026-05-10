# Vaultwarden Setup

Self-hosted Bitwarden-compatible password manager using [Vaultwarden](https://github.com/dani-garcia/vaultwarden).
Runs behind a [Caddy](https://caddyserver.com/) reverse proxy that handles HTTPS automatically.

## Quick start (local)

```powershell
# 1. Copy and configure environment
cp .env.example .env
# Edit .env — defaults work for local testing

# 2. Start
.\scripts\start-local.ps1

# 3. Open https://localhost in your browser
# If you see a cert warning, trust the Caddy CA:
docker exec vaultwarden-caddy caddy trust
```

Vaultwarden will be available at **https://localhost**.  
Admin panel: **https://localhost/admin** (requires ADMIN_TOKEN in .env).

## Stopping

```powershell
docker compose down          # keep data
docker compose down -v       # also delete volumes (destroys vault data)
```

## Configuration

All settings live in `.env` (copied from `.env.example`).

| Variable | Default | Notes |
|---|---|---|
| `DOMAIN` | `https://localhost` | Full URL including protocol |
| `SIGNUPS_ALLOWED` | `true` | Disable after creating your account |
| `ADMIN_TOKEN` | *(empty)* | Argon2 hash — see below |
| `LOG_LEVEL` | `info` | `warn` or `error` for production |

### Generate an admin token

```powershell
.\scripts\generate-admin-token.ps1
# or manually:
docker run --rm -it vaultwarden/server /vaultwarden hash --preset owasp
```

Paste the resulting `$argon2id$...` string as `ADMIN_TOKEN` in `.env`.

## Production (custom domain)

1. Point your domain DNS to the server's IP.
2. Set `DOMAIN=https://your.domain.com` in `.env`.
3. Make sure ports 80 and 443 are open.
4. Run `docker compose up -d` — Caddy fetches a Let's Encrypt cert automatically.

After your first login, set `SIGNUPS_ALLOWED=false` in `.env` and restart:
```powershell
docker compose up -d
```

## Restoring data from a failed installation

If you have a backup of the Vaultwarden `/data` directory:

```powershell
# Copy your backup into the Docker volume
docker run --rm -v vaultwarden-setup_vw-data:/data -v C:\path\to\backup:/backup alpine `
  sh -c "cp -av /backup/. /data/"

docker compose up -d
```

If you have a `.tar.gz` backup made by `scripts\backup.ps1`:
```powershell
docker run --rm -v vaultwarden-setup_vw-data:/data -v C:\path\to\backups:/backup alpine `
  tar xzf /backup/vaultwarden-backup-YYYY-MM-DD_HHMMSS.tar.gz -C /data
docker compose up -d
```

## Backup

```powershell
.\scripts\backup.ps1
# Saves a timestamped tar.gz to ./backups/
```

Schedule this daily with Windows Task Scheduler or a cron job.

## Kubernetes

See the `k8s/` directory for manifests. Requires:
- `nginx-ingress-controller`
- `cert-manager` with a `letsencrypt-prod` ClusterIssuer

```powershell
# 1. Edit k8s/configmap.yaml — set your DOMAIN
# 2. Copy and fill in k8s/secret.example.yaml → k8s/secret.yaml
# 3. Apply
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
```

## Architecture

```
Browser → Caddy (443/TLS) → Vaultwarden (80, internal)
                ↑
         Automatic HTTPS:
         localhost → self-signed CA (caddy trust)
         domain    → Let's Encrypt
```

Data persists in Docker named volume `vw-data`.
