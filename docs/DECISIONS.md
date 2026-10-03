# PayLight — Architecture Decisions

Status key: **PROPOSED** (needs Greg) · **ACCEPTED** · **SUPERSEDED**. Facts cited here are sourced in [`RESEARCH.md`](RESEARCH.md).

Rule 4 of the brief says that where the docs contradict the brief, the docs win and the conflict gets logged here. The conflicts found so far are summarised at the bottom.

---

## D-01 · Plan for the real deadline: 2026-10-09 04:00 UTC · ACCEPTED (Greg, 2026-10-03)

The window closes Friday 9 Oct, 05:00 Lagos time. Today is Saturday 3 Oct. That leaves about 3½ business days for VTpass approval, which is the slowest dependency.

**Proposed schedule:**

| Day | Claude | Greg |
|---|---|---|
| Sat 3 | Phase 0 (this) → Checkpoint 0 | Start VTpass live onboarding; message the IGNIX team; approve the parameter sheet; create wallets |
| Sun 4 | Contracts + Foundry tests on a mainnet fork; FeeTier netlist + fork tape-out test | Deploy the processor + tape out the circuit on mainnet (cheap, and it ticks two hard requirements on day 2) |
| Mon 5 | Worker + API (VTpass sandbox, MockProvider), `/pay` flow | Chase VTpass live approval; hosting accounts |
| Tue 6 | Mainnet deploy of gateway + router (after Checkpoint 1); `/light`, `/transparency`, `/help` | Canary purchase as soon as VTpass is live |
| Wed 7 | Fixes, admin basics, README | Pilot with 5–10 community users |
| Thu 8 | Demo script, submission text | Record the demo, post the disclosure, **submit before Thu 23:00 WAT** |

To fit this, the MUST list in brief §15 is trimmed:
- **Kept as MUST:** gateway with refunds + caps, cashback router, the TapeOut processor + circuit, `/pay`, the worker core (listener / fulfiller / settler / reconciler / float monitor / alerts), `/light`, `/transparency`, `/help`, README, demo, submission.
- **Moved to SHOULD:** SIWE history and the full admin dashboard. A minimal admin (requery / refund / rate / pause) stays.
- **Moved to COULD:** Playwright E2E, Slither (run it if time allows and document the findings, but it doesn't gate the pilot), and SMS.

Dropping Slither as a gate means relaxing brief §5.4. **This needs Greg's explicit OK.** Fork tests, fuzz tests and invariant tests stay mandatory.

## D-02 · The "asset" is the TapeOut processor's transistors, not an IGNIX ERC-20 · ACCEPTED (Greg, 2026-10-03)

**Context.** The brief assumed $LIGHT is an ERC-20 launched on an IGNIX bonding curve with a USD₮0 quote, and that cashback buys it. In reality a TapeOut processor issues **ERC-1155 transistors (NAND id 0, LATCH id 1)**:
- They're sold at a **fixed price in native OKB** up to a **fixed `supplyCap`**.
- There's no curve, no tax and no vault.
- They're consumed when anyone tapes out a circuit on our processor.

**Decision.**
- PayLight's hackathon asset is the **PayLight processor's transistors**.
- We **don't** launch a separate IGNIX token for the MVP. It isn't required, the LIGHT ticker is already taken on IGNIX, and pre-graduation IGNIX tokens can only be transferred to or from IgnixManager. It would also add a second traded asset, with all the wash-trading optics that brings.
- An IGNIX launch can be revisited after the hackathon (COULD).

**Consequences.**
- Every "$LIGHT" in the brief becomes "PayLight transistors" (UI copy: "Light transistors" or similar; to be agreed).
- There's no secondary-market buying by any protocol wallet, ever. Cashback is primary issuance (D-05).
- Holder utility stays the same in spirit: **fee tiers** (D-06), plus the transistors are building blocks people can use to tape out their own circuits on our processor.

## D-03 · How the circuit requirement is satisfied · ACCEPTED (Greg, 2026-10-03)

**Context.** A circuit is a NAND/LATCH netlist minted as an ERC-721 by `processor.tapeout(...)`, burning transistors. A circuit can't be an arbitrary contract, so the brief's "gateway/router is the circuit" idea isn't possible. Circuits can be evaluated on-chain through `processor.eval(id, bits)`, a `view` call that cost about 55k gas for 4 gates on the fork.

**Decision.**
- Greg's deployer wallet tapes out **`PayLight FeeTier v1`** on the PayLight processor right after deployment. It's about 7 NANDs, with inputs `h1, h2, r` and outputs `tier[1:0]`.
- `PayLightGateway` stores `(processor, feeCircuitId)` and, inside `pay*()`, computes the inputs on-chain:
  - `h1` = NAND+LATCH balance ≥ T1
  - `h2` = balance ≥ T2
  - `r` = the payer's settled orders ≥ R
- It then calls `eval` to get the tier. The tier is checked against the signed quote and emitted in `OrderPaid`.
- The call is wrapped in `try/catch`: on any revert or malformed output, the tier falls back to **0** (the default, highest fee). TapeOut is upgradeable, and we must never let a TapeOut change block payments or charge more than the signed fee.
- The backend reads the same value through a gateway view, `previewTier(payer)`, so quote and chain always agree.
- **Why this one:** it's the smallest circuit that's genuinely *used* on every payment, it's verifiable by judges from events, and it makes the processor "real and used".
- **Stretch:** encourage customers to tape out their own circuits using cashback transistors (e.g. a simple "light switch" tutorial on `/light`).

## D-04 · Payment paths · ACCEPTED (permit is SHOULD; gasless EIP-3009 is SHOULD, built if time allows)

USD₮0 supports `permit` (EIP-2612) and `receiveWithAuthorization` (EIP-3009), both verified on-chain. The gateway will expose:
1. **`pay(...)`**: classic approve + pay (2 transactions). Always available.
2. **`payWithPermit(...)`**: permit signature + 1 transaction. The `permit` is wrapped in try/catch with an allowance check, to resist front-run griefing. This is SHOULD, upgraded from the brief's "only if supported", because it *is* supported.
3. **`payWithAuthorization(...)`**: **gasless for the user**. The user signs an EIP-3009 `ReceiveWithAuthorization(from=payer, to=gateway, value=amount, validAfter, validBefore, nonce=orderId)`. Our operator relays it and pays the gas (about 0.02 gwei × ~250k gas, which is negligible). Using `nonce = orderId` binds the authorization to exactly one order. **SHOULD**, and a strong UX and judging point: "no OKB needed". If it ships, `/help` no longer needs the "get some OKB" step.

## D-05 · Cashback = transistors from an on-chain reserve; no swaps, no market buys · ACCEPTED (Greg, 2026-10-03)

**Context.** Transistors are minted with native OKB, while fees arrive in USD₮0. The brief's design (send a USD₮0 fee share to the router, which buys the asset) would need a USD₮0→OKB swap on every batch. I haven't verified any DEX router on X Layer, and a swap adds slippage, MEV and failure modes.

**Decision.**
- `CashbackRouter` holds a **disclosed cashback reserve** of PayLight NAND transistors. The router mints them itself, through `transistors.mint{value}`, at the public price (proposed size in [`PROCESSOR_PARAMS.md`](PROCESSOR_PARAMS.md)).
- When the gateway settles an order (`markFulfilled`), it calls `router.credit(orderId, payer, units)`. `units` comes from the order's base amount at a published rate (e.g. 1 NAND per ₦1,000 equivalent).
- A keeper calls `distribute(orderIds[])`, which transfers each payer their units and emits `CashbackPaid(orderId, payer, units)`. Integer units mean no dust.
- **The only outbound transfer path is `distribute` against credited, settled orders.** No sell, swap, approve, withdraw or arbitrary-transfer function exists for transistors. The router can't hold or forward any other token, except rescuing tokens that aren't transistors.
- A permissionless (or keeper) **`topUp`** can mint more transistors into the reserve at the public price while supply remains.
- **The whole service fee goes to the treasury in USD₮0.** The brief's `cashbackShareBps` disappears. Simpler, and no swap.

**Honesty note for judges (goes on `/light` and in the README).** Mint revenue accrues to the processor creator, which is Greg's deployer wallet. So the reserve is economically a **disclosed creator allocation, locked in a contract that can only release it to paying customers, one settled order at a time**. That's the asset-issuance story: **fixed public supply; the protocol's share is locked in a no-sell contract and distributed only through real electricity purchases; no protocol wallet ever trades.**

**Alternatives rejected:**
- (a) Mint on demand per batch: if someone buys out the public supply, cashback stops.
- (b) An on-chain USD₮0→OKB swap: unverified router, plus extra risk.
- (c) Buying on a secondary market: wash-trading optics.

## D-06 · Fees are tier-based and enforced by the circuit · ACCEPTED (Greg, 2026-10-03)

**Quote format.** The backend signs EIP-712 `Quote(bytes32 orderId,address payer,uint128 baseAmount,uint128 fee,uint8 tier,uint32 cashbackUnits,uint64 expiry)` (domain `PayLightGateway`, version `1`).

**The gateway enforces:**
- `tier == circuitTier(payer)`, via D-03 with its fallback. If not, it reverts with `TierChanged` and the UI re-quotes.
- `fee == ceil(baseAmount × tierFeeBps[tier] / 10_000)`.
- Admin setters for `tierFeeBps` are bounded (≤ 200 bps, i.e. 2%). So even a compromised quote signer can't overcharge beyond the published table, and the fee shown is exactly the fee charged.

**Brief vs proposal:** the brief let the signer choose any fee. The proposal moves fee logic on-chain, which is safer and makes the circuit load-bearing.

## D-07 · Confirmations before vending · ACCEPTED (Greg, 2026-10-03)

- **Vend after 3 blocks on `latest`** (about 3 s on X Layer's 1 s blocks), with a small per-order pilot cap.
- The reconciler re-verifies each order against the **`safe`** head (~4 min behind) and alerts on any mismatch. Accounting is final at `finalized` (~19 min).
- **Rationale:** X Layer is a single-sequencer OP-Stack chain. Reorgs of `latest` are rare, and the caps bound the worst case. Waiting for `safe` would add about 4 minutes to every purchase.
- Greg may choose a stricter setting.

## D-08 · Test against an Anvil fork of mainnet, not X Layer testnet · ACCEPTED (technical)

Neither the TapeOut factory nor USD₮0 exists on testnet (chainId 1952); `getCode` is empty at both. An Anvil fork of chainId 196 has the real USD₮0 (6 decimals, permit, EIP-3009) and the real TapeOut. I already ran create → mint → tapeout → eval end to end on a fork. "Testnet" in the brief §11 therefore means "fork + VTpass sandbox". Short refund timeouts for testing are set through constructor args on the fork, not on mainnet.

## D-09 · Our contracts are immutable; TapeOut is isolated · ACCEPTED (from brief)

- No proxies for `PayLightGateway` or `CashbackRouter`.
- TapeOut is upgradeable by a 3-of-5 Safe, so every TapeOut call is non-critical:
  - The fee-tier call falls back (D-03).
  - Cashback distribution failing never blocks settlement or refunds (credits accumulate and can be distributed later).
- `refund` and `claimRefund` never touch TapeOut.

## D-10 · All VTpass calls run from a static-IP backend · ACCEPTED (Greg, 2026-10-03)

VTpass live may require **IP whitelisting** (error 027). Vercel serverless egress IPs aren't static. **Proposal:** host both the Next.js app and the worker on one platform with a static outbound IP (Railway with static IP, or Fly.io with an egress IP), or have Vercel call the worker's internal HTTP endpoint for verify and quote. Greg picks the hosting. Default if he doesn't choose: Railway for web, worker and Postgres.

## D-11 · Event indexing within RPC limits · ACCEPTED (technical)

The public RPC caps `eth_getLogs` at **100 blocks** and requests at 100/s per IP. The listener will:
- scan in 100-block pages with a 10-block overlap;
- track a cursor per contract;
- also accept a dedicated RPC URL (`RPC_URL`) when Greg provides one (e.g. QuickNode, Alchemy, ZAN, Chainstack, BlockPI, all listed by X Layer).

## D-12 · Names · ACCEPTED (Greg, 2026-10-03)

- Processor name **"PayLight"**, symbol **"PLIGHT"**. LIGHT is taken on IGNIX by an unrelated token; TapeOut doesn't enforce uniqueness, but confusion hurts.
- Alternatives: WATT, PYLT, NEPA.
- Circuit name (off-chain label): **"PayLight FeeTier v1"**.

## D-13 · No IGNIX Agent / Founder Round / Buyback Escrow · ACCEPTED

These features only apply to IGNIX launchpad tokens linked to OKX Agents. They don't apply to TapeOut processors.

---

## D-14 · Use TapeOut factory 0x1f09…0761 without an IGNIX reply · ACCEPTED (Greg, 2026-10-03)

The IGNIX team hasn't replied to the request to confirm the factory. Greg chose to proceed with `0x1f09daefa827f02cbb40967cc91b259763760761`. Evidence:
- It's the only TapeOut factory deployed on X Layer.
- It holds 272 processors, and processor #0 was created by TapeOut's own protocol wallet.
- Its owner is a 3-of-5 Safe that includes that wallet.
- TapeKit's config lists it.
- The full lifecycle works on a fork.

Residual risk: IGNIX could later name a different factory. Cost of being wrong: about 0.0093 OKB and a redeploy.

---

## Conflicts between the brief and the docs (rule 4 log)

| Brief section | Brief says | Docs / chain say | Resolution |
|---|---|---|---|
| §1, §5.2, §9 | $LIGHT is the processor asset, bought on IGNIX with USD₮0 | A processor issues ERC-1155 transistors at a fixed OKB price; IGNIX is a separate launchpad | D-02, D-05 |
| §2.2, §5.2 | The cashback router is the circuit | A circuit is a taped-out netlist NFT | D-03 |
| §3.2 Q7–Q9 | Choose a quote token, vault and tax for the processor | Not applicable to TapeOut (OKB only, no vault, no tax) | D-02 |
| §5.1 | Signer chooses the fee; `cashbackShareBps` | Fee enforced on-chain by the circuit tier; cashback is transistors, not a fee share | D-05, D-06 |
| §5.1 | `payWithPermit` only if supported | Supported, and EIP-3009 too | D-04 |
| §11 | Deploy to X Layer testnet | TapeOut and USD₮0 aren't on testnet | D-08 |
| §13 | Web on Vercel | VTpass IP whitelisting needs static egress | D-10 |
| §15 | No deadline stated | Window ends 2026-10-09 04:00 UTC | D-01 |
