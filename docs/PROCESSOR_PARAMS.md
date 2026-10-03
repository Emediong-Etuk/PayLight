# PayLight Processor — Proposed Parameter Sheet (for Greg's approval)

_Proposed 2026-10-03. **Nothing here is deployed.** Every value is set once, at `createCPU`, and published in three places: the deployment tx, the `/light` page and a pinned X post. Background is in [`RESEARCH.md`](RESEARCH.md) §1 and [`DECISIONS.md`](DECISIONS.md) D-02, D-03, D-05, D-06._

## 1. On-chain processor parameters (TapeOut factory `createCPU`)

| Parameter | Proposed | Rationale | Mutable later? |
|---|---|---|---|
| Factory | `0x1f09daefa827f02cbb40967cc91b259763760761` (X Layer, chainId 196) | Verified on-chain; **TODO(verify) with the IGNIX team before signing** | — |
| `name` | **PayLight** | Product name; no clash on TapeOut or IGNIX | No |
| `symbol` | **PLIGHT** | LIGHT is taken on IGNIX by an unrelated token. Alternatives: WATT, PYLT, NEPA | No |
| `story` | "Pay for prepaid electricity in Nigeria with USD₮0 on X Layer. PayLight transistors are earned as customer cashback and unlock lower fees through the PayLight FeeTier circuit." | Plain use case for judges and holders | No |
| `supplyCap` (transistor supply, NAND + LATCH combined) | **1,000,000** | Finite and modest. At the proposed cashback rate it covers about ₦1B of electricity. Tape-outs burn transistors, but burns do **not** restore mintable supply | No (absent a TapeOut upgrade) |
| `mintPrice` (unit price) | **0.0001 OKB** per transistor (`100000000000000` wei) | Non-zero, because zero-price processors were squatted instantly. Low enough that anyone can mint a few to tape out their own circuit. **Greg: sanity-check against today's OKB/USD price; target about $0.005–$0.05 per transistor** | No |
| Per-wallet cap | **None.** TapeOut has no per-wallet cap; this is disclosed as such | — | — |
| Deploy fee (paid to TapeOut) | 0.0066 OKB (read on-chain 2026-10-03; TapeOut-owner-settable until sealed) | — | TapeOut owner |
| Protocol fee per mint call (to TapeOut) | 0.00066 OKB flat per `mint` call | — | TapeOut owner |
| Tape-out fee (to TapeOut) | 0.0013 OKB per circuit | — | TapeOut owner (via beacon upgrade) |
| Creator / mint-revenue recipient | **Deployment wallet** (fresh, hardware-wallet-backed, used only for PayLight; published) | `creator()` = the `createCPU` caller and can't be changed | No |

## 2. PayLight-side parameters (our contracts; bounded by code)

| Parameter | Proposed | Notes |
|---|---|---|
| **Cashback reserve** | Router may mint **at most 200,000 transistors (20% of supply)**, enforced as an immutable constant in `CashbackRouter`. Minted in tranches at the public price | Disclosed allocation, locked in a contract that can only release it against settled orders (D-05). Mint revenue flows back to the creator wallet, so a tranche's net cost is about 0.00066 OKB plus gas, but each tranche needs `units × 0.0001 OKB` of liquidity up front. Suggested first tranche: 20,000 (2 OKB) |
| **Cashback rate** | **1 NAND per ₦1,000** of electricity (rounded down, minimum 1), **max 50 per order**, with the 50 cap enforced on-chain | Units are part of the signed quote, so even a compromised signer is bounded by the on-chain per-order cap and by real paid orders |
| **Fee tiers** (decided by the FeeTier circuit) | Tier 0: **1.00%** · Tier 1: **0.50%** · Tier 2: **0.25%** | The brief proposed 0% for tier 2; I suggest keeping 0.25% so every order still covers costs. Setter bounded to ≤ 2.00% per tier |
| Tier inputs | `h1`: holds ≥ **50** transistors · `h2`: holds ≥ **500** · `r`: ≥ **3** settled PayLight orders | Tier 1 = `h1 OR r`; Tier 2 = `h2`. Thresholds are admin-settable within bounds and published on `/light` |
| Fee asset | USD₮0, 100% to treasury | No swap; `cashbackShareBps` removed (D-05) |
| Pilot caps | `maxOrderAmount` **30 USD₮0** · `dailyVolumeCap` **1,000 USD₮0** · per-wallet per day (backend) **60 USD₮0** | Raise after the canary and pilot. **Greg to approve** |
| `refundTimeout` | **24 h** (code bounds: 1 h – 72 h) | Self-refund guarantee |
| Quote TTL | 120 s | From the brief |
| FX | Admin-set NGN/USD₮0 rate + spread (Greg sets the numbers) | Quotes are blocked if the rate is stale or the provider float is low |

## 3. Circuit to tape out at launch

**PayLight FeeTier v1:** 7 NANDs, 3 inputs, 2 outputs. The netlist hex and full truth table are in RESEARCH §1 Q6, verified on a mainnet fork.

Launch cost:
- Mint 7 NAND: `7 × 0.0001 + 0.00066` = 0.00136 OKB (the mint revenue returns to the creator).
- Tape-out fee: 0.0013 OKB.
- Gas: negligible.

## 4. Mainnet launch sequence (each step needs Greg's "yes, run it")

1. `createCPU("PayLight","PLIGHT","<story>",1000000,100000000000000)` with `value = deployFee()`, from the **deployment wallet**. I'll print the exact `cast send … --ledger` command.
2. Mint 7 NAND, then `tapeout(<FeeTier netlist>, 3, 2)` with value 0.0013 OKB.
3. Deploy `PayLightGateway` and `CashbackRouter` (after Checkpoint 1); verify on OKLink; set the circuit id and tiers.
4. Mint the first cashback reserve tranche through the router.
5. Publish the disclosure (below) and fill in `/light` and `/transparency`.
6. Canary: Greg buys ₦500–₦1,000 for his own meter.

## 5. Approximate OKB budget

| Item | OKB |
|---|---|
| createCPU | 0.0066 |
| FeeTier circuit (mint + tape-out) | ~0.003 |
| Contract deployments + config (~10 txs at ~0.02 gwei) | < 0.001 |
| First reserve tranche (20,000 transistors; returns to creator) | 2.0007 (liquidity, mostly recoverable) |
| Operator gas float (relaying + settling) | 0.05 |
| **Total needed up front** | **≈ 2.07 OKB** (≈ 0.07 OKB actually spent) |

## 6. Disclosure post (draft)

> PayLight's processor is live on X Layer via TapeOut.
> Processor: `0x…` · Deployer: `0x…`
> Transistor supply cap: 1,000,000 · Unit price: 0.0001 OKB · No per-wallet cap
> Cashback reserve: max 200,000 (20%), held by the PayLight CashbackRouter `0x…`, which has no sell function and only pays customers per settled order
> Circuit: PayLight FeeTier v1 (#1 on the processor). It sets every customer's fee tier on-chain
> Use: pay for prepaid electricity in Nigeria with USD₮0. Protocol wallets never sell or trade.
> Transparency: <url>/transparency
