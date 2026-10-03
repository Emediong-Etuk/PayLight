# Things only Greg can do

Ordered by urgency. The deadline is **Fri 2026-10-09 04:00 UTC (05:00 WAT)**. Aim to submit by **Thu 8 Oct, 23:00 WAT**.

## 🔴 Today (Sat 3 Oct)

1. **VTpass: start live onboarding now. This is the slowest dependency.**
   - Create a **sandbox** account at https://sandbox.vtpass.com/register. Under Profile → API Keys, set the auth type to "API keys" and generate keys. Paste the api-key, public-key and secret-key into the env (not into chat). I need these for Monday's integration.
   - Create a **live** account at https://www.vtpass.com/register and complete any KYC it asks for.
   - Email VTpass tech support (address on https://www.vtpass.com/documentation/integrating-api/) or Skype `vtpass.techsupport`. Ask them to:
     - (a) enable **API access** on the live account (error 023 otherwise);
     - (b) whitelist **all 12 electricity products** (error 028): `ikeja-electric, eko-electric, abuja-electric, kano-electric, portharcourt-electric, jos-electric, kaduna-electric, enugu-electric, ibadan-electric, benin-electric, aba-electric, yola-electric`;
     - (c) tell you whether **IP whitelisting** applies (error 027). If it does, we'll send our server's static IP Monday;
     - (d) tell you **how long approval takes and what documents they need**.
   - Plan to fund the live VTpass wallet with a naira float for the pilot (suggest ₦30,000–₦50,000).
2. ~~**Ask the IGNIX team**~~ (no reply; Greg decided to proceed with the on-chain-verified factory, DECISIONS D-14). Original questions, kept for reference: I couldn't find these in any official doc:
   - (a) Is `0x1f09daefa827f02cbb40967cc91b259763760761` the official TapeOut factory on X Layer for this hackathon?
   - (b) Does a processor created by calling the factory directly (script, no UI) count? Is there an official X Layer TapeOut UI?
   - (c) Does "any cap" in the rules mean anything beyond `supplyCap`?
   - (d) Confirm the window ends 2026-10-09 04:00 UTC.
3. **Approve or change** the parameter sheet (`docs/PROCESSOR_PARAMS.md`): name and symbol, supply cap, mint price (check the OKB/USD price), reserve size, cashback rate, fee tiers, pilot caps.
4. **Approve or change** the decisions marked PROPOSED in `docs/DECISIONS.md`. The big ones:
   - D-01: trimmed MUST list, and Slither no longer gating.
   - D-02 / D-05: the asset is transistors, and there's no IGNIX token.
   - D-04: gasless payments.
   - D-07: 3-block confirmations.
   - D-10: hosting.
5. **Wallets.** Create these and send me **only the public addresses**:
   - **Deployment wallet / admin.** Hardware wallet preferred (Ledger works with `cast --ledger`), otherwise a Foundry keystore made with `cast wallet import`. This address becomes the processor creator, is published, and receives mint revenue.
   - **Treasury** address (receives USD₮0 fees). It can be the same hardware wallet, or a Safe.
   - Three hot keys will live in the server env only: **operator** (settles and refunds; holds gas only), **keeper** (cashback distribution), **quote signer** (signs quotes; holds no funds). I can generate these on the server side, or you can.
6. **Fund the deployment wallet** on X Layer with **≈ 2.1 OKB** (see the parameter sheet budget). Also fund ~**10 USD₮0** on your personal wallet for canary tests.

## 🟠 Sun 4 – Mon 5

7. **Mainnet signing:** processor `createCPU`, minting 7 NAND and tape-out of the FeeTier circuit. I'll print exact commands; you run them or type "yes, run it".
8. **Hosting:** create a Railway (or Fly.io) project with a **static outbound IP** and managed Postgres. Add a domain if you want one. Give me deploy access or an API token through env, never in chat.
9. **Alerts:** create a Telegram bot with @BotFather and a private alert chat. Put the bot token and chat ID in env.
10. **RPC (optional but recommended):** a free dedicated X Layer RPC (QuickNode, Alchemy, ZAN, Chainstack or BlockPI). The public one limits log queries to 100 blocks.
11. **OKLink API key**, if contract verification asks for one.
12. Set the **NGN/USD₮0 rate and spread** you're comfortable quoting.

## 🟡 Tue 6 – Thu 8

13. Mainnet deploy of gateway + router (after Checkpoint 1): "yes, run it".
14. **Canary:** buy ₦500–₦1,000 for your own meter and confirm the token loads.
15. **Pilot:** recruit 5–10 trusted community members. They need real, distinct wallets and real meters. **No team-funded fake purchases** (that's a disqualifier).
16. Screenshots of the OKX app flow for withdrawing USD₮0 (and OKB) to X Layer, for `/help`.
17. Logo and hero art for the site.
18. **Record the demo video** (script will be in `docs/DEMO_SCRIPT.md`). Post the disclosure on X and pin it.
19. **Submit the form:** processor address, deployment wallet, demo link, ≤300-word description.
