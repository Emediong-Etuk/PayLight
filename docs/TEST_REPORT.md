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

**Total: 317 tests passing, 0 failing.**

Commands:
```bash
cd packages/contracts
forge test                                                         # offline: 293 tests (fork suite skipped)
FORK=1 forge test --match-path test/fork/PayLightFork.t.sol        # 24 tests against X Layer mainnet state
```
