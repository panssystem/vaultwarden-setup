# Vaultwarden Setup

Self-hosted Bitwarden-compatible password manager using [Vaultwarden](https://github.com/dani-garcia/vaultwarden), running behind a [Caddy](https://caddyserver.com/) reverse proxy with automatic HTTPS.

## Table of contents

- [Quick start — local](#quick-start--local)
- [Configuration](#configuration)
- [Docker Compose profiles](#docker-compose-profiles)
- [Obsidian Sync (CouchDB)](#obsidian-sync-couchdb)
- [Production — Azure deployment](#production--azure-deployment)
- [Security hardening](#security-hardening)
- [Backups](#backups)
- [Restoring from a backup](#restoring-from-a-backup)
- [Keeping images up to date](#keeping-images-up-to-date)
- [Architecture](#architecture)

---

## Quick start — local

```powershell
# 1. Copy and configure environment (defaults work for local testing)
cp .env.example .env

# 2. Start Vaultwarden + Caddy
.\scripts\start-local.ps1

# 3. Open https://localhost
# First visit: trust the Caddy self-signed CA if your browser warns:
docker exec vaultwarden-caddy caddy trust
```

**https://localhost** — web vault  
**https://localhost/admin** — admin panel (requires `ADMIN_TOKEN` in `.env`)

### Stop

```powershell
docker compose down        # keep data
docker compose down -v     # delete volumes too (destroys vault data)
```

---

## Configuration

All settings live in `.env` (copy from `.env.example`).

| Variable | Default | Notes |
|---|---|---|
| `DOMAIN` | `https://localhost` | Full URL including `https://` |
| `SIGNUPS_ALLOWED` | `true` | Set to `false` after creating your accounts |
| `ADMIN_TOKEN` | *(empty)* | Argon2id hash — see below |
| `ADMIN_ALLOWED_IP` | `127.0.0.1` | IP allowed to reach `/admin` — set to your public IP in production |
| `LOG_LEVEL` | `info` | `warn` or `error` for production |
| `TZ` | `America/Chicago` | Timezone for Fail2Ban log timestamps |
| `GROCY_DOMAIN` | `grocy.localhost` | Hostname for the Grocy household-management app |
| `OBSIDIAN_DOMAIN` | `obsidian.localhost` | Hostname for the CouchDB Obsidian LiveSync backend |
| `COUCHDB_USER` | `admin` | CouchDB admin username (used by the LiveSync plugin) |
| `COUCHDB_PASSWORD` | *(required)* | CouchDB admin password — generate with `openssl rand -base64 24` |

### Generate an admin token

```bash
docker exec -it vaultwarden /vaultwarden hash --preset owasp
```

Paste the full `$argon2id$...` string as `ADMIN_TOKEN=` in `.env`, then restart:

```bash
docker compose --profile caddy restart vaultwarden
```

---

## Docker Compose profiles

| Profile | Services | Use case |
|---|---|---|
| `caddy` | Vaultwarden + Grocy + CouchDB + Caddy + Fail2Ban | Local dev and direct-TLS production |
| `tunnel` | Vaultwarden + cloudflared + Fail2Ban | Cloudflare Tunnel (no open ports needed) |

```bash
# Local / direct-TLS production
docker compose --profile caddy up -d

# Cloudflare Tunnel (set CLOUDFLARE_TUNNEL_TOKEN in .env first)
docker compose --profile tunnel up -d
```

Caddy automatically issues a self-signed cert for `localhost` and a Let's Encrypt cert for any real domain — no extra config needed.

---

## Obsidian Sync (CouchDB)

[Obsidian Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) syncs your vault between devices via a CouchDB database running here.

### Setup

1. Set `COUCHDB_USER` and `COUCHDB_PASSWORD` in `.env` (use a strong, unique password — this database is reachable from any network).
2. Start the stack: `docker compose --profile caddy up -d`
3. In Obsidian, install the **Self-hosted LiveSync** community plugin.
4. Open the plugin settings → Remote Database configuration:
   - **URI**: `https://<OBSIDIAN_DOMAIN>`
   - **Username** / **Password**: your `COUCHDB_USER` / `COUCHDB_PASSWORD`
   - **Database name**: any name, e.g. `obsidian-vault`
5. Click **Test Database Connection**, then **Check Database Configuration** and apply any remaining suggested fixes (chunk size, etc.).
6. **First device only**: click **Check and Fix**, then **Replicate**.
7. **Every other device**: same plugin setup, then click **Fetch** on first connect.

Notes:
- CouchDB has no IP restriction (unlike `/admin`) since sync clients connect from many networks. Security relies on HTTPS + your CouchDB password — keep it strong.
- The Fauxton admin UI is reachable at `https://<OBSIDIAN_DOMAIN>/_utils` if you need to inspect databases directly.
- CORS is pre-configured for the LiveSync plugin's origins (`app://obsidian.md`, `capacitor://localhost`, `http://localhost`) on every container start. If you previously used the plugin's "Check Database Configuration → Fix" button and saw a "CORS is not allowing credentials" error (a known issue when that fix sets `cors/origins` to `*`, which browsers reject when credentials are included — [obsidian-livesync#613](https://github.com/vrtmrz/obsidian-livesync/issues/613)), pull this update and recreate the container: `docker compose --profile caddy up -d --force-recreate couchdb`.

---

## Production — Azure deployment

The `azure/` directory contains a Bicep template and deploy script that provision everything needed:

- VNet, NSG (ports 22/80/443), static public IP, NIC
- Ubuntu 24.04 LTS B1ms VM with system-assigned managed identity
- Standard_LRS Cool-tier storage account for encrypted-at-rest backups
- Role assignment granting the VM write access to the backup container

### Prerequisites

- [Azure CLI](https://aka.ms/installazurecli) installed and logged in (`az login`)
- An Azure subscription
- DNS A record for your domain pointing to the VM's public IP (after first deploy)

### Deploy

```bash
# First deploy — creates all resources and provisions the VM via cloud-init
bash azure/deploy.sh vaultwarden-rg eastus

# Re-deploy — safe to run again; adds/updates resources without touching the VM OS
bash azure/deploy.sh vaultwarden-rg eastus
```

The script:
1. Creates or updates the resource group and all Azure resources
2. Generates an SSH key pair at `~/.ssh/vaultwarden_azure` if one doesn't exist
3. Runs cloud-init on first boot to install Docker, configure the system, and install the backup cron job
4. Writes the backup storage account name to `/etc/vaultwarden-backup.conf` on the VM
5. Prints the VM IP, SSH command, and backup storage account

### After first deploy

```bash
# SSH in (cloud-init takes ~2 minutes)
ssh -i ~/.ssh/vaultwarden_azure azureuser@<VM_IP>

# Watch cloud-init progress
tail -f /var/log/cloud-init-output.log

# Configure Vaultwarden
cd /opt/vaultwarden-setup
cp .env.example .env
nano .env   # set DOMAIN, ADMIN_TOKEN, ADMIN_ALLOWED_IP, SIGNUPS_ALLOWED=false

# Start
docker compose --profile caddy up -d
```

### Customize deployment

Copy `azure/parameters.example.json` to `azure/parameters.json` and edit:

| Parameter | Default | Notes |
|---|---|---|
| `vmSize` | `Standard_B1ms` | 1 vCPU / 2 GB — sweet spot for 1–5 users (~$14/mo) |
| `osDiskSizeGB` | `30` | OS disk size |
| `allowSshFromIP` | `*` | Restrict to your public IP for best security |

---

## Security hardening

Checklist for a production deployment:

- [ ] `SIGNUPS_ALLOWED=false` in `.env` after creating your accounts
- [ ] `ADMIN_TOKEN` set to an argon2id hash (not empty)
- [ ] `ADMIN_ALLOWED_IP` set to your public IP in `.env`
- [ ] `allowSshFromIP` in `azure/parameters.json` set to your IP (not `*`)
- [ ] 2FA enabled on your Vaultwarden account (Settings → Security → Two-step login)
- [ ] Fail2Ban running — verify with:
  ```bash
  docker exec vaultwarden-fail2ban fail2ban-client status
  ```

See `fail2ban/README.md` for Fail2Ban details and Cloudflare Tunnel integration notes.

---

## Backups

### Automatic (production VM)

A daily cron job runs at **02:30 UTC** and:

1. For Vaultwarden and Grocy: creates a compacted, WAL-free SQLite snapshot using `VACUUM INTO`, then archives it plus the rest of each volume (RSA keys, attachments, sends, config — excluding `icon_cache` which is auto-regenerated)
2. For CouchDB: dumps every database's documents via `_all_docs` into JSON files and archives them (CouchDB isn't SQLite, so `VACUUM INTO` doesn't apply — an HTTP-level dump is a safe, portable snapshot of a live server)
3. Saves timestamped `.tar.gz` files to `/opt/backups/` (30-day local retention)
4. Uploads each archive to Azure Blob Storage (`vw-backups` container) using the VM's managed identity — no credentials stored anywhere

```bash
# Run a backup manually
sudo /opt/vaultwarden-backup.sh

# Check recent backups
ls -lh /opt/backups/

# View backup log
tail -f /var/log/vw-backup.log
```

The Azure storage account name is stored in `/etc/vaultwarden-backup.conf` (written by `deploy.sh`).

### Manual vault export (portability)

For a portable backup importable into any Bitwarden-compatible client, export from the web vault:

**Settings → Vault → Export vault**

Store the exported file somewhere safe and separate from the server.

---

## Keeping images up to date

A daily cron job (`scripts/check-image-updates.sh`) checks every image in `docker-compose.yml` for a newer version. It only pulls and compares — it never recreates a running container, so nothing changes on its own.

Set `NTFY_TOPIC` in `.env` to get a free push notification (via [ntfy.sh](https://ntfy.sh)) when an update is found. Without it, results just go to the log.

```bash
# Check now
bash scripts/check-image-updates.sh

# View the daily check log
tail -f /var/log/vw-image-updates.log

# Apply available updates (after reviewing release notes, especially for Vaultwarden)
docker compose --profile caddy pull
docker compose --profile caddy up -d
```

Installed automatically by `setup-server.sh` on first boot; safe to re-run any time with `sudo bash scripts/install-update-check.sh`.

---

## Restoring from a backup

```bash
# Stop Vaultwarden
docker compose down

# Restore from a local backup archive
docker run --rm \
  -v vaultwarden-setup_vw-data:/data \
  -v /opt/backups:/backup \
  alpine tar xzf /backup/vw-data-YYYY-MM-DD-HHMM.tar.gz -C /data

# Start again
docker compose --profile caddy up -d
```

To restore from Azure Blob Storage, download the archive first:

```bash
az storage blob download \
  --account-name <storage-account-name> \
  --container-name vw-backups \
  --name vw-data-YYYY-MM-DD-HHMM.tar.gz \
  --file /opt/backups/vw-data-YYYY-MM-DD-HHMM.tar.gz \
  --auth-mode login
```

### Restoring CouchDB

CouchDB backups are per-database JSON dumps (`_all_docs` output), not a volume snapshot. Restore by posting each dump back to a (new) database:

```bash
# Create the database first (if it doesn't exist)
curl -u admin:<password> -X PUT https://<OBSIDIAN_DOMAIN>/obsidian-vault

# Re-insert documents from the dump
python3 -c "import json; d=json.load(open('obsidian-vault.json')); print(json.dumps({'docs':[r['doc'] for r in d['rows']]}))" \
  | curl -u admin:<password> -X POST https://<OBSIDIAN_DOMAIN>/obsidian-vault/_bulk_docs \
      -H "Content-Type: application/json" -d @-
```

Then re-run the LiveSync plugin's **Check and Fix** / **Replicate** on each device.

---

## Architecture

```
Internet
   │
   ├─ :443 (HTTPS) ──► Caddy ──► Vaultwarden:80 (DOMAIN)
   │                     ├──► Grocy:80          (GROCY_DOMAIN)
   │                     ├──► CouchDB:5984       (OBSIDIAN_DOMAIN)
   │                     │
   │              Let's Encrypt (real domain)
   │              self-signed CA (localhost)
   │
   └─ :22 (SSH) ──► VM (restricted by NSG allowSshFromIP)

Fail2Ban monitors Vaultwarden logs and applies iptables bans
for repeated login failures (vault: 5/10min → 1hr ban,
admin: 3/10min → 24hr ban, SSH: 5 failures → 1hr ban).

Optional: replace Caddy with Cloudflare Tunnel (profile: tunnel)
— no inbound ports needed, see docs/cloudflare-setup.md.

Data: Docker named volumes (vw-data, grocy-data, couchdb-data)
Backups: daily tar.gz → /opt/backups/ + Azure Blob Storage
```
