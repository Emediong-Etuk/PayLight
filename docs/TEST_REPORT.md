# Test report

## Phase 1: contracts (2026-10-03)

Toolchain: Foundry 1.5.1, solc 0.8.28, evm cancun, OpenZeppelin 5.4.0.

| Suite | File | Result |
|---|---|---|
| Smoke (happy paths) | `test/Smoke.t.sol` | 6/6 ✅ |
| Gateway unit | `test/PayLightGateway.t.sol` | 128/128 ✅ |
| Router unit + no-sell surface | `test/CashbackRouter.t.sol` | 119/119 ✅ |
| Fuzz (1,000 runs each) | `test/Fuzz.t.sol` | 23/23 ✅ |
| Invariants (128 runs × 16,384 calls, 9 invariants) | `test/invariant/PayLightInvariant.t.sol` | 11/11 ✅ |
| Security-fix regressions | `test/SecurityFixes.t.sol` | 6/6 ✅ |
| **Mainnet fork** (real TapeOut factory, real USD₮0 permit + EIP-3009, real FeeTier circuit, deploy + launch scripts) | `test/fork/PayLightFork.t.sol` | 24/24 ✅ |

**Total: 317 tests passing, 0 failing.** (Plus `test/Eip712CrossTest.t.sol` added in Phase 2: 318.)

Commands:
```bash
cd packages/contracts
forge test                                                         # offline: 293 tests (fork suite skipped)
FORK=1 forge test --match-path test/fork/PayLightFork.t.sol        # 24 tests against X Layer mainnet state
```

## Phase 2: backend + web (2026-10-03)

| Suite | Result |
|---|---|
| `@paylight/shared` (money math, formatting, EIP-712 vector) | 7/7 ✅ |
| **TS ↔ Solidity EIP-712 cross-test** (viem-signed quote accepted by the gateway) | 1/1 ✅ |
| `@paylight/core` (VTpass classifier on documented sample responses, request_id Lagos time, HTTP headers/timeout, crypto, quote engine, state machine incl. concurrency, rate limit; real Postgres) | 18/18 ✅ |
| `@paylight/worker` **end-to-end on Anvil** (real gateway/router, mock USD₮0/TapeOut, MockProvider, Postgres): success + cashback, pending→success, timeout→success (pay called once), pending→fail→refund, hard fail→refund, unknown→NEEDS_REVIEW (no auto-refund) then third-party self-refund, idempotent re-scan + reconciler | 7/7 ✅ |
| Next.js production build | ✅ (8 pages, 17 API routes) |
| **Full stack over HTTP** (Anvil + worker + Next server + Postgres): SIWE → verify → quote → approve+pay → SETTLED with owner-only token; gasless EIP-3009 relay → SETTLED; history + stats | ✅ (`apps/worker/scripts/smoke-local.mjs`) |
| Mobile layout at 360px (Playwright emulation) | ✅ no horizontal overflow, no client errors |
| Admin protection | ✅ 401 without basic auth, 403 without allowlisted wallet |
