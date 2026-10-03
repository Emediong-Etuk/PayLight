# PayLight ⚡

**Pay for Nigerian prepaid electricity with USD₮0 on X Layer.** Pick your disco, enter your meter number, see the owner's name, pay in USD₮0 (even without OKB), and get your 20-digit token on screen in seconds.

Built for the IGNIX × X Layer **TapeOut Genesis Transistor Hackathon** (window closes 2026-10-09 04:00 UTC).

## How it works

```
User (OKX Wallet browser) ──► apps/web (Next.js) ── verify meter / quote ──► VTpass
        │  pay(quote, sig) / gasless relay                      ▲  pay / requery (once per order)
        ▼                                                       │
 PayLightGateway (escrow) ── OrderPaid ──► apps/worker ─────────┘
        │  markFulfilled → treasury         │ settles / refunds, distributes cashback
        │  eval() ─► TapeOut FeeTier circuit (sets every fee tier on-chain)
        └──► CashbackRouter ──► PayLight transistors (cashback, no-sell reserve)
```

- **Escrow + refund guarantee.** USD₮0 is held until the token is delivered. Definitive provider failures are refunded automatically. If PayLight disappears, anyone can trigger `claimRefund` after 24h and the money goes back to the payer.
- **TapeOut integration.** PayLight has its own TapeOut processor (PayLight / PLIGHT, 1,000,000 transistors at 0.0001 OKB). Its **FeeTier circuit** (7 NAND gates) is evaluated on-chain on every payment to set the customer's fee tier.
- **Asset distribution through use.** Customers earn transistors as cashback from a capped (≤20%), no-sell reserve. Holding transistors lowers your fee. Protocol wallets never trade.

Docs: [research](docs/RESEARCH.md) · [decisions](docs/DECISIONS.md) · [processor parameters](docs/PROCESSOR_PARAMS.md) · [security](docs/SECURITY.md) · [tests](docs/TEST_REPORT.md) · [mainnet launch](docs/MAINNET_LAUNCH.md) · [progress](docs/PROGRESS.md)

## Repo layout

| Path | What |
|---|---|
| `packages/contracts` | Foundry: `PayLightGateway`, `CashbackRouter`, FeeTier netlist, deploy/launch scripts, 318 tests |
| `packages/shared` | Browser-safe: chain constants, ABIs (generated), EIP-712 types, bigint money math, zod schemas |
| `packages/db` | Prisma schema + migrations (Postgres) |
| `packages/core` | Server-only: VTpass + mock providers, quote engine, order state machine, encryption, alerts |
| `apps/worker` | Listener, fulfiller, settler, refunder, cashback keeper, reconciler, float/gas monitor |
| `apps/web` | Next.js app + API routes (`/pay`, `/receipt`, `/history`, `/light`, `/transparency`, `/help`, `/admin`) |

## Run locally

Prerequisites: Node 22, pnpm 10, Foundry, Postgres.

```bash
pnpm install
cp .env.example .env            # fill DATABASE_URL, SESSION_SECRET, TOKEN_ENCRYPTION_KEY; PROVIDER=mock
pnpm db:migrate
(cd packages/contracts && forge build) && pnpm abis

# local chain with mock USD₮0 + mock TapeOut + real gateway/router
anvil --chain-id 196 --block-time 1 &
cd packages/contracts && DEPLOYER_PK=... OPERATOR=... KEEPER=... QUOTE_SIGNER=... TREASURY=... USER1=... USER2=... \
  LOCAL_OUT=../../.local/addresses.json forge script script/LocalDev.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
# put the printed addresses + keys in .env, then:
pnpm worker          # terminal 1
pnpm dev             # terminal 2 → http://localhost:3000
```

## Deploy

One VPS with Docker Compose (Caddy HTTPS + web + worker + Postgres): see [`docs/VPS_DEPLOY.md`](docs/VPS_DEPLOY.md). Files: `Dockerfile`, `deploy/`. Railway is an alternative: [`docs/RAILWAY.md`](docs/RAILWAY.md).

## Tests

```bash
pnpm test:contracts                       # 294 offline Foundry tests (unit, fuzz, invariant, cross-test)
pnpm test:fork                            # 24 tests against real X Layer mainnet state (fork)
pnpm --filter @paylight/shared test       # money math + EIP-712 vector
pnpm --filter @paylight/core test         # VTpass classifier, quote engine, state machine (needs Postgres)
pnpm --filter @paylight/worker test       # end-to-end on Anvil: 7 provider scenarios (needs Postgres + Foundry)
```

## Status

Phase 0 (research) ✅ · Phase 1 (contracts) ✅ · Phase 2 (backend + web) ✅, tested locally end to end · Mainnet launch: pending (processor launch by Greg, then gateway/router deploy, then VTpass live).
