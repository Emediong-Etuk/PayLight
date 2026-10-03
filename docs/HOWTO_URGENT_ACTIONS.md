# Urgent owner actions: how-to and double-check list

_Researched 2026-10-03 by a 4-researcher workflow._
- The **VTpass** section was independently verified, and its corrections are applied below.
- The **funding**, **wallet** and **treasury** sections were verified later the same day, and their corrections are applied below too.
- Items marked ⚠️ are the ones people most often miss.

## 1. VTpass

**Done already? Check these:**

- ⚠️ **Products are disabled by default, in BOTH sandbox and live.** Open your account → **Product Settings** tab → tick all the electricity DisCos → **Submit**. If you skip this, every call fails with `028 PRODUCT IS NOT WHITELISTED`. Sandbox: https://sandbox.vtpass.com/account. Live: https://vtpass.com/account.
- ⚠️ **Live KYC needs BVN + NIN + a recent utility bill.** Go to *My Account → KYC and BVN Info*, choose Individual or Registered Business. Your **dedicated wallet-funding account number only appears after KYC is verified, plus about 1 hour**. Without it you can't put naira in the live wallet.
- ⚠️ **Submit the "Go Live" form as well as the email.** Log in on **www.vtpass.com**, then open https://www.vtpass.com/request-api-access yourself (the developers-page button only takes you to the login page). A community README says the form asks for the services you integrated and **a successful sandbox `request_id`**. Once your sandbox keys are in the environment, I'll produce one for you.
- **Email support@vtpass.com.** Include:
  - your live account email and phone;
  - "PayLight, prepaid electricity vending via API";
  - the 12 serviceIDs;
  - 1–3 successful sandbox request_ids;
  - our **static server IP** for whitelisting (your VPS's public IPv4, see `docs/VPS_DEPLOY.md` step 7);
  - the callback URL (comes later);
  - the 9 Oct deadline.
  - **Never** send the secret key, BVN or NIN.
- **Follow up** by phone on **07080631810** or via live chat on vtpass.com (listed as 24/7). The Skype handle in their docs is dead; Microsoft retired Skype in May 2025.
- **Keys:** the PK_ and SK_ keys are shown only once. Sandbox keys don't work against live (error 087), and vice versa.
- **Funding:** use the dedicated account number or **Credit Wallet**. **Never** pay into bank accounts listed in old VTpass blog posts. Start with a small float, because over-funding past your customer class can lock the wallet.
- **Commission:** the API column at https://www.vtpass.com/commissions. Ikeja and PHED pay **0% on MD meters**; AEDC is capped at ₦1,300 and Ikeja at ₦1,500.
- **No published turnaround** exists for live provisioning. We'll make sure the full demo also works on the **sandbox** (meter `1111111111111` returns a token) as a fallback.

## 2. Getting OKB and USD₮0 onto X Layer (verified)

- ⚠️ **Withdrawing USDT from OKX:** pick the network labelled **"X Layer (USDT0)"**. In your wallet the token must show as **USD₮0** (with ₮), contract `0x779Ded0c9e1022225f8E0630b35a9b54bE713736`. Plain **"USDT"** on X Layer (`0x1E4a…D41d`) is the legacy token being phased out, and PayLight doesn't accept it.
- **OKB:** OKB-USDT is a spot market on OKX. USDT bought via P2P lands in your **Funding** account, so first move it with Assets → **Transfer** (Funding → Trading), then buy OKB.
- **Withdrawing OKB:** Assets → Withdraw → OKB → *New destination* (on-chain, not "OKX recipients") → paste your 0x address → network **X Layer** (may be labelled "X Layer (OKB)").
  - ⚠️ On the website you enter the **address first** and OKX auto-picks a network. A 0x address also matches Ethereum and Arbitrum, so **check X Layer is selected** before Next.
  - Read the fee and minimum on the screen.
  - An ERC-20 OKB withdrawal from another exchange lands on Ethereum, **not** X Layer.
- **Send a small test first,** check it on the explorer, then send the rest. Your address page is `https://web3.okx.com/explorer/x-layer/evm/address/<YOUR_ADDR>`.
- ⚠️ **P2P "T+N" holds:** some P2P merchants trigger a 3, 7 or 15-day lock on withdrawing what you buy. **T+7 or T+15 would run past the deadline.** OKX warns you before you place the order; if you see a T+N warning, back out and pick another merchant. NGN P2P is live on OKX (≈₦1,352/USDT on 2026-10-03).
- **Other withdrawal locks:**
  - Changing your password, phone or 2FA blocks withdrawals for 24h.
  - The "New address withdrawal lock" holds newly added addresses for 24h.
  - An address OKX flags as high-risk is restricted for 48h.
  - Set up authenticator + email 2FA now (SMS can't be used once all three are linked).
- **If OKX doesn't work for you:** Gate lists OKB withdrawals on X Layer, but has no USD₮0 on X Layer. Bitget, KuCoin and HTX don't support X Layer for these assets.
- **Cost check:** OKB ≈ 120 USDT and USDT ≈ ₦1,352 (2026-10-03), so 1 OKB ≈ ₦162k.
  - The processor launch itself needs only **≈0.01 OKB**.
  - The first cashback reserve batch is the big item, and it comes back to you as creator revenue: 20,000 transistors ≈ 2.0 OKB (≈₦325k), or **5,000 ≈ 0.5 OKB (≈₦81k), which is recommended**.
  - The operator gas float is 0.05 OKB.
- **Read-only balance checks** (no keys needed):
  `cast balance <ADDR> --ether --rpc-url https://rpc.xlayer.tech` (shows OKB)
  `cast erc20 balance 0x779Ded0c9e1022225f8E0630b35a9b54bE713736 <ADDR> --rpc-url https://rpc.xlayer.tech` (6 decimals)

## 3. Deployment / admin wallet (verified)

- ⚠️ **Only use a Ledger if you already own a genuine one you set up yourself.** Ledger delivery to Nigeria takes 4–6 weeks, so don't order one for this. Never use a second-hand or "pre-set-up" device. Otherwise use the keystore option below; it's fine for the hackathon.
- **Install Foundry:**
  1. `curl -L https://getfoundry.sh/install | bash`
  2. Add `export PATH="$PATH:$HOME/.foundry/bin"` to `~/.zshrc` or `~/.bashrc`.
  3. Run `foundryup`. It installs the latest stable (≈1.8.x, about 120 MB, so use Wi-Fi).
  - On Windows, use **WSL2**. If it fails with 0x80370102, enable virtualization in BIOS.
- **Ledger:**
  - Install the **Ethereum** app. It also signs for X Layer (chain 196).
  - Get your address with `cast wallet address --ledger`, which uses the Ledger Live path index 0.
  - Test the connection for free with `cast wallet sign "PayLight ledger test" --ledger`.
  - ⚠️ **Enable Blind signing** in the Ethereum app's settings, or contract calls (createCPU, mint, tapeout, deploy) get rejected. It switches itself off after app or firmware updates.
  - **Close Ledger Live and MetaMask** while using cast.
  - In WSL2, the Ledger needs **usbipd-win** to pass the USB device through.
- **Keystore (no Ledger):**
  1. `mkdir -p ~/.foundry/keystores`
  2. `cast wallet new ~/.foundry/keystores paylight-admin` (the key is never shown; the password prompt shows nothing as you type)
  3. **Immediately** run `cast wallet address --account paylight-admin` to confirm the password works (it's asked only once).
  - ⚠️ **Run the create command only once.** Older Foundry silently overwrites an existing key of the same name. Newer versions ask `[y/N]`; answer **N**.
  - There's no seed phrase. Back up `~/.foundry/keystores/paylight-admin` and its password offline. On WSL the file is at `\\wsl$\Ubuntu\home\<you>\.foundry\keystores`, and resetting Ubuntu deletes it.
- ⚠️ **Always pass `--rpc-url https://rpc.xlayer.tech` explicitly.** Without it, cast defaults to localhost. Confirm every real transaction on the OKX explorer.
- **Never** use `--private-key` or `--unsafe-password` on the command line (they end up in shell history), and never run `cast wallet new` without a folder (it prints the key).

## 4. Treasury (verified)

- ⚠️ **The treasury receives the WHOLE amount of every settled order** (electricity cost + fee), not just fees. It's your operating account: sweep it regularly (e.g. daily in the pilot) to your OKX USDT deposit address on the **X Layer** network, sell for naira, and top up VTpass. Don't treat the balance as profit.
- **Without a Ledger (recommended for you):** a second keystore. Run `cast wallet new ~/.foundry/keystores paylight-treasury`, then confirm it with `cast wallet address --account paylight-treasury`. Back it up like the admin keystore.
- **With a Ledger:** use account index 1, from `cast wallet address --ledger --mnemonic-index 1`. You'll need `--mnemonic-index 1` on **every** command that sends from it.
- **Sending from the treasury:**
  - Command: `cast erc20 transfer 0x779Ded0c9e1022225f8E0630b35a9b54bE713736 <TO> <AMOUNT> --account paylight-treasury --rpc-url https://rpc.xlayer.tech`
  - AMOUNT is in raw units: 25 USD₮0 = `25000000`.
  - Give the treasury about 0.001 OKB of gas first; that covers hundreds of sweeps.
- If you haven't decided yet, the gateway can be deployed with treasury = the admin address and moved later with `setTreasury`.
- **Safe** does officially support X Layer (https://app.safe.global/welcome?chain=xlayer). Use "Pay now" (costs under a cent). It's an option for after the hackathon.
  - Keep the gateway **admin** on your Ledger, not a Safe, until after the deadline, so pause and refunds stay fast.
- **OKX Wallet:** use a seed-phrase wallet → **Add account**. Copy the **0x** form (switch away from the XKO-prefixed form).
- The treasury needs a little OKB later in order to *send* funds out, but not to receive them.

## 5. Send to Claude (public info only)

- Deployer/admin address and treasury address.
- The IGNIX team's reply about the factory.
- VTpass live status.
- After the processor launch (`docs/MAINNET_LAUNCH.md`): PROCESSOR, TRANSISTORS, FEE_CIRCUIT_ID and the three tx hashes.
- **Secrets** (VTpass keys) go in the cloud environment settings as `VTPASS_BASE_URL`, `VTPASS_API_KEY`, `VTPASS_PUBLIC_KEY`, `VTPASS_SECRET_KEY`.
