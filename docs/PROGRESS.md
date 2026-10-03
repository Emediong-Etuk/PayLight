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
