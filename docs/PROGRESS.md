# Progress log

## 2026-10-03 (Sat) — Phase 0: Discovery

- Read all 24 IGNIX pages listed in the brief, the TapeOut site and whitepaper, the X Layer developer docs and the VTpass API docs. Sources are in `SOURCES.md`.
- **Found the hackathon window: it ends 2026-10-09 04:00 UTC.**
- Found that TapeOut (processor / transistor / circuit) is a separate protocol from the IGNIX launchpad. I recovered the X Layer TapeOut ABIs from bytecode and confirmed their behaviour with `eth_call` simulations.
- On an Anvil fork of X Layer mainnet I dry-ran the full TapeOut lifecycle: `createCPU` → `mint` → `tapeout` → `eval`. I then taped out the proposed **PayLight FeeTier v1** circuit, and all 8 truth-table rows came out correct.
- Verified on-chain: USD₮0 has 6 decimals and supports EIP-2612 permit (domain name "USD₮0", version "1") and EIP-3009.
- Measured X Layer: 1 s blocks, gas price about 0.02 gwei, `safe` lag about 4 min, `getLogs` capped at 100 blocks.
- Wrote `RESEARCH.md`, `DECISIONS.md`, `PROCESSOR_PARAMS.md`, `GREG_ACTIONS.md` and `SOURCES.md`. Saved the brief as `BUILD_BRIEF.md`.
- No application code yet (Phase 0 rule). No mainnet transactions. No secrets.
- **→ CHECKPOINT 0: waiting for Greg.**

## 2026-10-03 (Sat) — Checkpoint 0 approved

- Greg approved the redesign and the full parameter sheet (PayLight / PLIGHT, cap 1,000,000, 0.0001 OKB, fee tiers 1% / 0.5% / 0.25%, pilot caps 30 / 1,000 USD₮0).
- Also approved: trimmed test gates (Slither and Playwright don't gate launch; fork, fuzz and invariant tests are mandatory), vend after 3 blocks, hosting on Railway.
- Owner actions are still in progress (clarified later the same day). Greg is being walked through VTpass, wallets, funding and the processor launch. Secrets go to environment variables, never chat.
- Starting Phase 1 (contracts).

## 2026-10-03 (Sat), evening

- The Phase 1 test/review workflow was cut off by a usage limit and re-launched. The contracts were unaffected.
- IGNIX hasn't replied about the factory address. **Greg decided to proceed with `0x1f09…0761`** (verified on-chain; 272 processors; deployed by TapeOut's protocol wallet). Recorded as D-14.
- Added `docs/HOWTO_URGENT_ACTIONS.md` (VTpass steps verified; wallet/funding/treasury steps being re-verified).

## 2026-10-03 (Sat), late — Phase 1 contracts complete

- Test suites written by 4 parallel agents and finished by the lead engineer: 317 tests, all passing, including 24 against real X Layer mainnet state on a fork.
- Security review: 2 real bugs from test authors, 18 reviewer findings. 9 fixed in code with regression tests; the rest documented in `docs/SECURITY.md`.
- Deploy scripts: `script/Deploy.s.sol` (gateway + router, writes `deployments/<chainId>.json`) and `script/LaunchProcessor.s.sol` (processor + FeeTier tape-out), both exercised on the fork.
- **→ CHECKPOINT 1: waiting for Greg.**

## 2026-10-03 (Sat), night — Checkpoint 1 approved

- Greg approved Checkpoint 1. Starting Phase 2: backend (shared package, DB, VTpass provider, quote engine, worker, API routes).
- Worker built: listener, fulfiller (request_id persisted before the single pay call; requery backoff 10s→10m; NEEDS_REVIEW on persistent unknown, never auto-refund), settler, refunder, cashback keeper, reconciler (at `safe` head), float/gas monitor with auto-pause, Telegram alerts, health endpoint.
- End-to-end on local Anvil (real gateway/router, mock USD₮0/TapeOut, MockProvider, Postgres): 7/7 scenarios pass.
- Found and fixed during e2e: viem caches getBlockNumber for ~4s, so the listener now reads the head uncached.
- Web app built: API routes (discos, meter verify, quote, orders, SIWE, stats, VTpass webhook, gasless relay, admin) and pages (/, /pay, /receipt, /history, /light, /transparency, /help, /admin). Mobile-first; light and dark mode.
- Full stack verified locally over HTTP (SIWE, quote, approve+pay, gasless relay, settlement, owner-only token). Details in TEST_REPORT.md.
- Not done yet: Railway deployment, live VTpass, mainnet deploy, demo script, WalletConnect (injected-only for now).
