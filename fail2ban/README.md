# Fail2Ban for Vaultwarden

Fail2Ban monitors `vaultwarden.log` and bans IPs that repeatedly fail login.
It runs as part of both the `caddy` and `tunnel` Docker Compose profiles.

## Configuration layout

The container's `/config` is a named volume (`fail2ban-config`) so the image
can seed it with its full default config on first run (`fail2ban.conf`,
`jail.conf`, `filter.d/sshd.conf`, `action.d/*.conf`, etc.) and write its own
log there. `jail.local` and `filter.d/vaultwarden.conf` in this directory are
bind-mounted read-only to `/our-config` and copied into `/config/fail2ban` by
`custom-cont-init.d/10-vaultwarden-config.sh` on every container start — so
edits here take effect after `docker compose --profile caddy up -d
--force-recreate fail2ban`.

## How it works

- **5 vault login failures** in 10 minutes → IP banned for 1 hour
- **3 admin panel failures** in 10 minutes → IP banned for 24 hours
- **5 SSH failures** → IP banned for 1 hour

Bans are applied via `iptables` on the host (the container uses `network_mode: host`).

## With Cloudflare Tunnel

When using the Cloudflare Tunnel, all traffic arrives from Cloudflare's own IP
ranges — iptables bans won't block the actual attacker. Two options:

### Option A: Cloudflare Rate Limiting (recommended, no extra config)
Cloudflare's free WAF includes basic rate limiting. In your Cloudflare dashboard:
- Security → WAF → Rate Limiting Rules
- Create a rule: path `/api/accounts/login`, >10 requests/minute → Block

### Option B: Fail2Ban + Cloudflare API (blocks at the edge)
1. Create a Cloudflare API token with `Zone:Firewall Services:Edit` permission
2. Add to `.env`:
   ```
   CF_API_TOKEN=your-token-here
   CF_ZONE_ID=your-zone-id-here
   ```
3. Add the cloudflare action to `jail.local`:
   ```ini
   [vaultwarden]
   banaction = cloudflare
   ```
4. Create `action.d/cloudflare.conf` using the template from:
   https://github.com/fail2ban/fail2ban/blob/master/config/action.d/cloudflare.conf

## Check ban status

```bash
docker exec vaultwarden-fail2ban fail2ban-client status vaultwarden
docker exec vaultwarden-fail2ban fail2ban-client status vaultwarden-admin
```

## Unban an IP

```bash
docker exec vaultwarden-fail2ban fail2ban-client set vaultwarden unbanip 1.2.3.4
```
