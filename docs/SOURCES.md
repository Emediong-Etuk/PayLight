# Sources

Everything below was read during Phase 0 on 2026-10-03. "[chain]" facts were read directly from X Layer mainnet (chainId 196) through `https://rpc.xlayer.tech`, around block 72,263,000, using Foundry `cast` 1.5.1. Fork tests used `anvil --fork-url https://rpc.xlayer.tech`.

## Hackathon / IGNIX
- Campaign page and rules: https://ignix.bot/x_campaign (requirements, judging criteria, FAQ, prize table)
- Hackathon window (API behind the campaign countdown): https://api.ignix.bot/v1/supernova/hackathon
- Submission form: https://docs.google.com/forms/d/e/1FAIpQLSd7USjG6LUNNRxwFWY4YEuSY0V0xv8VZNCl6z_-lGSl96vWZA/viewform
- IGNIX docs:
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
- IGNIX app pages (client-rendered; little static content): https://ignix.bot/store, https://ignix.bot/launchpad, https://ignix.bot/create, https://ignix.bot/skymap
- IGNIX HTTP API, used for the ticker-collision scan of 7,312 launches: https://api.ignix.bot/v1/launches
- IGNIX community: https://t.me/IGNIXOfficial

## TapeOut
- TapeOut home (currently the Solana devnet edition; describes processors, transistors, tape-out, upgradeability): https://tapeout.world/
- TapeOut whitepaper (netlist format, evaluation, the seal): https://tapeout.world/whitepaper
- TapeKit kernel network config, listing the X Layer factory address (TapeOut-ecosystem gateway, MIT; not first-party TapeOut): https://tapekit.org/.tape/kernel/config.js and https://tapekit.org/.tape/kernel/selectors.js
- Function-signature lookups for recovering the ABI from bytecode: https://api.4byte.sourcify.dev/signature-database/v1/lookup
- Sourcify check (no verified source found for the TapeOut contracts on 196 or 56): https://sourcify.dev/server/v2/contract/196/<address>
- Search results mentioning the same factory address (third-party hackathon repos; not relied on as primary sources): https://github.com/diveyreadytodive-star/circuitdesk-ignix-tapeout and similar

## X Layer
- Network information: https://web3.okx.com/onchainos/dev-docs/xlayer/developer/build-on-xlayer/network-information
- Contracts and token addresses (USD₮0, USDT, WOKB, …): https://web3.okx.com/onchainos/dev-docs/xlayer/developer/build-on-xlayer/contracts
- RPC endpoints and limits: https://web3.okx.com/onchainos/dev-docs/xlayer/developer/rpc-endpoints/rpc-endpoints
- Verify with Foundry: https://web3.okx.com/onchainos/dev-docs/xlayer/developer/verify-a-smart-contract/verify-with-foundry
- Deploy with Foundry: https://web3.okx.com/onchainos/dev-docs/xlayer/developer/deploy-a-smart-contract/deploy-with-foundry
- Testnet faucet: https://web3.okx.com/onchainos/dev-docs/xlayer/developer/bridge/get-testnet-okb-from-faucet
- Flashblocks: https://web3.okx.com/onchainos/dev-docs/xlayer/developer/flashblocks/overview
- Overview: https://web3.okx.com/xlayer/docs/developer/build-on-xlayer/about-xlayer
- USD₮0 FAQ (OKX): https://www.okx.com/en-us/help/usdt0-faq
- USD₮0 deployments (search result; page not fetched directly): https://docs.usdt0.to/technical-documentation/deployments

## VTpass
- https://www.vtpass.com/documentation/introduction/
- https://www.vtpass.com/documentation/authentication/
- https://www.vtpass.com/documentation/how-to-generate-request-id/
- https://www.vtpass.com/documentation/integrating-api/
- https://www.vtpass.com/documentation/available-services/
- https://www.vtpass.com/documentation/?p=635 (Service ID API)
- https://www.vtpass.com/documentation/variation-codes/
- https://www.vtpass.com/documentation/re-query-services/
- https://www.vtpass.com/documentation/callback-api-integration/
- https://www.vtpass.com/documentation/response-codes/
- https://vtpass.com/documentation/get-vtpass-wallet-balance/
- https://www.vtpass.com/documentation/electricity-payment-api/
- Per-disco pages:
  - https://www.vtpass.com/documentation/phed-api/
  - https://www.vtpass.com/documentation/ikedc-ikeja-electricity-distribution-company-payment-api/
  - https://www.vtpass.com/documentation/eko-electricity-ekedc-payment-api/
  - https://vtpass.com/documentation/aedc-abuja-electricity-distribution-company-payment-api-2/
  - https://www.vtpass.com/documentation/kano-electric/
  - https://www.vtpass.com/documentation/jos-electric/
  - https://vtpass.com/documentation/kaedco-kaduna-electricity-distribution-company-api/
  - https://www.vtpass.com/documentation/eedc-enugu-electric-api/
  - https://www.vtpass.com/documentation/ibadan-electric/
  - https://vtpass.com/documentation/bedc-benin-electricity-distribution-company-payment-api/
  - https://vtpass.com/documentation/aba-electric-api-documentation/
  - https://vtpass.com/documentation/yedc-yola-electric-api-documentation/
- Commission rates (referenced, not fetched): https://vtpass.com/commissions
