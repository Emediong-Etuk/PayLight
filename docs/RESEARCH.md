# PayLight — Phase 0 Research

_Last updated: 2026-10-03 (Sat), ~13:00 UTC. Author: Claude (lead engineer). Reviewer: Greg._

Every fact below comes from a source read in this session (URL in brackets, full list in [`SOURCES.md`](SOURCES.md)), or from a direct on-chain read I ran against X Layer mainnet (`https://rpc.xlayer.tech`, chainId 196, around block 72,263,000). On-chain reads are marked **[chain]**. Anything I could not confirm from a first-party source is marked **TODO(verify)**.

---

## 0. Headline findings (read these first)

1. **The hackathon window closes 2026-10-09 04:00 UTC (Fri 05:00 Lagos time).** That's about 5½ days from now, and today is a Saturday. Source: the IGNIX API that powers the campaign page countdown, `GET https://api.ignix.bot/v1/supernova/hackathon` → `{"startAt":"2026-09-22T04:00:00.000Z","endAt":"2026-10-09T04:00:00.000Z"}`. The brief never stated a date, so this changes the plan (see `DECISIONS.md` D-01).
2. **TapeOut is a separate protocol from the IGNIX token launchpad.** The brief assumed the "processor" is an ERC-20 asset ($LIGHT) launched on an IGNIX bonding curve with a USD₮0 quote. That is wrong:
   - A **processor** is a contract created by the **TapeOut factory**.
   - **Transistors** are that processor's **ERC-1155 tokens** (id 0 = NAND, id 1 = LATCH). They are minted at a **fixed price in native OKB** up to a **fixed supply cap**.
   - A **circuit** is an **ERC-721 NFT** minted by `tapeout(netlist, …)`. Taping out burns the transistors the design uses.
   - There's no bonding curve, no quote-token choice, no tax, no vault and no dividends on TapeOut assets.
   - The IGNIX launchpad docs never mention TapeOut. IGNIX only hosts the campaign.
3. **Our gateway or cashback contract cannot "be" the circuit.** A circuit is a netlist of NAND/LATCH gates stored on-chain. What we *can* do (verified on a mainnet fork) is tape out a small circuit and have our gateway **call it on-chain with `eval()` on every payment**. Proposal: a "FeeTier" circuit that decides each payer's fee tier. That makes the circuit genuinely part of the money path.
4. **USD₮0 on X Layer supports both EIP-2612 `permit` and EIP-3009 `receiveWithAuthorization`** [chain]. EIP-3009 lets users pay **without holding any OKB for gas**: they sign one message and our relayer submits it. That's a big UX win for Nigerian users.
5. **VTpass is suitable. The risk is time.** Going live needs sandbox testing first, then a request to VTpass support to provision live API access. Live calls can also fail on **IP whitelisting** (code 027) and **product whitelisting** (code 028). Greg needs to start this today. See §3.
6. **TapeOut is still upgradeable** (`isSealed() == false`) [chain]. A 3-of-5 Safe multisig controls the factory and both beacons [chain]. Our contracts must not *depend* on TapeOut to move money: the circuit call needs a safe fallback.
7. The public X Layer RPC limits **`eth_getLogs` to 100 blocks per request** [chain] and **100 requests/second per IP** [X Layer docs]. The worker's event listener must page through ranges, or we use a dedicated RPC provider.

---

## 1. TapeOut / IGNIX

### Q1. What exactly is a processor on-chain?

- The TapeOut whitepaper (Solana edition, same model) says: "A processor is an identity with its own transistor supply. Creating one stands up two … mints, NAND and LATCH … The creator sets the total supply and the price per transistor at creation, and both are permanent. Mint revenue is credited to the creator and withdrawable at any time." [tapeout.world/whitepaper]
- On **X Layer (EVM)**, I decoded the deployed bytecode against the 4byte/Sourcify signature database and checked live state [chain]:
  - **Processor contract** = a beacon proxy (implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` behind beacon `0xf70d1ed4f62cf3780157b0b421b7e2f45bd0991c`). It's an **ERC-721 collection of circuits**: `name`, `symbol`, `ownerOf`, `transferFrom`, `tokenURI`, `nextId`, plus `tapeout(bytes,uint32,uint32)`, `eval(uint256,bytes)`, `step(uint256,bytes,bytes)`, `netlist(uint256)`, `circuitInfo(uint256)`, `transistors()`, `TAPEOUT_FEE()`, `TREASURY()`, `sweepFees()`.
  - **Transistor contract** (one per processor) = a beacon proxy (implementation `0x265bf10faB9ddEC0eE0A649C6B9DB845f1b9a06b` behind beacon `0x1059ad62cabb6a6925bb65aa617300556c60a51b`). It's an **ERC-1155** with `NAND() = 0` and `LATCH() = 1`, `mint(uint256 id, uint256 amount)` (payable), `mintPrice()`, `supplyCap()`, `minted()`, `creator()`, `owed(address)`, `withdraw()`, `burnFrom(address,uint256,uint256)`, `protocolFee()`, `cpuName()`, `cpuSymbol()`, `story()`.
- **Owner/creator:** the wallet that calls `createCPU` becomes `creator()` and receives mint revenue through `owed(creator)` + `withdraw()`. I verified this on a mainnet fork: after a mint, `owed(creator)` equalled `mintPrice × amount`.
- **What's immutable:** the whitepaper says supply and price are "permanent". The current contracts expose no setter for `mintPrice` or `supplyCap`. However, **both beacons are upgradeable**: they're owned by the factory, whose owner can call `upgradeTransistors` / `upgradeCircuits`. The factory is a UUPS proxy (implementation `0x74956236ab64ed143933040b4137e8a352e4d17b`) [chain]. tapeout.world says plainly: "The protocol contracts are still upgradeable … Only after the formal seal will the factory and all logic be frozen forever." The factory's `isSealed()` currently returns `false` [chain]. So the parameters are permanent *as long as TapeOut doesn't upgrade*.
- Factory owner `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138` is a **Safe v1.4.1, threshold 3 of 5** [chain]. Its owners include `0x571d447f4f24688eC35Ccf07f1D6993655F6aF15`, which is also the factory's `protocolWallet()` and the creator of processor #0, "OnlyTestXLayer".

### Q2. What is a transistor?

A transistor is one unit of the processor's ERC-1155 supply. There are two token ids: **NAND (id 0)** and **LATCH (id 1)**. The NAND is the "primitive element" and the LATCH is "one cell of memory" [tapeout.world]. Both ids share **one supply counter** (`minted()` vs `supplyCap()`) and **one price** (`mintPrice()`). I verified both ids mint at the same price [chain, eth_call simulation]. Transistors are freely transferable ERC-1155 tokens. They are consumed (burned) when someone tapes out a circuit on that processor.

### Q3. TapeOut factory address on X Layer mainnet and its ABI

| Item | Value | How verified |
|---|---|---|
| TapeOut factory (proxy) | `0x1f09daefa827f02cbb40967cc91b259763760761` | Listed in TapeKit kernel `config.js` (a TapeOut-ecosystem gateway, "mainnet read-only checked 2026-09-19"). Code present on X Layer; `cpuCount() = 272`; processor #0 was created by TapeOut's own protocol wallet [chain]. |
| Factory implementation (ERC-1967 slot) | `0x74956236ab64ed143933040b4137e8a352e4d17b` | [chain] |
| Circuit beacon → impl | `0xf70d1ed4…0991c` → `0x977f2178…f29B2` | [chain] |
| Transistor beacon → impl | `0x1059ad62…0a51b` → `0x265bf10f…9a06b` | [chain] |
| Same addresses on Base (chainId 8453) | yes | TapeKit config |

**Status: TODO(verify).** The address is consistent across a TapeOut-ecosystem tool, on-chain state and 272 deployed processors. But **no first-party IGNIX or TapeOut page lists it**: the IGNIX "Deployments" page covers only the launchpad contracts, and tapeout.world currently shows its Solana devnet program. The contracts are **not source-verified** on Sourcify, and the OKLink explorer pages render client-side, so I couldn't read their source there. **Ask the IGNIX team in Telegram to confirm the factory address before mainnet** (in Greg's list).

**Factory ABI (recovered from bytecode, signatures hash-checked with `cast sig`):**

```solidity
function createCPU(string name, string symbol, string story, uint256 supplyCap, uint256 mintPrice) payable; // value = deployFee()
function cpuCount() view returns (uint256);
function cpuAt(uint256 index) view returns (address processor);
function cpus(uint256) view returns (address);
function isCPU(address) view returns (bool);
function deployFee() view returns (uint256);      // 0.0066 OKB on 2026-10-03
function protocolFee() view returns (uint256);    // 0.00066 OKB on 2026-10-03
function protocolWallet() view returns (address);
function isSealed() view returns (bool);          // false
function transistorBeacon() view returns (address);
function circuitBeacon() view returns (address);
function owed(address) view returns (uint256);
function withdraw();
// owner-only: setDeployFee, setProtocolFee, setProtocolWallet, upgradeTransistors, upgradeCircuits, seal, upgradeToAndCall, transferOwnership
```

The `createCPU` argument order was **verified on a mainnet fork (Anvil)**: `createCPU("PayLightTest","LIGHT","test story",21000,1e14)` produced `supplyCap()=21000` and `mintPrice()=1e14`, and `creator()` was the caller. It used about 693k gas.

### Q4. How are supply, unit price and cap set? Which are immutable? Pricing model?

- They're set once, in `createCPU(…, supplyCap, mintPrice)`. No setter exists (subject to the upgradeability caveat in Q1).
- **Pricing is a fixed price per transistor, paid in native OKB.** There's no bonding curve.
- **Exact mint cost** (verified with `eth_call` simulations on a live processor):
  `msg.value ≥ mintPrice × amount + protocolFee`
  `protocolFee` is a **flat 0.00066 OKB per `mint` call**, not per transistor. With 1 wei less, the call reverts with `"insufficient"`.
- **Cap** = `supplyCap`, the lifetime total of NAND + LATCH that can be minted. TapeOut has **no per-wallet cap and no allow-list**: anyone can mint any amount up to the remaining supply.
- `minted()` is a **lifetime counter**. Burning transistors in a tape-out does **not** free up supply (fork: `minted` stayed 7 after the 7 NANDs were burned).
- Mints are ERC-1155 *safe* mints to `msg.sender`. A contract minter must implement `IERC1155Receiver`; otherwise the mint reverts with `ERC1155InvalidReceiver` (observed on the fork).
- Observed in the wild [chain scan of all 272 processors]:
  - Typical caps are 10,000 to 1,000,000 (one processor set 9×10⁷⁶).
  - Typical prices are 0.000066 to 0.01 OKB.
  - Several processors priced at **0 were fully minted** almost immediately (e.g. "OnlyTestXLayer", 100,000/100,000).
  - So **a zero price invites supply squatting.**

### Q5. What is a circuit and how is it taped out?

- **What it is:** a circuit is an ERC-721 token in the processor's collection. Its netlist is stored on-chain and anyone can evaluate it. "What remains is a permanent circuit that anyone can call and nobody can alter." [whitepaper]
- **How to tape one out:** `tapeout(bytes netlist, uint32 nInputs, uint32 nOutputs)`, payable with `value = TAPEOUT_FEE()` = **0.0013 OKB** [chain]. Verified on a mainnet fork:
  - The caller's NAND balance on **that processor's** transistor contract dropped by exactly the number of NAND gates (10 → 6 for a 4-gate XOR).
  - Circuit NFT #1 was minted to the caller.
  - The call used about 252k gas.
  - Circuit ids start at 1. `nextId()` returns the latest id, which equals the number of circuits.
- **Netlist format** (matches the whitepaper; confirmed by reading live netlists and by our own fork tapeout):
  - Signal 0 is constant 0, signal 1 is constant 1. Signals 2 … (2+nInputs−1) are the inputs. Each element appends one output signal.
  - `NAND`: `0x00` followed by two 24-bit operands (7 bytes).
  - `LATCH`: `0x01` followed by one 24-bit operand (4 bytes).
  - `REF`: `0x02` followed by the processor address (20 bytes) and the circuit id. This embeds another circuit as a black box. The exact byte layout of REF arguments is TODO; we don't need it.
  - Outputs are read from the last `nOutputs` signals.
- **`circuitInfo(id)`** returns 4 words, inferred as `(nInputs, nOutputs, nLatches, nNands)` (e.g. the XOR returns `[2,1,0,4]`).
- **Evaluation:** `eval(uint256 id, bytes input) view returns (bytes)`. Inputs and outputs are **bit-packed, least-significant bit first**. Verified on the XOR circuit: `0x00→0x00`, `0x01→0x01`, `0x02→0x01`, `0x03→0x00`. A 4-gate eval cost about 55k gas. Because it's a `view`, **other contracts can call it on-chain**. `step(id, state, input)` exists for sequential (latch) circuits; its semantics are TODO and we don't need it.
- **Who can tape out:** anyone holding enough of that processor's transistors, plus the fee. The campaign FAQ: "Circuits can be your own or taped out by anyone on your processor."
- **Cost of a small circuit:** about 7 NAND transistors × mintPrice, plus 0.0013 OKB tape-out fee, plus gas (gas price is about 0.02 gwei, so gas is negligible).

### Q6. Can PayLight's own contract be the circuit? If not, what's the smallest meaningful circuit?

**No.** A circuit is a gate netlist, not an arbitrary contract. The brief's idea of registering the gateway or router "as the circuit" isn't possible.

**Proposed smallest meaningful circuit: `PayLight FeeTier v1`.** It's a combinational circuit of about 7 NANDs with 3 inputs and 2 outputs.
- **Inputs:**
  - `h1`: payer holds ≥ T1 PayLight transistors.
  - `h2`: payer holds ≥ T2 transistors.
  - `r`: payer has ≥ R settled orders on the gateway.
- **Output:** a 2-bit fee tier: `tier = h2 ? 2 : ((h1 OR r) ? 1 : 0)`.
- **How it's used:** `PayLightGateway.pay()` computes the three bits on-chain (ERC-1155 `balanceOf`, plus its own settled-order counter). It calls `processor.eval(feeCircuitId, bits)` and applies the admin-bounded fee for that tier.
- **Safety:** the call is wrapped in `try/catch`. If TapeOut ever reverts or is upgraded badly, payments still go through at the default tier (never above the signed `maxFee`).
- **Result:** every `OrderPaid` event records the tier the circuit computed, so judges can check that the circuit is used for real. Others can also `REF` our circuit.
- **Verified end to end on a mainnet fork (2026-10-03):**
  - The netlist is 7 NAND gates:
    `g5=NAND(2,2) g6=NAND(4,4) g7=NAND(5,6) g8=NAND(3,3) g9=NAND(7,8) g10=NAND(9,9) g11=NAND(8,8)`, hex
    `0x00000002000002000000040000040000000500000600000003000003000000070000080000000900000900000008000008`.
    It's taped out with `nInputs=3, nOutputs=2`.
  - `circuitInfo(1) = [3,2,0,7]`.
  - **All 8 input combinations returned the expected tier.** Input bit 0 = `h1`, bit 1 = `h2`, bit 2 = `r`. Output bit 0 = `lo`, bit 1 = `hi`.
  - Tape-out used about 256k gas, and each `eval` costs about 63k gas.

### Q7. Quote-token options

- **TapeOut:** there's no quote token. Mint price and fees are in **native OKB**. Cashback in transistors therefore needs OKB, not USD₮0. See `DECISIONS.md` D-05: the cashback reserve is funded once in OKB, so there's no per-order swap.
- **IGNIX launchpad (only relevant if we also launched an IGNIX ERC-20, which isn't recommended):** USD₮0 is a supported quote token (`0x779d…3736`) with an 8,000 USD₮0 graduation threshold. OKB has an 85 OKB threshold. Others are listed on the page [ignix.bot/docs/launching-a-token].

### Q8. How is the asset bought programmatically?

- **TapeOut transistors (the real asset):** `transistors.mint{value: mintPrice*amount + protocolFee}(id, amount)`. This is primary issuance from the contract at a fixed price, so there's no slippage, no deadline and no router. The minted tokens go to `msg.sender` through an ERC-1155 safe mint, so a contract receiver must implement `IERC1155Receiver` (confirmed on the fork: a receiver without it reverts with `ERC1155InvalidReceiver`). There's no official TapeOut market contract on X Layer that I could verify. tapeout.market exists (for BNB) but returned HTTP 429, and I haven't verified it.
- **IGNIX tokens (for reference only):**
  - **Before graduation:** `IgnixManager.buy(token, amountIn, minTokensOut)`, or `buyTo(token, amountIn, minTokensOut, recipient)` when calling from a contract.
  - **Transfer restriction:** pre-graduation launch tokens can only move to or from `IgnixManager` (`CurveOnly()` revert). So a cashback contract **cannot hold** them and must use `buyTo` straight to each user.
  - **No on-chain quote function:** the caller computes `minTokensOut` (round divisions up).
  - **After graduation:** Uniswap V4 (non-tax tokens) or V2 (fee-on-transfer tokens; exact-out is unsupported) [ignix.bot/docs/developers/curve-trading, token-types].

### Q9. Taxes, vaults, dividends

- **TapeOut:** none. Transistors are plain ERC-1155s with no transfer tax, no vault and no dividends. The only fees are the TapeOut protocol fee per mint call (0.00066 OKB), the tape-out fee (0.0013 OKB) and the processor deploy fee (0.0066 OKB). All three are owner-settable until the factory is sealed (`setProtocolFee`, `setDeployFee`; `TAPEOUT_FEE` lives in the circuit implementation).
- **IGNIX (for reference):**
  - Buy/sell tax runs 0–10% per side. There are four vault templates (System, Tokenized Stock, Tax Distribution, Directed).
  - Holder dividends stream linearly over 24h.
  - Excluded from dividends: the token contract, the curve, the primary V2 pool and burn addresses. Other contracts that hold the token *do* accrue dividends [ignix.bot/docs/tax-and-dividends].

### Q10. Events and HTTP API (for the transparency page)

- **TapeOut:** a fork tapeout emitted three logs: one on the transistor contract (topic `0xc3d58168…` = ERC-1155 `TransferSingle`, the burn), plus `Transfer` (`0xddf252ad…`, the ERC-721 mint) and one TapeOut-specific event (`0xc11215e4…`) on the processor. Mints emit ERC-1155 `TransferSingle` from `address(0)`. TapeOut has no HTTP API that I could find for X Layer. **For our transparency page we index our own contracts' events (OrderPaid, CashbackPaid, …) plus ERC-1155 `TransferSingle` on our transistor contract.**
- **IGNIX (for reference):** `TokenCreated`, `Trade`, `Graduated`/`GraduatedV2`, starting block 68,373,506. There's also a read-only HTTP API at `https://api.ignix.bot` (`/v1/launches`, `/v1/launches/{token}`, `/v1/launches/{token}/candles`).
- **RPC limits:** the public `eth_getLogs` caps ranges at **100 blocks** [chain, error `block range greater than 100 max`], and the rate limit is 100 requests/s per IP [X Layer RPC docs].

### Q11. Agent linking, Founder Round, Buyback Escrow

These are IGNIX launchpad features gated on linking an **OKX Agent** with escrow revenue. They don't apply to TapeOut processors or transistors. **Out of scope.**

### Q12. Is LIGHT / PayLight free?

- **TapeOut X Layer:** none of the 272 existing processors is named "PayLight" or uses the LIGHT symbol [chain scan]. TapeOut doesn't enforce unique names or symbols anyway.
- **IGNIX:** "PayLight" is free. **"LIGHT" is already taken** by "The Light of Consciousness" (`0x15724a5c2d23309eb6d6852ef0af6fc23fc0eeee`). I scanned all 7,312 launches via `/v1/launches`.
- **Proposal:** processor name **PayLight**, symbol **PLIGHT**. Alternatives: **WATT**, **PYLT**, **NEPA** (a Nigerian in-joke; check tone with Greg). Keeping LIGHT is allowed on TapeOut, but it could be confused with the IGNIX token.

---

## 2. X Layer

### Q13. Mainnet parameters

| Item | Value | Source |
|---|---|---|
| Chain ID | **196** (`0xC4`) | X Layer docs, plus `eth_chainId` [chain] |
| RPC | `https://rpc.xlayer.tech`, `https://xlayerrpc.okx.com` (100 req/s/IP) | X Layer RPC docs |
| Flashblocks RPC (200 ms preconfirmations, `pending` tag) | `https://rpc.xlayer.tech/flashblocks` | X Layer Flashblocks docs |
| Explorer | `https://www.okx.com/web3/explorer/xlayer` (also OKLink `https://www.oklink.com/x-layer`) | X Layer network info |
| Gas token | OKB | X Layer docs |
| Block time | **1.0 s** (1,000-block average) | [chain] |
| Gas price | about **0.02 gwei** | [chain] |
| `safe` head lag | about 234 blocks (~4 min) | [chain] |
| `finalized` head lag | about 1,160 blocks (~19 min) | [chain] |
| Verification (Foundry) | `forge verify-contract <addr> <path>:<Name> --verifier oklink --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER` (wait ≥1 min after deploy). The `chainShortName` "XLAYER" is TODO(verify) against the OKLink chain list; the endpoint answered for "XLAYER". An OKLink API key may be needed. | X Layer "Verify with Foundry" docs |

**Safe confirmation count (proposal, D-07):**
- X Layer is an OP-Stack rollup with a single sequencer. Our vending is irreversible.
- **Proposal:** vend after **3 blocks** on `latest` (about 3 s), with orders capped at the pilot limit. The reconciler re-checks every order against the **`safe`** head and raises an alert on any mismatch.
- Accounting is final at `finalized`.
- Waiting for `safe` before vending would add about 4 minutes to every purchase.

### Q14. Testnet

| Item | Value |
|---|---|
| Chain ID | 1952 (`0x7A0`) |
| RPC | `https://testrpc.xlayer.tech/terigon`, `https://xlayertestrpc.okx.com/terigon` |
| Explorer | `https://www.okx.com/web3/explorer/xlayer-test` |
| Faucet | `https://web3.okx.com/xlayer/faucet`: 0.2 test OKB per day |

**Important:** neither the TapeOut factory nor USD₮0 exists on testnet. `getCode` returns empty at both addresses on chainId 1952 [chain]. So **integration tests should run on an Anvil fork of mainnet** (real USD₮0 and real TapeOut), not on testnet. I've confirmed this works (§1 Q3/Q5).

### Q15. USD₮0 on X Layer

| Item | Value | Source |
|---|---|---|
| Address | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | X Layer "Contracts" page; IGNIX quote-token table (`0x779d…3736`); search result for docs.usdt0.to deployments |
| `name()` / `symbol()` | `USD₮0` / `USD₮0` | [chain] |
| `decimals()` | **6** | [chain] |
| Proxy implementation | `0x1ec7df9e74be05cb5a456aca2dc1ac2cec9ab6a3` (ERC-1967) | [chain] |
| EIP-2612 `permit(owner,spender,value,deadline,v,r,s)` | **Yes** (selector `0xd505accf` in the implementation; `nonces()` and `DOMAIN_SEPARATOR()` respond) | [chain] |
| EIP-712 domain | `name="USD₮0"`, `version="1"`, `chainId=196`, `verifyingContract=0x779D…3736`. The recomputed separator matches the on-chain `DOMAIN_SEPARATOR()` exactly (`0xd591d9ba…599d`). | [chain] |
| EIP-3009 `transferWithAuthorization` / `receiveWithAuthorization` | **Yes** (selectors `0xe3ee160e` and `0xef55bec6` present) | [chain] |
| Also present | `permit(address,address,uint256,uint256,bytes)` (bytes signature, ERC-1271-friendly) | [chain] |

Note that "USDT" on X Layer is a **different** token, `0x1E4a5963aBFD975d8c9021ce480b42188849D41d`. Users may hold the wrong one. The UI and /help must say **USD₮0** explicitly. OKX: "Simply deposit your old USDT back to exchange and withdraw via X Layer to receive the USDT0" [okx.com/help/usdt0-faq]. USD₮0, like USDT, can freeze addresses at the issuer level. That's an accepted risk, recorded in SECURITY later.

**Getting funds onto X Layer (for /help):**
- OKX lets you withdraw USDT on the X Layer network, and it arrives as USD₮0 [OKX FAQ].
- Exact withdrawal-UI wording for OKB on X Layer is **TODO(verify)**. Greg should screenshot the actual OKX app flow.
- If we ship EIP-3009 relaying (D-04), users need **no OKB at all**.

---

## 3. Bill provider (VTpass)

### Q16. Base URLs and auth

- **Sandbox:** `https://sandbox.vtpass.com/api/`
- **Live:** `https://vtpass.com/api/`
- **GET requests** use headers `api-key: …` and `public-key: PK_…`. **POST requests** use `api-key: …` and `secret-key: SK_…`.
- Keys are generated under Profile → API Keys. The secret key is shown once. "API AUTHENTICATION TYPE" must be set to "all" or "API keys" [vtpass.com/documentation/authentication].

### Q17. Endpoints

| Purpose | Method + path | Notes |
|---|---|---|
| Service categories | `GET /service-categories` | `electricity-bill` is the identifier |
| Discos + min/max amounts | `GET /services?identifier=electricity-bill` | returns `serviceID`, `minimium_amount` (sic), `maximum_amount`, `convinience_fee` |
| Verify meter | `POST /merchant-verify` with `{billersCode, serviceID, type: "prepaid"\|"postpaid"}` | returns `content.Customer_Name`, `Address`, `Meter_Type`, `Min_Purchase_Amount`, `MAX_Purchase_Amount`, `Customer_Account_Type` (MD/NMD), `WrongBillersCode` |
| Pay | `POST /pay` with `{request_id, serviceID, billersCode, variation_code: "prepaid", amount, phone}` | |
| Requery | `POST /requery` with `{request_id}` | |
| Wallet balance | `GET /balance` | returns `{"code":1,"contents":{"balance":…}}` |
| Webhook | A callback URL configured in the VTpass dashboard. VTpass POSTs JSON `{type, data, …}`, and we must reply `{"response":"success"}`; it retries up to 5 times. It carries transaction status updates (including reversals) and variation-code updates. | [callback docs] |

### Q18. `request_id` rules

- At least 12 characters. **The first 12 must be numeric** and must be **today's date and time in Africa/Lagos (GMT+1), as `YYYYMMDDHHmm`**. Any alphanumeric suffix may follow (e.g. `202202071830YUs83meikd`) [how-to-generate-request-id].
- Error 085 is returned if the date part is missing, malformed or not today. Error 014 means the request ID was already used.
- **Plan:** `YYYYMMDDHHmm` (Lagos) + 16 random hex characters. It's generated and saved in the DB **before** calling `/pay`, and it's unique per order.

### Q19. Electricity service IDs, variation codes, amounts, statuses, token location

**Service IDs (12 discos, each verified on its VTpass doc page):**

| Disco | serviceID |
|---|---|
| Ikeja (IKEDC) | `ikeja-electric` |
| Eko (EKEDC) | `eko-electric` |
| Abuja (AEDC) | `abuja-electric` |
| Kano (KEDCO) | `kano-electric` |
| Port Harcourt (PHED) | `portharcourt-electric` |
| Jos (JED) | `jos-electric` |
| Kaduna (KAEDCO) | `kaduna-electric` |
| Enugu (EEDC) | `enugu-electric` |
| Ibadan (IBEDC) | `ibadan-electric` |
| Benin (BEDC) | `benin-electric` |
| Aba | `aba-electric` |
| Yola (YEDC) | `yola-electric` |

- **Variation code:** `prepaid` (or `postpaid`). MVP supports prepaid only.
- **Min/max amounts:** per disco, from `GET /services?identifier=electricity-bill` plus per-meter `Min_Purchase_Amount` / `MAX_Purchase_Amount` from verify. Read these live; don't hardcode.
- **Response codes:**
  - `000` = processed; check `content.transactions.status`, which is `initiated`, `pending` or `delivered`.
  - `099` = processing, so requery.
  - `016` = failed. `091` = not processed (not charged).
  - Codes 010–035 and 083–089 are errors: e.g. 013/017 below the minimum / above the maximum, 018 low wallet balance, 019 likely duplicate within 30 s, 023 API access not enabled, **027 IP not whitelisted**, **028 product not whitelisted**, 030 biller unreachable, 034/035 service suspended/inactive.
  - `040` = reversal to wallet.
  - **VTpass's rule:** "Take any response that differs from the guidelines provided here as pending, and initiate a transaction requery … If transaction times out or response is not received, please treat as pending." [response-codes]
- **Where the token and units appear:**
  - Token: top-level `purchased_code` (e.g. `"Token: 35419981304203731832"` or `"Token : 2636…"`) and `token`. The token is sometimes prefixed with "Token :" and sometimes bare.
  - Units: `units` (e.g. `"8.2"` or `"79.9 kWh"`).
  - Also present: `tokenAmount`, `tariff`, `customerName`, `exchangeReference`, and `content.transactions.transactionId` (our provider transaction ID).
  - **The parser must tolerate both formats.**
- **Commission:** VTpass pays the merchant a commission (sandbox examples: PHED 2.00%, IKEDC 1.50%; rates differ by disco and MD/NMD). Live rates are at vtpass.com/commissions. That's extra margin on top of our fee.

### Q20. Sandbox simulation (prepaid)

| billersCode | Result |
|---|---|
| `1111111111111` | success, prepaid (verify + pay) |
| `1010101010101` | success, postpaid |
| `201000000000` | pending |
| `500000000000` | unexpected response |
| `400000000000` | no response |
| `300000000000` | timeout |
| any other number | failed (and verify fails) |

The sandbox account comes with a default wallet balance [PHED doc; integrating-api doc].

### Q21. Live-account approval ⚠️ the slowest dependency

- VTpass says: "After tests have been done successfully and integration completed on the sandbox, kindly request to be provisioned on our live environment." "You can get your live parameters by registering on the VTpass live platform, then request from our support team that your account be provisioned for API access. This will be done after some sandbox testing is completed." [integrating-api]
- **No timeline or KYC list is published.** I couldn't find one, so this is TODO(verify) with VTpass support. Contact: the email on the integrating-api page, or Skype "vtpass.techsupport".
- **Hidden gotchas from the response codes:**
  - 023: API access isn't enabled by default.
  - 027: the server IP must be whitelisted. **Our worker needs a static egress IP**, so the pay call should run from the worker on Railway/Fly with a static IP, not from Vercel serverless.
  - 028: each product must be whitelisted (ask for all 12 electricity products).
- **Funding:** the live VTpass wallet must be pre-funded in NGN. That's Greg's naira float.
- **Plan B if live access doesn't come in time:** a fallback provider. I did **not** verify an alternative's docs in this session: Fincra's energy doc URL returned 404, and ClubKonnect docs weren't found. So VTpass stays the default, and Greg should start live onboarding today (Saturday) so that Monday morning is spent on approval, not paperwork. If VTpass stalls by Tuesday, we re-evaluate.

---

## 4. Things I looked for and could not find

- A first-party TapeOut or IGNIX page listing X Layer TapeOut contract addresses. I found TapeKit config plus on-chain evidence only.
- A first-party TapeOut UI for X Layer. tapeout.world currently renders the Solana devnet version, and subdomains like xlayer.tapeout.world don't resolve. **We'll interact with the factory by script (`cast send`), which is allowed: the rule is "deployed through the TapeOut factory", not "through a UI".** TODO(verify) with the IGNIX team that a factory-direct deployment counts.
- Verified source code for TapeOut contracts. The ABI was recovered from bytecode selectors, and behaviour was confirmed by fork simulation.
- The VTpass live approval timeline and KYC requirements.
- Exact OKX app wording for withdrawing OKB/USD₮0 to X Layer.
