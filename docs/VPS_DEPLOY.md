# Deploying PayLight on one VPS (Docker Compose)

_Written 2026-10-03. Replaces Railway (optional now, see `RAILWAY.md`). Tested locally: `docker build` plus `docker compose up` of the files in `deploy/`. Results: migrations applied, web healthy behind Caddy HTTPS, `/admin` returned 401 without credentials, and the worker waited for `GATEWAY_ADDRESS` as expected._

## What you'll end up with

```
One Linux server (one fixed public IPv4 ──► whitelist this with VTpass)
├── caddy    ports 80/443, automatic HTTPS certificate
├── web      Next.js site + API (internal port 3000)
├── worker   background jobs (exactly one)
├── db       Postgres 16 (not exposed to the internet)
└── migrate  runs database migrations on every start, then exits
```

A VPS keeps the same public IP for as long as the server exists, so you send **one** IP to VTpass. With Railway you had to send six.

## 1. Get a server (≈10 min)

Any Ubuntu 24.04 VPS with **2 GB RAM or more** (the web build needs it) and about 20 GB disk. Prices change, so check the provider's page:

| Provider | Typical small plan | Notes |
|---|---|---|
| Hetzner Cloud | CX22-class, roughly €4–6/mo | Cheapest reliable option; may ask for ID verification at signup |
| DigitalOcean | 2 GB droplet, roughly $12/mo | Easy signup, card or PayPal |
| Vultr / Linode | 2 GB, roughly $10–12/mo | Similar to DigitalOcean |
| Contabo | roughly €5/mo | Lots of RAM for the price; slower provisioning |
| Oracle Cloud Always Free | ARM VM, $0 | Free but signup is often rejected, and capacity is limited |

When you create the server:
- **Image:** Ubuntu 24.04.
- **Auth:** add your **SSH key**, not a password. If you don't have a key, run `ssh-keygen -t ed25519` on your laptop and paste in the contents of `~/.ssh/id_ed25519.pub`.
- Note the server's **public IPv4** (example used below: `203.0.113.7`).

## 2. Prepare the server (≈5 min)

From your laptop:

```bash
ssh root@203.0.113.7
```

On the server:

```bash
# Updates, firewall, Docker (official convenience script from get.docker.com)
apt update && apt -y upgrade
apt -y install git ufw
ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable
curl -fsSL https://get.docker.com | sh
docker compose version          # should print v2 or newer

# 2 GB swap, so the Next.js build can't run out of memory
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

Only ports 22, 80 and 443 are open. Postgres, web and worker are reachable only inside Docker's private network.

## 3. Get the code

The repo is private, so use a read-only **deploy key**:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/paylight_deploy -N ""
cat ~/.ssh/paylight_deploy.pub
```

1. Copy the printed public key.
2. In GitHub, open the repo **Settings → Deploy keys → Add deploy key**, paste it in, and leave "Allow write access" **off**.

Then:

```bash
cat >> ~/.ssh/config <<'EOF'
Host github.com
  IdentityFile ~/.ssh/paylight_deploy
EOF
git clone -b claude/compassionate-wright-ntt2sk git@github.com:Emediong-Etuk/PayLight.git /opt/paylight
cd /opt/paylight
```

Switch the branch to `main` once the PR is merged.

## 4. Domain

You have two options:
- **Your own domain:** add an **A record**, e.g. `pay.yourdomain.com → 203.0.113.7`.
- **No domain:** use `203-0-113-7.sslip.io`, which is your IP with the dots replaced by dashes. It resolves to your server automatically, and Caddy still gets a real HTTPS certificate.

## 5. Fill in the server env file

```bash
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
nano deploy/.env
```

Set at least:

| Variable | Value |
|---|---|
| `DOMAIN` | from step 4 |
| `POSTGRES_PASSWORD` | `openssl rand -hex 24` |
| `SESSION_SECRET`, `TOKEN_ENCRYPTION_KEY` | each `openssl rand -hex 32`. Back up `TOKEN_ENCRYPTION_KEY` offline: without it, stored meter tokens can't be read. |
| `ADMIN_BASIC_AUTH` | `greg:<a strong password>` |
| `ADMIN_WALLETS` | your deployment wallet address, lowercase |
| `VTPASS_API_KEY`, `VTPASS_PUBLIC_KEY`, `VTPASS_SECRET_KEY` | from the VTpass dashboard. Keep `VTPASS_BASE_URL` on sandbox until live access is approved. |
| `OPERATOR_PRIVATE_KEY`, `KEEPER_PRIVATE_KEY`, `QUOTE_SIGNER_PRIVATE_KEY` | the three **hot** keys from `cast wallet new`. **Never** your deployment/admin wallet. |
| `PUBLIC_*_ADDRESS` | the matching public addresses |
| `NEXT_PUBLIC_SUPPORT_TELEGRAM` | your support link |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALERT_CHAT_ID` | for alerts |

Leave `GATEWAY_ADDRESS`, `CASHBACK_ROUTER_ADDRESS`, `PROCESSOR_ADDRESS` and `START_BLOCK` empty until the mainnet deploy; I'll send the values.

Rules for this file:
- Type the keys directly on the server. Don't paste them into chat, and don't commit the file (it's in `.gitignore`).
- Keep comments on their own lines. Don't put a `# comment` after a value.

## 6. Start it

```bash
cd /opt/paylight
docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build
```

The first build takes about 5–10 minutes. Then check it:

```bash
docker compose -f deploy/docker-compose.yml --env-file deploy/.env ps
curl -s https://<DOMAIN>/api/config        # JSON with "chainId":196
docker compose -f deploy/docker-compose.yml --env-file deploy/.env logs -f worker
```

- **Before the gateway is deployed**, the worker logs `GATEWAY_ADDRESS is not set` and keeps restarting, and the pay page says the gateway "isn't deployed yet". **That's expected.**
- **After I send the addresses**, add them to `deploy/.env` and rerun the `up -d` command above. The rebuild is quick, and the worker starts listening.
- **Set the exchange rate** at `https://<DOMAIN>/admin`: log in with basic auth, sign in with the admin wallet, then enter the rate and spread.

To save typing, add an alias: `echo "alias plc='docker compose -f /opt/paylight/deploy/docker-compose.yml --env-file /opt/paylight/deploy/.env'" >> ~/.bashrc`. Then `plc ps`, `plc logs -f worker`, and so on.

## 7. VTpass

1. **IP whitelisting:** reply on your VTpass API-access thread (support@vtpass.com) with the server's **public IPv4**, e.g. `203.0.113.7`. To confirm what VTpass will see, run `curl -4 ifconfig.me` on the server.
2. **Callback URL** in the VTpass dashboard: `https://<DOMAIN>/api/webhooks/vtpass`

## 8. Updating

```bash
cd /opt/paylight && git pull
docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build
```

Migrations run automatically before web and worker start. Changing `NEXT_PUBLIC_SUPPORT_TELEGRAM` needs this rebuild too, because it's baked into the web build.

## 9. Backups (daily Postgres dump)

```bash
mkdir -p /opt/backups
cat > /etc/cron.daily/paylight-db <<'EOF'
#!/bin/sh
docker exec paylight-db-1 pg_dump -U paylight paylight | gzip > /opt/backups/paylight-$(date +%F).sql.gz
find /opt/backups -name 'paylight-*.sql.gz' -mtime +14 -delete
EOF
chmod +x /etc/cron.daily/paylight-db
```

Copy the dumps off the server now and then (e.g. `scp root@203.0.113.7:/opt/backups/* .`). Many providers also offer whole-server snapshots for about 20% of the plan's price.

To restore: `gunzip -c paylight-YYYY-MM-DD.sql.gz | docker exec -i paylight-db-1 psql -U paylight paylight`.

## 10. Things to keep in mind

- **Don't destroy and recreate the server.** You'd get a new IP, and VTpass would need to whitelist it again. Reboots and resizes keep the IP.
- **Run exactly one worker.** Never `--scale worker=2`.
- **Only the three hot keys live on the server.** Your deployment/admin wallet stays on your laptop (keystore) or Ledger.
- **If the server or a hot key is compromised:**
  1. Pause from `/admin`, or from your admin wallet on-chain.
  2. Rotate the keys on-chain: `grantRole` / `revokeRole` for the operator, `setQuoteSigner` for the signer.
  3. Put the new keys in `deploy/.env` and rerun `up -d`.
  Payers can always self-refund after 24h, whatever happens to the server.
- **Logs:** `plc logs --since 1h web worker`. Docker keeps them on the server.
