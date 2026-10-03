# PayLight — Complete Build Brief for Claude Code

> **How to use this file:** put it in an empty folder as `BUILD_BRIEF.md`, open Claude Code in that folder, and say:
> *"Read BUILD_BRIEF.md end to end, then start Phase 0. Stop at every checkpoint."*

> **Note (2026-10-03):** Phase 0 found several places where this brief conflicts with the TapeOut and IGNIX docs and with on-chain reality. Per rule 4 the docs win. See `docs/DECISIONS.md` (conflict log at the bottom) and `docs/RESEARCH.md`. The brief is kept verbatim below as the original spec.

---

## 0. Your role and working rules

You are the lead engineer building **PayLight** end to end for the **IGNIX × X Layer "TapeOut Genesis Transistor Hackathon"**. The owner is **Greg**, a backend engineer (Next.js/TypeScript, PHP/Laravel) based in Nigeria. You build; Greg approves anything involving money, keys, token parameters, or mainnet.

Follow these rules for the whole project:

1. **Never invent on-chain facts.** Contract addresses, ABIs, function names, chain parameters, API endpoints and token decimals must come from an official source you actually read in this session (docs, verified explorer source, official repo). If you can't verify something, write `TODO(verify)` and ask. Record every source URL in `docs/SOURCES.md`.
2. **No mainnet transactions without Greg typing an explicit "yes, run it".** Prefer printing the exact command for Greg to run himself. Testnet and local forks are fine.
3. **Secrets never touch git.** Only `.env.example` is committed. Never print a private key. Use a Foundry keystore (`cast wallet import`) or `--ledger` for deployments.
4. **Docs beat this brief.** This brief was written before the TapeOut factory mechanics were fully documented. If IGNIX/TapeOut docs contradict anything here, follow the docs and log the conflict in `docs/DECISIONS.md`.
5. **Phases and checkpoints.** Work phase by phase. At each `CHECKPOINT`, summarise what's done, what's verified, what's open, then wait for Greg.
6. **Small commits, clear messages.** Keep `docs/PROGRESS.md` updated with a dated log.
7. **Tests gate mainnet.** Nothing gets deployed to mainnet with failing or missing tests on money-moving paths.
8. **Prioritise shipping.** The hackathon deadline is fixed. Build the MUST list first (Section 15), then SHOULD, then COULD.

---

## 1. The product in one paragraph

**PayLight lets Nigerians pay for prepaid electricity directly from their crypto wallet on X Layer.** Many Nigerians earn in USDT (freelancers, remote workers, creators, airdrop farmers) but must first sell on P2P, wait for naira, and risk scams or frozen bank accounts just to buy "light." With PayLight, the user picks their distribution company (disco), enters their meter number, sees the meter owner's name for confirmation, pays in **USD₮0 on X Layer**, and gets the **20-digit meter token** on screen in seconds. A small service fee is charged; part of it automatically buys the project's TapeOut asset (**$LIGHT**, working name) and sends it to the payer as cashback, so the asset ends up held by real customers and every buy is traceable to a real electricity purchase.

**Target users:** Nigerian crypto earners with an OKX Wallet or any EVM wallet, starting with Greg's West African crypto community.

**The one demo moment that matters:** pay ₦1,000 in USD₮0 for a real meter on camera, type the token into the meter, and show the units load.

---

## 2. Hackathon requirements (source: https://ignix.bot/x_campaign)

### 2.1 Hard requirements
- The processor must be deployed on **X Layer** through the **TapeOut factory**.
- **Transistor supply, unit price and any cap** must be set and **publicly disclosed at deployment**.
- **At least one circuit** must be taped out on the processor before the window closes. Circuits can be our own or taped out by anyone on our processor. What counts is that the processor is real and used.
- **Mainnet launch is required.**
- Submit: **processor contract address, deployment wallet, product demo, project description.** Submission form: https://docs.google.com/forms/d/e/1FAIpQLSd7USjG6LUNNRxwFWY4YEuSY0V0xv8VZNCl6z_-lGSl96vWZA/viewform

### 2.2 Judging criteria and how PayLight answers each

| Criterion | PayLight's answer |
|---|---|
| Application innovation | Crypto → physical electricity in a Nigerian home, no P2P off-ramp |
| Depth of TapeOut integration | Processor asset is wired into the payment flow (cashback buys, holder fee tiers); our gateway/cashback contract is the circuit (confirm in Phase 0) |
| Product completeness & UX | Mobile-first, 4 steps, meter-name confirmation, token on screen, receipts, history, refunds |
| Asset issuance design | Fixed, disclosed supply; distribution to real paying customers via revenue-funded cashback; protocol wallets are buy-only |
| X Layer integration | USD₮0 payments, OKB gas, on-chain order lifecycle, verified contracts, public transparency page |
| User growth potential | Weekly repeat purchase (electricity), Greg's community as launch distribution, obvious expansion to data/airtime/TV |
| Contract security & economic model | Signed quotes, escrowed orders, user self-refund after timeout, caps, pause, invariant tests, no-sell cashback contract |

### 2.3 Disqualifiers — design to make these impossible
Wash trading, matched orders, self-trading and any fake trading void eligibility. The event does **not** judge on volume or price alone. Therefore:
- Protocol and deployer wallets **never sell** the asset. The cashback contract has **no sell path** at all.
- No team-controlled wallet buys the asset except the cashback contract, and every cashback buy is linked on-chain to the order IDs that funded it.
- All team and protocol wallets are listed publicly on the `/transparency` page.

---

## 3. PHASE 0 — Discovery (no application code yet)

### 3.1 Read all of these fully
IGNIX / TapeOut (fetch each; follow links to any TapeOut-specific pages you find):
- https://ignix.bot/docs
- https://ignix.bot/docs/getting-started
- https://ignix.bot/docs/vault
- https://ignix.bot/docs/tax-and-dividends
- https://ignix.bot/docs/bonding-curve
- https://ignix.bot/docs/risks
- https://ignix.bot/docs/vault-templates
- https://ignix.bot/docs/launching-a-token
- https://ignix.bot/docs/fees-and-creator-income
- https://ignix.bot/docs/agent-verification
- https://ignix.bot/docs/developers/token-types
- https://ignix.bot/docs/developers/curve-trading
- https://ignix.bot/docs/developers/events
- https://ignix.bot/docs/developers/token-metadata
- https://ignix.bot/docs/developers/http-api
- https://ignix.bot/docs/developers/addresses
- https://ignix.bot/docs/dashboard
- https://ignix.bot/docs/verifiability
- https://ignix.bot/docs/faq
- https://ignix.bot/store
- https://ignix.bot/launchpad
- https://ignix.bot/create
- https://ignix.bot/skymap
- https://ignix.bot/x_campaign

X Layer: official X Layer developer docs (network params, RPC, explorer, contract verification, testnet + faucet, USD₮0 address).

Bill provider: VTpass API docs (default provider). If VTpass is unsuitable, evaluate one alternative Nigerian bill-payment API and explain why.

### 3.2 Write `docs/RESEARCH.md` answering every question below, with source links

**TapeOut / IGNIX**
1. What exactly is a *processor* on-chain? Contract type, standard (ERC-20?), who owns it, what's immutable.
2. What is a *transistor*? Is it the token unit of the processor?
3. TapeOut **factory address on X Layer mainnet** and its ABI (from the Deployments page or a verified explorer source). Never guess this.
4. How are transistor **supply, unit price and cap** set? Which are immutable after deployment? Is pricing a bonding curve, fixed price, or something else?
5. What is a *circuit*, and how is one *taped out*? Is it a contract we deploy and register, a factory call, an NFT, a vault? Who can tape out, and what does it cost?
6. Can PayLight's own contract (gateway or cashback router) be registered as the circuit? If not, what is the smallest meaningful circuit for PayLight?
7. Quote-token options for a processor. **Prefer USD₮0** (payments are in USD₮0, so cashback buys need no extra swap). If only OKB is possible, design a USD₮0→OKB swap step and note the extra risk.
8. How is the asset bought programmatically? Function signatures, slippage/min-out parameters, deadlines, router addresses, before and after graduation (Uniswap).
9. Buy/sell taxes and vault options for TapeOut assets. Do tokens held by a contract accrue dividends? (This affects the cashback contract's holdings.)
10. Events emitted and the HTTP API, for indexing stats on our transparency page.
11. Do Agent linking, Founder Round or Buyback Escrow apply to TapeOut assets? (Stretch only.)
12. Is the name/ticker **LIGHT / PayLight** free on IGNIX? If taken, propose three alternatives.

**X Layer**
13. Mainnet chainId (campaign page states 196 — confirm), RPC URLs, explorer, verification method for Foundry, typical block time and a safe confirmation count.
14. Testnet chainId, RPC, faucet.
15. **USD₮0 contract address on X Layer, decimals, and whether it supports EIP-2612 `permit`.** (Never hardcode from memory.)

**Bill provider (VTpass)**
16. Sandbox and live base URLs, auth headers for GET and POST.
17. Endpoints for: meter verification, payment, requery, wallet balance. Webhook support, if any.
18. `request_id` format rules. (Hint, verify: it must start with the current date-time in Africa/Lagos time, `YYYYMMDDHHmm`, followed by a unique suffix.)
19. Electricity `serviceID` list for all discos, the prepaid variation code, min/max amounts, response codes, transaction statuses (delivered/pending/failed), and where the meter token and units appear in the response.
20. Sandbox test meter numbers and how to simulate success, pending and failure.
21. Live-account approval requirements and timeline. **Flag this to Greg immediately** — it's the slowest external dependency.

### 3.3 Also produce in Phase 0
- `docs/DECISIONS.md` — architecture decisions, especially how the circuit requirement is satisfied.
- A proposed **processor parameter sheet** (supply, unit price, cap, quote token, vault, any creator allocation) with rationale, for Greg to approve.
- A list of everything **only Greg can do** (accounts, KYC, funding, mainnet signing, asking the IGNIX team in https://t.me/IGNIXOfficial).

### >>> CHECKPOINT 0
Present a summary, the open questions, and the parameter sheet. Wait for Greg.

---

## 4. Architecture

### 4.1 Overview

```
 User (phone, OKX Wallet browser / any EVM wallet)
   │
   ▼
 apps/web  (Next.js)  ── meter verify / quote ──►  BillProvider (VTpass)
   │   ▲                                            ▲
   │   │ order status (poll / SSE)                  │ pay / requery
   │   │                                            │
   │  Postgres (Prisma) ◄──────────── apps/worker ──┘
   │                                   │  ▲
   │ pay(orderId, signed quote)        │  │ OrderPaid events
   ▼                                   ▼  │
 PayLightGateway (X Layer) ──fee share──► CashbackRouter ──buy──► TapeOut processor asset ($LIGHT)
   │        markFulfilled / refund (operator)          │
   └──► Treasury (USD₮0)                               └──► $LIGHT cashback to payers
```

### 4.2 Repo layout (pnpm workspaces)

```
paylight/
  apps/
    web/              Next.js (App Router) + TypeScript + Tailwind + wagmi/viem
    worker/           Node + TypeScript long-running process (listener, fulfiller, keeper, reconciler)
  packages/
    contracts/        Foundry project (Solidity ^0.8.24, OpenZeppelin v5)
    db/               Prisma schema + client
    shared/           zod schemas, types, constants, generated ABIs, formatters
  docs/
    RESEARCH.md  DECISIONS.md  SOURCES.md  PROGRESS.md  SECURITY.md  DEMO_SCRIPT.md
  deployments/        <chainId>.json with every deployed address + tx hash
  .env.example
  README.md
```

### 4.3 Stack
- **Contracts:** Foundry, OpenZeppelin v5 (`SafeERC20`, `ReentrancyGuard`, `Pausable`, `AccessControl`, `EIP712`, `ECDSA`).
- **Web:** Next.js App Router, TypeScript strict, Tailwind, wagmi + viem, a wallet modal that works well inside the OKX Wallet in-app browser (injected connector first; WalletConnect as fallback).
- **Auth:** Sign-In with Ethereum (SIWE) session cookie for history and full receipts.
- **DB:** Postgres + Prisma.
- **Worker:** plain Node/TS process with a DB-backed job table (no Redis needed for MVP).
- **Validation:** zod on every API input.
- **Hosting:** web on Vercel; worker + Postgres on Railway, Render or Fly.io.
- **Testing:** Foundry (unit, fuzz, invariant), Vitest for TS, Playwright for one happy-path E2E.

---

## 5. Smart contracts

### 5.1 `PayLightGateway.sol`

**Purpose:** escrow each order's USD₮0 until the electricity is delivered, then settle or refund. Users are protected by a timeout self-refund. No meter numbers, names or tokens ever go on-chain.

**Roles**
- `DEFAULT_ADMIN_ROLE` — Greg's multisig or hardware wallet. Can set bounded parameters, pause, and manage roles.
- `OPERATOR_ROLE` — worker hot wallet. Can `markFulfilled` and `refund`. Cannot withdraw anything else.
- `QUOTE_SIGNER` — an address stored in state (not a role) whose EIP-712 signatures authorise quotes. Its key lives only in the backend.

**Storage**
```solidity
enum Status { None, Paid, Fulfilled, Refunded }

struct Order {
    address payer;
    uint128 amount;      // total USD₮0 pulled, fee included
    uint128 fee;         // service fee portion
    uint64  paidAt;
    Status  status;
}

mapping(bytes32 => Order) public orders;
IERC20  public immutable usdt0;
address public treasury;
address public cashbackRouter;
address public quoteSigner;
uint16  public cashbackShareBps;     // share of fee sent to cashback, e.g. 5000 = 50%
uint128 public maxOrderAmount;       // pilot cap per order
uint128 public dailyVolumeCap;       // pilot cap per UTC day
uint64  public refundTimeout;        // e.g. 24 hours
uint256 public totalPending;         // sum of amounts in Paid status
```

**Functions**
- `pay(bytes32 orderId, uint128 amount, uint128 fee, uint64 quoteExpiry, bytes sig)` — `whenNotPaused`, `nonReentrant`.
  - Requires: `orders[orderId].status == None`, `block.timestamp <= quoteExpiry`, `amount <= maxOrderAmount`, `fee < amount`, daily cap not exceeded, and a valid EIP-712 signature by `quoteSigner` over `Quote(orderId, payer=msg.sender, amount, fee, quoteExpiry)`.
  - Pulls `amount` with `safeTransferFrom`, records the order, increments `totalPending`, emits `OrderPaid(orderId, payer, amount, fee)`.
- `payWithPermit(...)` — same as above but takes EIP-2612 permit params. **Only implement if Phase 0 confirms USD₮0 supports permit.**
- `markFulfilled(bytes32 orderId, bytes32 receiptHash)` — `onlyRole(OPERATOR_ROLE)`.
  - `Paid → Fulfilled`. Sends `amount - fee` plus the non-cashback part of `fee` to `treasury`, and the cashback part to `cashbackRouter` via `CashbackRouter.credit(payer, cashbackAmount)`.
  - `receiptHash = keccak256(provider transaction ID)` — never the meter token.
  - Emits `OrderFulfilled(orderId, receiptHash, cashbackAmount)`.
- `refund(bytes32 orderId)` — `onlyRole(OPERATOR_ROLE)`. `Paid → Refunded`, returns the full `amount` to the payer, emits `OrderRefunded(orderId, byOperator=true)`.
- `claimRefund(bytes32 orderId)` — callable only by the payer, only if status is `Paid` and `block.timestamp > paidAt + refundTimeout`. Full refund. Emits `OrderRefunded(orderId, byOperator=false)`. This is the trust-minimising guarantee: if PayLight disappears, users get their money back.
- Admin setters with **hard bounds** and events: `setTreasury`, `setQuoteSigner`, `setCashbackRouter`, `setCashbackShareBps` (≤ 10000), `setMaxOrderAmount`, `setDailyVolumeCap`, `setRefundTimeout` (between 1h and 72h).
- `pause` / `unpause`. While paused, `pay` is blocked, but `refund` and `claimRefund` keep working.
- `rescueToken(token, to, amount)` — admin only, and for USD₮0 only the excess above `totalPending` can be rescued.

**Invariant:** `usdt0.balanceOf(gateway) >= totalPending` at all times.

### 5.2 `CashbackRouter.sol` (the "circuit" candidate — confirm in Phase 0)

**Purpose:** collect the cashback share of fees and periodically buy the processor asset, distributing it pro-rata to the payers who funded it.

- `credit(address user, uint256 amount)` — only callable by the gateway. Adds to `owed[user]` and `pendingTotal`.
- `executeBatch(address[] users, uint256 minAssetOut, uint256 deadline)` — `onlyRole(KEEPER_ROLE)`, `nonReentrant`.
  - Sums `owed[u]` for the listed users and zeroes them.
  - Buys the processor asset through an `IAssetAcquirer` adapter, enforcing `minAssetOut`.
  - Transfers each user their pro-rata share; rounding dust stays in the contract and rolls into the next batch.
  - Emits `CashbackBatch(batchId, users.length, quoteIn, assetOut)` plus `CashbackPaid(batchId, user, assetAmount)` per user.
- **No function can sell, swap out of, or arbitrarily transfer the asset.** The only outbound transfers are pro-rata distributions inside `executeBatch`. State this in NatSpec and in `docs/SECURITY.md`; judges will read it.
- `IAssetAcquirer` interface: `buy(uint256 quoteIn, uint256 minOut, uint256 deadline) returns (uint256 assetOut)`. Implement the concrete adapter **only after Phase 0** confirms how TapeOut purchases work (curve function vs router; before vs after graduation). If the quote token is not USD₮0, the adapter performs the swap first and enforces min-out on both legs.
- Batch policy (worker side): run when pending cashback ≥ a threshold or every 6 hours, whichever comes first, to avoid hundreds of dust buys.

### 5.3 Holder fee tiers (off-chain logic, on-chain enforcement)
At quote time the backend reads the payer's processor-asset balance and sets the fee (example: 1.0% default, 0.5% at tier 1, 0% at tier 2). The fee is part of the signed quote, so the contract enforces whatever the signer approved. Tier thresholds live in config and are published on the `/light` page.

### 5.4 Contract tests (all required before mainnet)
- Unit: every function, every revert path, every role check, every event.
- Signature: wrong signer, wrong payer, expired quote, replayed orderId, mismatched amount/fee, wrong chainId domain.
- Refunds: operator refund, self-refund before/after timeout, refund while paused, double refund, refund after fulfilment.
- Caps: per-order and daily cap, including the day rollover.
- Cashback: pro-rata math with uneven amounts, dust carry-over, `minAssetOut` enforced, zero-user batch, only gateway can credit.
- **Fuzz:** amounts, fees, timestamps.
- **Invariant:** `balanceOf(gateway) >= totalPending`; no order transitions out of `Fulfilled` or `Refunded`; cashback router asset balance only decreases via `executeBatch`.
- Run Slither (or Aderyn) and resolve or document every finding in `docs/SECURITY.md`.

### 5.5 Deployment scripts
- `script/Deploy.s.sol` deploys gateway + router (+ adapter once known), wires roles, sets pilot caps, and writes `deployments/<chainId>.json` (addresses, tx hashes, block numbers, constructor args).
- Verify all contracts on the X Layer explorer using the method found in Phase 0.
- Generate typed ABIs into `packages/shared` (e.g. wagmi CLI) so web and worker never hand-copy ABIs.

### >>> CHECKPOINT 1
Contracts complete, tests and fuzzing green, Slither report reviewed, testnet deployment verified. Wait for Greg.

---

## 6. Backend (apps/web API routes + apps/worker)

### 6.1 Order state machine (single source of truth in Postgres)

```
QUOTED ──(user pays on-chain)──► PAID ──► PROVIDER_PENDING ──► DELIVERED ──► SETTLED
   │                                │              │                │
   └─► EXPIRED (no payment)         │              ├─► PROVIDER_FAILED ──► REFUNDING ──► REFUNDED
                                    │              └─► NEEDS_REVIEW (status unknown after max requeries)
                                    └─► UNDERPAID/MISMATCH ──► REFUNDING ──► REFUNDED
```
- `DELIVERED` = provider returned a meter token. `SETTLED` = `markFulfilled` confirmed on-chain.
- Every transition is written with a timestamp and reason to an `OrderEvent` table.

### 6.2 Critical failure rules — read twice
1. **Never call the provider's pay endpoint twice for the same order.** One order → one `request_id`, stored before the call. On timeout or network error, **requery**; never re-pay.
2. **Never auto-refund when the provider status is unknown.** Unknown → requery with backoff (e.g. 10s, 30s, 1m, 2m, 5m, 10m). Still unknown → `NEEDS_REVIEW` and alert Greg. Auto-refund only on a definitive provider failure.
3. **Deliver first, settle second.** Show the token to the user as soon as the provider delivers; `markFulfilled` follows. If `markFulfilled` fails, retry. The `refundTimeout` (24h) must be far longer than the worst-case settle delay.
4. **Don't take money you can't fulfil.** If the provider wallet float is below threshold, the quote endpoint returns "temporarily unavailable" and the UI says so.
5. **Event processing is idempotent.** Re-processing the same `OrderPaid` event must be a no-op. Track the last processed block, re-scan with an overlap window, and require N confirmations (from Phase 0).

### 6.3 API routes (Next.js route handlers, all zod-validated)
| Route | Purpose |
|---|---|
| `GET /api/discos` | Supported discos (display name, serviceID, min/max amount) |
| `POST /api/meter/verify` | `{serviceID, meterNumber, meterType}` → `{customerName, addressMasked}`. Requires a connected wallet address. Rate-limited per wallet and IP (stops meter-owner lookups at scale). |
| `POST /api/quote` | `{serviceID, meterNumber, amountNgn, phone?, payer}` → `{orderId, amountUsdt0, feeUsdt0, rate, expiry, signature, cashbackEstimate}`. Re-verifies the meter, checks float, caps and fee tier. |
| `GET /api/orders/:id` | Public: status + tx links. Owner with SIWE session: also the meter token and units. |
| `GET /api/orders` | SIWE: the user's history |
| `POST /api/auth/siwe/*` | nonce, verify, logout |
| `GET /api/stats` | Totals for landing and transparency pages (bills paid, ₦ delivered, unique payers, cashback batches) |
| `/api/admin/*` | Basic-auth + allowlisted wallet: orders, retry requery, operator refund, set rate/spread, pause quotes, float status |

### 6.4 Quote engine
- `RateProvider` interface. Default: **admin-set NGN/USD₮0 rate plus a configurable spread**, editable from `/admin`. Optional: an external rate source as a sanity check — if the admin rate deviates more than X% from it, block quotes and alert.
- Quote TTL: 120 seconds. Each quote gets a random `bytes32 orderId`.
- `amountUsdt0 = ceil((amountNgn / rate) * 10^decimals)`; `fee = ceil(amountUsdt0 * feeBps / 10000)`; total = both. Use bigint math only, never floats for money.
- Signature: EIP-712 typed data matching `PayLightGateway` exactly (domain name, version, chainId, verifyingContract). Write a cross-test that signs in TypeScript and verifies in Foundry.

### 6.5 Bill provider integration
- `BillProvider` interface: `listDiscos()`, `verifyMeter()`, `purchase()`, `requery()`, `getWalletBalance()`.
- Implement `VtpassProvider` against the exact endpoints found in Phase 0. Keep sandbox and live behind the same interface via env.
- Generate `request_id` per the provider's rules (Lagos time prefix + unique suffix) and persist it **before** calling `purchase`.
- Parse and store: provider transaction ID, status, meter token, units, and the raw response (JSON, for disputes).
- Add a `MockProvider` for local development and tests that can simulate success, pending→success, pending→fail, hard fail and timeout.

### 6.6 Worker jobs (apps/worker)
1. **Chain listener** — watch `OrderPaid`, `OrderFulfilled`, `OrderRefunded`, `CashbackBatch`. Persist the last processed block; backfill on restart.
2. **Fulfiller** — for each new PAID order: validate it against the DB quote (payer, amount, fee) → `purchase()` → store result → `markFulfilled` on success, `refund` on definitive failure → requery loop otherwise.
3. **Settler** — retries `markFulfilled` for DELIVERED orders not yet SETTLED.
4. **Cashback keeper** — when the threshold or interval is hit, call `executeBatch` with a `minAssetOut` computed from a fresh price read minus slippage tolerance.
5. **Reconciler (every 10 min)** — compare on-chain order states with the DB; anything mismatched → `NEEDS_REVIEW` + alert.
6. **Float monitor (every 5 min)** — provider wallet balance and operator OKB gas balance; below threshold → disable quotes + alert.
7. **Alerts** — send to a private Telegram chat via bot token (NEEDS_REVIEW, low float, low gas, failed settle, reconciler mismatch).

### 6.7 Notifications to users
- MUST: status updates in the UI (polling every 2s or SSE).
- COULD: SMS of the meter token via a Nigerian SMS API (e.g. Termii) if the user opts in with a phone number.

---

## 7. Database (Prisma) — minimum models

- `Quote` — orderId, payer, serviceID, meterNumber, meterType, customerName, amountNgn, rate, amountUsdt0, feeUsdt0, feeTier, expiry, signature, createdAt.
- `Order` — orderId (PK), status, payer, txHashPaid, blockPaid, providerRequestId (unique), providerTxId, providerStatus, meterTokenEncrypted, units, providerRaw (JSON), txHashSettled, txHashRefund, timestamps.
- `OrderEvent` — orderId, from, to, reason, createdAt.
- `CashbackBatch` — batchId, txHash, usersCount, quoteIn, assetOut, orderIds (JSON), createdAt.
- `ChainCursor` — name, lastBlock.
- `Config` — key/value for rate, spread, fee tiers, thresholds (audited: who changed what, when).
- `AdminAudit` — actor, action, payload, createdAt.

Privacy: encrypt meter tokens at rest (AES-256-GCM, key from env). Never log full meter numbers or tokens; mask them in logs. Never put meter data on-chain.

---

## 8. Frontend (apps/web)

### 8.1 UX principles
- **Mobile-first**, tested at 360px width, inside the OKX Wallet in-app browser on a low-end Android.
- Plain, friendly Nigerian English. No crypto jargon on the main path. "Pay for light with USDT" beats "On-chain utility settlement."
- Large tap targets, high contrast, light and dark mode, naira formatted with `en-NG` (₦5,000).
- Every money step shows exactly what the user pays, in both ₦ and USD₮0, before they sign.
- Leave a clear slot for a custom logo and hero illustration (Greg will supply original artwork).

### 8.2 Pages
1. **`/` Landing** — headline, 3-step "how it works", live stats from `/api/stats`, CTA "Buy light now", short FAQ, links to `/light` and `/transparency`.
2. **`/pay` — the core flow (4 steps, one screen each)**
   - **Step 1 — Meter:** searchable disco picker, meter number input (numeric keyboard), prepaid selected by default, amount presets (₦1,000 / ₦2,000 / ₦5,000 / ₦10,000) plus custom, optional phone.
   - **Step 2 — Confirm:** "This meter belongs to **JOHN D***E**, Rumuola, PH." Buttons: "Yes, that's me / my meter" or "Go back."
   - **Step 3 — Pay:** quote card (₦ amount, rate, fee, total USD₮0, $LIGHT cashback estimate), countdown, connect wallet, then approve exact amount + pay (or a single permit+pay if supported). Clear error states: wrong network (one-tap switch to X Layer), insufficient USD₮0, insufficient OKB for gas (link to `/help`), quote expired (one-tap refresh).
   - **Step 4 — Your token:** live status ("Payment received" → "Buying your units" → "Done"), then the **20-digit token in groups of 4** in a huge font, one-tap copy, units, receipt link, explorer link, "Buy again" button. If something fails: honest message + refund status + support link.
3. **`/receipt/[orderId]`** — public view shows status and tx links only; owner (SIWE) also sees the token.
4. **`/history`** — SIWE-gated list of past purchases with quick "Buy again for this meter".
5. **`/light`** — the processor asset page: what $LIGHT is (cashback, holder fee tiers), **supply, unit price, cap, quote token, vault, contract addresses, deployment wallet**, link to the asset on IGNIX. Include a plain disclaimer: cashback reward, not an investment, no promise of value.
6. **`/transparency`** — every contract and team/protocol wallet with explorer links; the no-sell policy; table of cashback batches with linked order counts; totals (orders, unique payers, ₦ delivered, USD₮0 processed). Pull figures from chain events, not hand-entered numbers.
7. **`/help`** — how to get USD₮0 and a little OKB onto X Layer (e.g. withdrawing from an exchange directly to X Layer — verify the steps in Phase 0), supported discos, refund policy (including the 24h self-refund button for stuck orders), Telegram support link.
8. **`/admin`** — protected: orders table with filters, order detail with event log, requery, operator refund, rate/spread editor, fee tiers, pause quotes, float and gas balances.

### 8.3 Self-refund UI
On any order still `Paid` after the timeout, show a "Claim refund" button that calls `claimRefund` directly from the user's wallet — works even if the PayLight backend is down.

---

## 9. Processor / asset issuance design

### 9.1 Principles (finalise numbers after Phase 0, with Greg's approval)
- **Fixed, disclosed supply.** No hidden allocations. If the factory allows a creator allocation, use zero or a small amount that is disclosed and, ideally, locked.
- **Unit price and cap set at deployment and published** in three places: the deployment tx, the `/light` page, and a pinned X post.
- **Quote token: USD₮0** if allowed (one currency end to end).
- **Distribution through use:** the main buyer of the asset is the cashback contract, funded only by real service fees, delivering the asset to real customers.
- **Holder utility:** fee tiers on PayLight (Section 5.3). Utility is a discount, never a yield promise.
- **Vault:** choose based on Phase 0 findings; if a holder-dividend vault is available, explain clearly how customers who hold cashback benefit.

### 9.2 Worked economics example (illustrative numbers — label them as such in the UI)
User buys ₦5,000 of electricity. Fee 1.0% (₦50). Cashback share 50% → ₦25 equivalent in USD₮0 goes to the cashback pool; ₦25 goes to the treasury for operations. The user receives ₦5,000 of units and, after the next batch, about ₦25 worth of $LIGHT.

### 9.3 Disclosure post template (Greg posts at deployment)
> PayLight's processor is live on X Layer via TapeOut.
> Processor: `0x…` · Deployer: `0x…`
> Transistor supply: … · Unit price: … · Cap: …
> Circuit: `0x…` (PayLight cashback router)
> Use: pay for prepaid electricity in Nigeria with USD₮0. Part of each fee buys $LIGHT as customer cashback. Protocol wallets never sell.
> Transparency: <url>/transparency

### 9.4 Launch order (each mainnet step needs Greg's explicit "yes, run it")
1. Greg deploys the processor through the TapeOut factory with the approved parameters (via the IGNIX UI or a script, per Phase 0).
2. Deploy gateway + cashback router + adapter on mainnet; verify on the explorer.
3. Tape out the circuit on the processor, per Phase 0's answer.
4. Publish the disclosure post and fill in `/light` and `/transparency`.
5. Canary: Greg pays ₦500–₦1,000 for his own meter. Confirm token, settle, cashback.
6. Open to real users with pilot caps.

---

## 10. Security checklist (write the final version into `docs/SECURITY.md`)
- Contracts: reentrancy guards on all external money paths; `SafeERC20`; checks-effects-interactions; no `tx.origin`; EIP-712 domain bound to chainId and contract; unique orderIds; bounded admin setters with events; pause that never blocks refunds; no upgradeability (immutable is simpler to trust) unless Greg decides otherwise; invariant tests; static analysis.
- Keys: admin = hardware wallet or multisig; operator and keeper = separate hot wallets holding only gas; quote signer key only in the backend env; all three rotatable via admin.
- Backend: zod everywhere; rate limits on verify and quote; SIWE with nonce + expiry; CSRF-safe cookies; admin behind auth + wallet allowlist; secrets only in env; provider keys never sent to the browser.
- Money: bigint math; caps per order, per wallet per day, and global per day during the pilot; float checks before quoting.
- Privacy: no meter data on-chain; masked logs; encrypted tokens at rest; masked customer address in the UI.
- Operations: alerts on every abnormal state; runbook in `docs/RUNBOOK.md` (stuck order, provider outage, low float, compromised hot key → pause + rotate).

---

## 11. Testing and rollout
1. **Local:** Anvil + MockProvider; full flow in the browser.
2. **Testnet + provider sandbox:** deploy to X Layer testnet with a mock USD₮0 if needed; run every scenario: success, pending→success, pending→fail, hard fail, quote expiry, wrong network, self-refund after timeout (use a short timeout on testnet only).
3. **Playwright E2E:** one happy path with an injected test wallet.
4. **Mainnet canary:** a single small real purchase (Greg's meter), then a short pilot with 5–10 trusted users before opening up.
5. Keep a `docs/TEST_REPORT.md` with results and tx links.

---

## 12. `.env.example` (document every variable)
```
# Chain
CHAIN_ID=196
RPC_URL=
RPC_URL_FALLBACK=
EXPLORER_URL=
USDT0_ADDRESS=            # from Phase 0, verified
USDT0_DECIMALS=
GATEWAY_ADDRESS=
CASHBACK_ROUTER_ADDRESS=
PROCESSOR_ADDRESS=
CONFIRMATIONS=

# Keys (worker only, never in web client bundle)
OPERATOR_PRIVATE_KEY=
KEEPER_PRIVATE_KEY=
QUOTE_SIGNER_PRIVATE_KEY=

# Bill provider
PROVIDER=vtpass           # vtpass | mock
VTPASS_BASE_URL=
VTPASS_API_KEY=
VTPASS_PUBLIC_KEY=
VTPASS_SECRET_KEY=
DEFAULT_PHONE=

# App
DATABASE_URL=
SESSION_SECRET=
TOKEN_ENCRYPTION_KEY=
ADMIN_BASIC_AUTH=
ADMIN_WALLETS=
FEE_BPS_DEFAULT=100
CASHBACK_SHARE_BPS=5000
QUOTE_TTL_SECONDS=120
MAX_ORDER_NGN=
DAILY_WALLET_CAP_NGN=
FLOAT_MIN_NGN=

# Alerts
TELEGRAM_BOT_TOKEN=
TELEGRAM_ALERT_CHAT_ID=
```

---

## 13. Deployment and operations
- Web → Vercel (env vars set per environment). Worker → Railway/Render/Fly with a health endpoint and auto-restart. Postgres → managed, daily backups.
- Contracts → Foundry script with keystore/ledger; verified on the explorer; addresses committed to `deployments/196.json`.
- A `Makefile` or `pnpm` scripts for: `dev`, `test`, `test:contracts`, `deploy:testnet`, `deploy:mainnet` (prints the command, doesn't run it), `worker`, `db:migrate`.
- `docs/RUNBOOK.md` for incidents.

---

## 14. Demo and submission package

### 14.1 `docs/DEMO_SCRIPT.md` (2–3 minute video)
1. **Problem (15s):** "Earn in USDT, need light tonight — P2P is slow and risky."
2. **Live purchase (60s):** open PayLight in OKX Wallet on a phone → pick PHED → enter meter → see name → pay ₦1,000 in USD₮0 → token appears.
3. **The physical moment (20s):** type the token into the meter, units load.
4. **On-chain proof (30s):** explorer: `OrderPaid` → `OrderFulfilled`; cashback batch buying $LIGHT and paying the customer.
5. **Asset design (20s):** `/light` page: supply, price, cap, fee tiers, no-sell policy, `/transparency` stats with real unique payers.
6. **Close (10s):** next steps — data bundles, airtime, cable TV, more payment tokens.

### 14.2 `README.md` must include
Problem, solution, how it works (diagram), processor parameters and addresses, circuit address and what it does, deployment wallet, how the asset is issued and distributed, anti-wash-trading design, security model (refund guarantee, caps, pause), how to run locally, tests, live link, demo video link, team.

### 14.3 Submission form fields to prepare
Processor contract address · Deployment wallet · Demo video link · Project description (≤ 300 words, written from the README).

---

## 15. Priorities and definition of done

**MUST (ship first)**
- Phase 0 research complete and approved.
- Gateway + cashback router with full tests, deployed and verified on mainnet.
- Processor deployed via TapeOut with disclosed parameters; circuit taped out.
- `/pay` flow end to end with the live provider, including refunds.
- Worker: listener, fulfiller, settler, reconciler, float monitor, alerts.
- `/light`, `/transparency`, `/help` pages.
- Real purchases by real, distinct users during the window.
- README, demo video, submission.

**SHOULD**
- Holder fee tiers live.
- SIWE history and full receipts.
- Admin dashboard.
- `permit` single-signature payment (if USD₮0 supports it).

**COULD (stretch)**
- SMS delivery of tokens.
- Data bundles and airtime as a second service.
- Gas sponsorship so users need no OKB.
- Agent linking / Founder Round / Buyback Escrow, if Phase 0 shows they apply to TapeOut assets.

**Done means:** a stranger with USD₮0 and a little OKB on X Layer can buy electricity for their meter on mainnet in under a minute; every money path is tested; every address and parameter is public; and nothing in the system can sell the asset or fake activity.
