# PayLight — Security model

_Phase 1, 2026-10-03. Covers `PayLightGateway` and `CashbackRouter` (packages/contracts). Static analysis (Slither/Aderyn) is not a launch gate per D-01; it will be run and documented here if time allows._

## 1. Guarantees

| Guarantee | How it's enforced | Test evidence |
|---|---|---|
| **Payers can always get their money back if PayLight disappears.** | `claimRefund` works after the order's `refundableAt`, which is **snapshotted at payment time** (24h). It works while paused, needs no backend, and **anyone can trigger it**, but funds only go to the payer, so gasless payers with no OKB can ask anyone to call it. | `test_claimRefund_*`, `test_claimRefund_anyoneCanTrigger_fundsGoToPayer`, fork `test_fork_claimRefund_afterWarp_evenWhilePaused`, invariants |
| **The operator can't race a self-refund.** | `markFulfilled` reverts with `SettlementWindowClosed` after `refundableAt`; after the deadline an order can only be refunded. | `test_markFulfilled_closesAtRefundDeadline`, invariant handler |
| **Escrow is always solvent.** | `usdt0.balanceOf(gateway) >= totalPending`; `totalPending` equals the sum of Paid orders; USD₮0 is conserved; `rescueToken` can only take USD₮0 above `totalPending`. | 9 invariants × 128 runs × 16,384 calls |
| **Orders are final.** | Status only moves None→Paid→Fulfilled or None→Paid→Refunded. | `invariant_terminalStatesAreFinal` |
| **The fee shown is the fee charged; nobody can overcharge beyond the published table.** | The fee must equal `ceil(base × tierFeeBps[tier] / 10 000)`. Tier fees are bounded ≤ 2% and non-increasing by tier. The tier must equal what the TapeOut FeeTier circuit returns on-chain. | `FeeMismatch`, `TierChanged`, fuzz fee tests |
| **TapeOut can never block payments, settlement or refunds.** | All TapeOut calls are gas-capped (eval 150k, balanceOf 50k) and return-size-capped staticcalls. Any failure or garbage falls back to tier 0. Balances are summed with saturation (no overflow DoS). A gas precheck makes sure fallbacks are genuine, not caller-starved. Refunds and settlement never call TapeOut. | `test_tapeOutFailure_*` (Revert, Empty, BadOffset, Tier3, GasBomb, HugeReturn, ShortReturn), `test_computeTier_maxBalances_mustNotBlockPayments` |
| **A broken cashback router never blocks settlement.** | Crediting goes through try/catch; routers without code are skipped; `retryCashbackCredit` covers failed credits. | `test_markFulfilled_routerWithoutCode_settlementStillSucceeds`, router-revert tests |
| **No-sell: the cashback reserve can't be sold or diverted.** | Transistors enter the router only via `topUp` mints (the receiver hook rejects everything else). They leave only via `distribute` to the credited payer of a settled order. There is no approve/transfer/sell function. `rescueERC20` explicitly refuses the transistor contract. Lifetime minting is capped at 20% of supply. `distribute` fails closed if a transfer doesn't actually move tokens. | Router surface test, `test_rescueERC20_cannotMoveTransistors`, `test_router_distribute_failsClosedOnNoopTransfer`, router invariants |
| **Cashback is tied to real money.** | `cashbackUnits ≤ 50` per order **and** each unit needs ≥ 0.25 USD₮0 of base amount (`MIN_BASE_PER_CASHBACK_UNIT`). | `test_cashbackFloor_*`, `testFuzz_cashbackFloor` |
| **No meter data on-chain.** | Only `keccak256(provider tx id)` is emitted as `receiptHash`. | Code review |

## 2. Roles and blast radius

| Key | Holds | Can | Cannot |
|---|---|---|---|
| Admin (hardware wallet / keystore, published) | nothing | Bounded setters, pause/unpause, grant/revoke roles, set treasury/router/signer, rescue *excess* tokens | Lower any order's refund deadline; push fees above 2%; take escrowed USD₮0 directly via rescue |
| Operator (hot, gas only) | OKB gas | Settle (before deadline), refund, pause | Unpause, change config, settle after the deadline |
| Keeper (hot, gas + top-up OKB) | OKB | `topUp` the reserve at the public price, within the 20% cap | Move transistors anywhere |
| Quote signer (backend only) | nothing | Sign quotes | Set fees outside the table, give unbacked cashback, take funds (money only goes to the treasury or back to the payer) |

**Known trust assumptions (accepted for the pilot, disclosed):**
1. **Admin compromise.** An admin can grant itself OPERATOR, point `treasury` at itself and settle Paid orders before their deadline. That diverts escrow of undelivered orders. Mitigations: the admin is a hardware/offline key, pilot caps (30 USD₮0 per order, 1,000 per day) bound exposure, and every change emits an event. Post-hackathon: move admin to a Safe and/or add a timelock on `setTreasury`.
2. **Quote signer + operator compromise.** An attacker with both keys could create small backed orders with their own money to farm cashback (bounded: 50 units need ≥ 12.5 USD₮0 of real payment, and the reserve is capped). They could also fill the daily cap (released again by refunds).
3. **TapeOut is upgradeable** by its owner (a 3-of-5 Safe) until sealed. Covered by the fallbacks above. The worst case is everyone pays the tier-0 fee, or cashback distribution stalls.
4. **USD₮0 issuer blocklist.** If the issuer blocklists a payer after payment, refunds to that payer revert; the order stays Paid and counted in `totalPending`. Accepted; this is inherent to USD₮0.
5. **Settlement delay vs refund window.** If the worker delivers electricity but can't settle within 24h, the payer can self-refund and keep the units. This is bounded by pilot caps; settlement is normally seconds.

## 3. Backend rules the contracts rely on (for Phase 2)

- **Never re-quote** for a payer while a previous quote's signature is still valid (120s TTL) and its payment failed. Failed relay calldata is public and can be replayed until expiry (`test_poc_failedRelayReplayAfterUnpause`). The UI should show "processing" until the quote expires.
- The quote type is exactly `Quote(bytes32 orderId,address payer,uint128 baseAmount,uint128 fee,uint8 tier,uint32 cashbackUnits,uint64 expiry)`, domain `PayLightGateway` / `1` / 196 / gateway address. A TypeScript-sign → Foundry-verify cross-test is required in Phase 2.
- Gasless payments must use `ReceiveWithAuthorization` (not `TransferWithAuthorization`) with `nonce = orderId` and `to = gateway`.
- Relayers should use `eth_estimateGas`. A real `payWithAuthorization` uses about 230k gas, and 350k forwarded is plenty (`test_payWithAuthorization_succeedsWith350kGas`).
- `cashbackUnits` = min(50, floor(₦amount / 1000)), and never more than `baseAmount / 0.25 USD₮0`.

## 4. Review log

Phase 1 review, 2026-10-03:
- **Test authors' bug reports:** 2 real bugs from the gateway test author — (a) overflow DoS in `computeTier`, (b) settlement blocked when the router has no code.
- **Independent reviewers:** two (state machine/access, signatures/payment paths) reported 9 findings each. The third reviewer (TapeOut/router) and the independent verifiers were cut off by a usage limit, so the lead engineer verified each finding against the code.
- **Fixed:** the overflow DoS; the no-code router; cashback units not tied to value; settlement after the deadline; self-refund needing the payer's own gas; refunds not releasing the daily cap; router rescue not excluding transistors; router trusting transfer success; a gas precheck too strict for relayers.
- **Accepted/documented:** admin can redirect escrow (trust assumption 1); tier "stack sharing" via flash-lent transistors (max saving ≈ 0.75% of a ≤30 USD₮0 order, costs ≈ 0.05 OKB to set up); failed-relay replay within the TTL (backend rule); payers that can't receive ERC-1155 keep their credit pending forever (cashback only, no funds at risk); `topUp(0)` only wastes the keeper's own protocol fee.
- **Still to do before mainnet if time allows:** rerun the TapeOut/router-focused review; Slither.
