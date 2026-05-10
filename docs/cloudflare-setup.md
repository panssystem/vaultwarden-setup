# Cloudflare Tunnel Setup

This guide wires Vaultwarden to the internet with zero open inbound ports.
All traffic flows: **Browser → Cloudflare Edge → encrypted tunnel → your VM**.

## Why this is more secure than opening port 443

- Your VM's IP address is never exposed to the internet
- Cloudflare absorbs DDoS attacks at the edge (free tier)
- No firewall rules needed for 80/443 — only SSH (port 22) is open
- Cloudflare's WAF can add rate limiting on top

---

## Step 1 — Create a Cloudflare account and add your domain

1. Sign up at **https://cloudflare.com** (free plan is fine)
2. Click **Add a site**, enter your domain name
3. Cloudflare will scan your existing DNS records
4. Copy the two **Cloudflare nameservers** shown (e.g. `ada.ns.cloudflare.com`)
5. Log in to your domain registrar and replace the nameservers with Cloudflare's
6. Wait for propagation (~10–30 minutes — check with `nslookup -type=NS kaosklan.net`)

---

## Step 2 — Enable Zero Trust (free)

1. In the Cloudflare dashboard, click **Zero Trust** in the left sidebar
2. If prompted, choose a team name (anything — e.g. your name). This is free.
3. Select the **Free plan**

---

## Step 3 — Create the tunnel

1. In Zero Trust, go to **Networks → Tunnels**
2. Click **Create a tunnel**
3. Choose **Cloudflared** as the connector type
4. Name it `vaultwarden` → **Save tunnel**
5. On the next screen, select **Docker** as the environment
6. You'll see a command like:
   ```
   docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token eyJ...
   ```
   **Copy the token** — it's the long string after `--token`. It looks like `eyJhIjoiMTIz...`
7. Click **Next**

---

## Step 4 — Configure the public hostname

On the **Public Hostnames** tab:

| Field | Value |
|---|---|
| Subdomain | `vault` (or whatever you prefer) |
| Domain | `kaosklan.net` |
| Type | `HTTP` |
| URL | `vaultwarden:80` |

This routes `https://vault.kaosklan.net` → through the tunnel → to the Vaultwarden container on port 80.

Click **Save tunnel**.

---

## Step 5 — Add the token to your .env

On your Azure VM, edit `/opt/vaultwarden-setup/.env`:

```bash
DOMAIN=https://vault.kaosklan.net
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiMTIz...   # paste your token here
IP_HEADER=CF-Connecting-IP
SIGNUPS_ALLOWED=true                        # set false after account creation
TZ=America/Chicago                          # your timezone
```

---

## Step 6 — Start the production stack

```bash
cd /opt/vaultwarden-setup
docker compose --profile prod up -d
docker compose ps
```

You should see three containers running:
- `vaultwarden` — Up (healthy)
- `vaultwarden-cloudflared` — Up
- `vaultwarden-fail2ban` — Up

---

## Step 7 — Verify

1. Open `https://vault.kaosklan.net` in your browser
2. You should see the Vaultwarden login page with a valid HTTPS certificate
3. Check the Cloudflare tunnel status: **Zero Trust → Networks → Tunnels** — it should show **Healthy**

---

## Step 8 — Lock down after account creation

Once you've created your account and verified everything works:

```bash
# On the Azure VM
nano /opt/vaultwarden-setup/.env
# Set: SIGNUPS_ALLOWED=false
docker compose --profile prod up -d   # picks up the change
```

---

## Optional hardening — Cloudflare WAF rate limiting

In the Cloudflare dashboard:
1. **Security → WAF → Rate Limiting Rules → Create rule**
2. Rule name: `Vaultwarden login protection`
3. When incoming requests match: `URI Path equals /api/accounts/login`
4. Then: **Block** if more than **10 requests per minute** from the same IP
5. Save

This stops brute-force attacks at Cloudflare's edge before they reach your server.

---

## Troubleshooting

**Tunnel shows "Inactive" in dashboard**
- Check cloudflared logs: `docker logs vaultwarden-cloudflared`
- Verify `CLOUDFLARE_TUNNEL_TOKEN` is set correctly in `.env`
- Ensure the VM has outbound internet access (it should by default)

**502 Bad Gateway**
- Vaultwarden isn't running: `docker compose ps`
- Check logs: `docker logs vaultwarden`

**Certificate error in browser**
- Cloudflare handles TLS — there should be no cert error
- If you see one, check that the Public Hostname URL is `http://vaultwarden:80` (not https)
