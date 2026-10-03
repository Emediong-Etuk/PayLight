# Urgent owner actions: how-to and double-check list

_Researched 2026-10-03 by a 4-researcher workflow._
- The **VTpass** section was independently verified, and its corrections are applied below.
- The **funding**, **wallet** and **treasury** sections were researched but their verification pass was cut off by a usage limit. Treat them as "likely": every step cites first-party pages, but nobody re-checked them.
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
  - our **static server IP** for whitelisting (I'll send it once Railway is up);
  - the callback URL (comes later);
  - the 9 Oct deadline.
  - **Never** send the secret key, BVN or NIN.
- **Follow up** by phone on **07080631810** or via live chat on vtpass.com (listed as 24/7). The Skype handle in their docs is dead; Microsoft retired Skype in May 2025.
- **Keys:** the PK_ and SK_ keys are shown only once. Sandbox keys don't work against live (error 087), and vice versa.
- **Funding:** use the dedicated account number or **Credit Wallet**. **Never** pay into bank accounts listed in old VTpass blog posts. Start with a small float, because over-funding past your customer class can lock the wallet.
- **Commission:** the API column at https://www.vtpass.com/commissions. Ikeja and PHED pay **0% on MD meters**; AEDC is capped at ₦1,300 and Ikeja at ₦1,500.
- **No published turnaround** exists for live provisioning. We'll make sure the full demo also works on the **sandbox** (meter `1111111111111` returns a token) as a fallback.

## 2. Getting OKB and USD₮0 onto X Layer (likely; not independently re-verified)

- ⚠️ **Withdrawing USDT from OKX:** pick the network labelled **"X Layer (USDT0)"**. In your wallet the token must show as **USD₮0** (with ₮), contract `0x779Ded0c9e1022225f8E0630b35a9b54bE713736`. Plain **"USDT"** on X Layer (`0x1E4a…D41d`) is the legacy token being phased out, and PayLight doesn't accept it.
- **OKB:** in OKX go to Assets → Withdraw → OKB → on-chain → network **X Layer** (may be labelled "X Layer (OKB)") → paste your 0x address. Read the fee and minimum on the screen. An ERC-20 OKB withdrawal from another exchange lands on Ethereum, **not** X Layer.
- **Send a small test first,** check it on the explorer, then send the rest. Your address page is `https://web3.okx.com/explorer/x-layer/evm/address/<YOUR_ADDR>`.
- **Withdrawal locks:** changing your password, phone or 2FA blocks withdrawals for 24h. The "New address withdrawal lock" also holds newly added addresses for 24h. USDT bought via P2P can carry a T+N hold.
- **If OKX doesn't work for you:** Gate lists OKB withdrawals on X Layer, but has no USD₮0 on X Layer. Bitget, KuCoin and HTX don't support X Layer for these assets.
- **Cost check:** OKB ≈ 120 USDT (OKX ticker, 2026-10-03), so the ≈2.1 OKB budget is about $250. **2.0 OKB of that is the first cashback reserve tranche**, and it comes back to you as creator revenue. To cut the up-front cash, the first tranche can be 5,000 transistors (≈0.5 OKB) instead of 20,000.
- **Read-only balance checks** (no keys needed):
  `cast balance <ADDR> --ether --rpc-url https://rpc.xlayer.tech` (shows OKB)
  `cast erc20 balance 0x779Ded0c9e1022225f8E0630b35a9b54bE713736 <ADDR> --rpc-url https://rpc.xlayer.tech` (6 decimals)

## 3. Deployment / admin wallet (likely)

- **Install Foundry:** `curl -L https://getfoundry.sh/install | bash`, then add `export PATH="$PATH:$HOME/.foundry/bin"` to `~/.zshrc` or `~/.bashrc`, then run `foundryup`. On Windows, use **WSL2**.
- **Ledger:**
  - Install the **Ethereum** app. It also signs for X Layer (chain 196).
  - Get your address with `cast wallet address --ledger`, which uses the Ledger Live path index 0.
  - Test the connection for free with `cast wallet sign "PayLight ledger test" --ledger`.
  - ⚠️ **Enable Blind signing** in the Ethereum app's settings, or contract calls (createCPU, mint, tapeout, deploy) get rejected. It switches itself off after app or firmware updates.
  - **Close Ledger Live and MetaMask** while using cast.
  - In WSL2, the Ledger needs **usbipd-win** to pass the USB device through.
- **Keystore (no Ledger):**
  1. `mkdir -p ~/.foundry/keystores`
  2. `cast wallet new ~/.foundry/keystores paylight-admin` (the key is never shown)
  3. **Immediately** run `cast wallet address --account paylight-admin` to confirm the password works (it's asked only once).
  - There's no seed phrase, so back up the keystore file and its password offline.
- **Never** use `--private-key` or `--unsafe-password` on the command line (they end up in shell history), and never run `cast wallet new` without a folder (it prints the key).

## 4. Treasury (likely)

- **Recommended:** a second Ledger account, from `cast wallet address --ledger --mnemonic-index 1`. It's free and keeps fee income separate from the published deployer wallet.
- **Safe** does officially support X Layer (https://app.safe.global/welcome?chain=xlayer). Use "Pay now" (costs under a cent).
  - Strip the `xlayer:` prefix when copying addresses.
  - Keep the gateway **admin** on your Ledger, not a Safe, until after the deadline, so pause and refunds stay fast.
- **OKX Wallet:** use a seed-phrase wallet → **Add account**. Copy the **0x** form (switch away from the XKO-prefixed form).
- The treasury needs a little OKB later in order to *send* funds out, but not to receive them.

## 5. Send to Claude (public info only)

- Deployer/admin address and treasury address.
- The IGNIX team's reply about the factory.
- VTpass live status.
- After the processor launch (`docs/MAINNET_LAUNCH.md`): PROCESSOR, TRANSISTORS, FEE_CIRCUIT_ID and the three tx hashes.
- **Secrets** (VTpass keys) go in the cloud environment settings as `VTPASS_BASE_URL`, `VTPASS_API_KEY`, `VTPASS_PUBLIC_KEY`, `VTPASS_SECRET_KEY`.
