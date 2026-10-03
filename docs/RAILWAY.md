# Railway setup (web + worker + Postgres)

> **Optional alternative.** The primary hosting path is now a single VPS: see `VPS_DEPLOY.md`.

_Written 2026-10-03 from Railway's current docs (docs.railway.com: static-outbound-ips, monorepo, config-as-code, variables, pricing). The repo already contains `apps/web/railway.json` and `apps/worker/railway.json` with the build, start, migration and health-check commands. A clean `pnpm install --frozen-lockfile` + build was tested._

## What you'll end up with

```
Railway project "paylight"
├── Postgres       (managed database)
├── web            (Next.js site + API)      ── static outbound IPs ──► VTpass
└── worker         (background jobs, 1 copy) ── static outbound IPs ──► VTpass
```

**Cost:** static outbound IPs need the **Pro plan ($20/month, usage included up to that amount)**. Hobby ($5) has no static IPs, so it only works if VTpass confirms that IP whitelisting doesn't apply to you.

## 1. Create the project (≈10 min)

1. Sign up at https://railway.com with GitHub and **upgrade to Pro** (Account → Plans).
2. **New Project → Deploy from GitHub repo →** pick `Emediong-Etuk/PayLight`. Railway may auto-detect the pnpm monorepo and stage services. Keep only **web** (`@paylight/web`) and **worker** (`@paylight/worker`) and delete any others it suggests (`shared`, `core`, `db`).
   - If it creates one service instead, add a second one: **+ New → GitHub Repo →** same repo.
3. **+ New → Database → PostgreSQL.**
4. For **each** of web and worker, open **Settings**:
   - **Source → Branch:** `claude/compassionate-wright-ntt2sk` (or `main` once merged).
   - **Root Directory:** leave **empty** (repo root). The apps need the shared workspace packages.
   - **Config file path (Railway config file):**
     - web: `/apps/web/railway.json`
     - worker: `/apps/worker/railway.json`
   - That file sets the build command, start command, health check, and (web only) runs DB migrations before each deploy.
5. **web → Settings → Networking → Generate Domain** (e.g. `paylight-production.up.railway.app`). You can add a custom domain later.

## 2. Generate the three hot keys (on your laptop, privately)

These are server keys that hold only gas or nothing. They are **not** your deployment wallet.

```bash
cast wallet new   # run 3 times: operator, keeper, quote signer. Each prints an address + private key.
```

Each private key goes straight into Railway as a **sealed** variable (step 3). Don't save them anywhere else and never paste them into chat. Send me the three **addresses**: they go into the gateway deployment, and the operator and keeper need a little OKB.

Also generate two secrets:

```bash
openssl rand -hex 32   # SESSION_SECRET
openssl rand -hex 32   # TOKEN_ENCRYPTION_KEY (losing this makes stored meter tokens unreadable, so back it up offline)
```

## 3. Variables

**Project → Settings → Shared Variables** (used by both services):

```
CHAIN_ID=196
RPC_URL=https://rpc.xlayer.tech
RPC_URL_FALLBACK=https://xlayerrpc.okx.com
USDT0_ADDRESS=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
GATEWAY_ADDRESS=            # after the mainnet deploy (I'll send it)
CASHBACK_ROUTER_ADDRESS=    # after the mainnet deploy
PROCESSOR_ADDRESS=          # after your processor launch
CONFIRMATIONS=3
PROVIDER=vtpass
VTPASS_BASE_URL=https://sandbox.vtpass.com/api/    # switch to https://vtpass.com/api/ when live access is granted
MAX_ORDER_NGN=39000
DAILY_WALLET_CAP_NGN=80000
FLOAT_MIN_NGN=5000
NODE_ENV=production
```

Then, on **both** services → **Variables**, add references plus the secrets. Use **⋮ → Seal** on every key and secret so it can't be viewed again.

```
DATABASE_URL=${{Postgres.DATABASE_URL}}
TOKEN_ENCRYPTION_KEY=…           (sealed, same value on both)
VTPASS_API_KEY=…                 (sealed)
VTPASS_PUBLIC_KEY=PK_…           (sealed)
VTPASS_SECRET_KEY=SK_…           (sealed)
OPERATOR_PRIVATE_KEY=0x…         (sealed; both: the web relays gasless payments, the worker settles)
QUOTE_SIGNER_PRIVATE_KEY=0x…     (sealed; web only)
KEEPER_PRIVATE_KEY=0x…           (sealed; worker only)
```

**web only:**

```
SESSION_SECRET=…                 (sealed)
ADMIN_BASIC_AUTH=greg:<strong password>   (sealed)
ADMIN_WALLETS=0x<your deployment wallet, lowercase>
PUBLIC_DEPLOYER_ADDRESS=0x…
PUBLIC_TREASURY_ADDRESS=0x…
PUBLIC_OPERATOR_ADDRESS=0x…
PUBLIC_KEEPER_ADDRESS=0x…
PUBLIC_QUOTE_SIGNER_ADDRESS=0x…
NEXT_PUBLIC_SUPPORT_TELEGRAM=https://t.me/<your support handle>
```

**worker only:**

```
START_BLOCK=                     # the gateway's deployment block (I'll send it)
TELEGRAM_BOT_TOKEN=…             (sealed; from @BotFather)
TELEGRAM_ALERT_CHAT_ID=…
```

`NEXT_PUBLIC_*` values are baked in at build time, so redeploy web after changing them.

## 4. Static outbound IPs (for VTpass)

For **web** and **worker** each: **Settings → Networking → Enable Static IPs**, then **redeploy**. Railway shows **3 IPv4 addresses per service**, so 6 in total.

Send **all 6** to support@vtpass.com for whitelisting (reply on your API-access thread). Notes from Railway's docs:
- These IPs are outbound-only.
- They may be shared with other Railway customers.
- They change if you move the service to a different region, so pick the region once and leave it.

## 5. VTpass callback URL

In your VTpass dashboard, set the callback / webhook URL to:

```
https://<your-web-domain>/api/webhooks/vtpass
```

It replies `{"response":"success"}` immediately and only triggers a re-check. It never trusts the payload.

## 6. First deploy and checks

1. Deploy both services. Web runs `pnpm db:migrate` before it starts.
2. Open `https://<web-domain>/api/config` → JSON with chainId 196.
3. Worker → **Deployments → logs** should show `worker starting`. Its health check is `/health`.
4. Until `GATEWAY_ADDRESS` is set (after the mainnet deploy), the worker exits with `GATEWAY_ADDRESS is not set` and the pay page says "isn't deployed yet". That's expected.
5. Set the exchange rate at `https://<web-domain>/admin`: basic auth, then sign in with the admin wallet, then enter the rate (e.g. `1352.50`) and spread (e.g. `150`).

## 7. Things to keep in mind

- **Run exactly one worker** (`numReplicas: 1` is already in its config).
- **Postgres backups:** enable them on the Postgres service (Backups tab), daily.
- **Never** put the deployment/admin wallet's key on Railway. Only the three hot keys go there.
- **If a hot key leaks:**
  1. Pause from `/admin`.
  2. Rotate on-chain from your admin wallet: `grantRole` / `revokeRole` for the operator, `setQuoteSigner` for the signer.
  3. Replace the sealed variable and redeploy.
