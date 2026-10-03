# Mainnet launch: PayLight processor + FeeTier circuit

These are the exact commands for Greg to run **on his own computer** from the **deployment wallet**. Never run them from a cloud session, and never paste a private key anywhere.

The parameters are the approved values from [`PROCESSOR_PARAMS.md`](PROCESSOR_PARAMS.md). Every command below was dry-run verbatim on an Anvil fork of X Layer mainnet on 2026-10-03: createCPU, mint and tapeout all succeeded; eval returned `00 01 02 02 01 01 02 02`; total spend was 0.00928 OKB, of which 0.0007 OKB is owed back to the creator.

> ℹ️ The IGNIX team hadn't confirmed the factory address. Greg decided to proceed with it on 2026-10-03, based on on-chain evidence ([`DECISIONS.md`](DECISIONS.md) D-14).
>
> Each step costs real OKB. Total ≈ 0.0066 + 0.00136 + 0.0013 ≈ **0.0093 OKB** plus negligible gas. The 0.0007 OKB mint price comes back to you as the processor creator.

## 0. One-time setup (on your laptop)

```bash
# Install Foundry (macOS / Linux / WSL2)
curl -L https://foundry.paradigm.xyz | bash
foundryup

export RPC=https://rpc.xlayer.tech
export FACTORY=0x1f09daefa827f02cbb40967cc91b259763760761

# Pick ONE signer and set SIGNER accordingly:
#   Ledger (Ethereum app open on the device):
export SIGNER="--ledger"
#   …or an encrypted Foundry keystore you created with `cast wallet import paylight-deployer --interactive`:
# export SIGNER="--account paylight-deployer"

export DEPLOYER=0xYOUR_DEPLOYMENT_WALLET   # the public address only

# Sanity checks
cast chain-id --rpc-url $RPC                                   # expect 196
cast balance $DEPLOYER --rpc-url $RPC --ether                  # expect >= 0.02
cast call $FACTORY "deployFee()(uint256)" --rpc-url $RPC        # expect 6600000000000000 (0.0066 OKB); if different, stop and tell Claude
cast call $FACTORY "isSealed()(bool)" --rpc-url $RPC            # currently false (TapeOut is still upgradeable)
```

## 1. Create the processor (`createCPU`)

```bash
cast send $FACTORY \
  "createCPU(string,string,string,uint256,uint256)" \
  "PayLight" "PLIGHT" \
  "Pay for prepaid electricity in Nigeria with USD₮0 on X Layer. PayLight transistors are earned as customer cashback and unlock lower fees through the PayLight FeeTier circuit." \
  1000000 100000000000000 \
  --value $(cast call $FACTORY "deployFee()(uint256)" --rpc-url $RPC | awk '{print $1}') \
  --rpc-url $RPC $SIGNER
```

- `1000000` is the supply cap.
- `100000000000000` wei is 0.0001 OKB, the unit price.
- Both values are permanent.

**Find your processor.** Search the newest processors for one created by your wallet:

```bash
N=$(cast call $FACTORY "cpuCount()(uint256)" --rpc-url $RPC | awk '{print $1}')
for i in $(seq $((N-1)) -1 $((N>10 ? N-10 : 0))); do
  P=$(cast call $FACTORY "cpuAt(uint256)(address)" $i --rpc-url $RPC)
  T=$(cast call $P "transistors()(address)" --rpc-url $RPC)
  C=$(cast call $T "creator()(address)" --rpc-url $RPC)
  if [ "$(echo $C | tr A-F a-f)" = "$(echo $DEPLOYER | tr A-F a-f)" ]; then echo "PROCESSOR=$P TRANSISTORS=$T (index $i)"; break; fi
done
export PROCESSOR=0x...     # paste from the output
export TRANSISTORS=0x...   # paste from the output
```

**Verify:**

```bash
cast call $PROCESSOR "name()(string)" --rpc-url $RPC              # "PayLight"
cast call $PROCESSOR "symbol()(string)" --rpc-url $RPC            # "PLIGHT"
cast call $TRANSISTORS "supplyCap()(uint256)" --rpc-url $RPC      # 1000000
cast call $TRANSISTORS "mintPrice()(uint256)" --rpc-url $RPC      # 100000000000000
cast call $TRANSISTORS "creator()(address)" --rpc-url $RPC        # your DEPLOYER
```

## 2. Mint 7 NAND transistors (for the circuit)

The cost is `7 × mintPrice + protocolFee`, where the protocol fee is a flat charge per mint call:

```bash
FEE=$(cast call $TRANSISTORS "protocolFee()(uint256)" --rpc-url $RPC | awk '{print $1}')
cast send $TRANSISTORS "mint(uint256,uint256)" 0 7 \
  --value $((7 * 100000000000000 + FEE)) \
  --rpc-url $RPC $SIGNER

cast call $TRANSISTORS "balanceOf(address,uint256)(uint256)" $DEPLOYER 0 --rpc-url $RPC   # 7
```

## 3. Tape out "PayLight FeeTier v1"

```bash
cast send $PROCESSOR "tapeout(bytes,uint32,uint32)" \
  0x00000002000002000000040000040000000500000600000003000003000000070000080000000900000900000008000008 \
  3 2 \
  --value $(cast call $PROCESSOR "TAPEOUT_FEE()(uint256)" --rpc-url $RPC | awk '{print $1}') \
  --rpc-url $RPC $SIGNER
```

**Verify:**

```bash
cast call $PROCESSOR "nextId()(uint256)" --rpc-url $RPC            # 1  -> FEE_CIRCUIT_ID=1
cast call $PROCESSOR "ownerOf(uint256)(address)" 1 --rpc-url $RPC   # your DEPLOYER
cast call $TRANSISTORS "balanceOf(address,uint256)(uint256)" $DEPLOYER 0 --rpc-url $RPC   # 0 (all 7 burned)
for x in 00 01 02 03 04 05 06 07; do echo "in=0x$x -> $(cast call $PROCESSOR 'eval(uint256,bytes)(bytes)' 1 0x$x --rpc-url $RPC)"; done
# expected: 00 01 02 02 01 01 02 02
```

## 4. Send Claude these public values

`PROCESSOR`, `TRANSISTORS`, `FEE_CIRCUIT_ID` (should be 1), and the three transaction hashes. Claude records them in `deployments/196.json` and on `/light`. You then post the disclosure from [`PROCESSOR_PARAMS.md`](PROCESSOR_PARAMS.md) §6.

> At this point the "processor deployed through the TapeOut factory" and "at least one circuit taped out" requirements are both met on mainnet. The gateway and router get deployed later, after Checkpoint 1.
