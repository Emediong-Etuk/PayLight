// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/console2.sol";

import {ITapeOutFactory, ITapeOutProcessor, ITapeOutTransistors} from "../src/interfaces/ITapeOut.sol";
import {FeeTierCircuit} from "../src/libraries/FeeTierCircuit.sol";

/// @dev ERC-721 metadata of a TapeOut processor (not part of ITapeOutProcessor).
interface ITapeOutProcessorMeta {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/// @title ProcessorLauncher
/// @notice Core logic of the PayLight processor launch (docs/PROCESSOR_PARAMS.md §1 and §4 steps 1-2,
///         docs/MAINNET_LAUNCH.md): createCPU with the APPROVED parameters, mint 7 NAND, tape out "PayLight FeeTier v1".
/// @dev    Kept free of broadcast cheatcodes so the mainnet-fork test (test/fork/PayLightFork.t.sol) runs exactly this
///         code under `vm.startPrank(deployer, deployer)`. Every external call is made by the current caller (the
///         broadcaster in a script, the pranked deployer in the test), so `creator()` is the deployer's own wallet.
abstract contract ProcessorLauncher is CommonBase {
    /// @notice TapeOut factory proxy on X Layer mainnet (chainId 196).
    address internal constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    uint256 internal constant LAUNCH_CHAIN_ID = 196;

    // ── APPROVED processor parameters (docs/PROCESSOR_PARAMS.md §1, approved by Greg 2026-10-03). Permanent once used.
    string internal constant PROCESSOR_NAME = "PayLight";
    string internal constant PROCESSOR_SYMBOL = "PLIGHT";
    string internal constant PROCESSOR_STORY =
        unicode"Pay for prepaid electricity in Nigeria with USD₮0 on X Layer. PayLight transistors are earned as customer cashback and unlock lower fees through the PayLight FeeTier circuit.";
    uint256 internal constant PROCESSOR_SUPPLY_CAP = 1_000_000;
    uint256 internal constant PROCESSOR_MINT_PRICE = 0.0001 ether; // 100000000000000 wei
    uint256 internal constant NAND = 0;
    /// @dev Upper bound on circuit ids scanned when resuming a launch.
    uint256 internal constant MAX_CIRCUIT_SCAN = 32;

    struct Launch {
        address processor;
        address transistors;
        uint256 circuitId;
        /// @dev True if the FeeTier circuit already existed (resume) and no new tape-out was done.
        bool circuitReused;
        /// @dev Native OKB the deployer's wallet sent to TapeOut contracts in this launch (excludes gas).
        uint256 okbSent;
    }

    error WrongChain(uint256 chainId);
    error CpuCountMismatch(uint256 countBefore, uint256 countAfter);
    error NotTapeOutProcessor(address processor);
    error NotProcessorCreator(address processor, address creator, address expected);
    error ProcessorParamMismatch(string field);
    error CircuitOwnerMismatch(uint256 circuitId, address owner, address expected);
    error FeeTierEvalMismatch(uint256 circuitId, uint8 input);

    // ─────────────────────────────────────────────────────────────── core

    /// @notice Step 1 + step 2 in one go: createCPU, then mint 7 NAND and tape out FeeTier.
    function _launchProcessor(address deployer) internal returns (Launch memory l) {
        uint256 okbBefore = deployer.balance;
        l.processor = _createProcessor(deployer);
        (l.transistors, l.circuitId) = _tapeoutFeeTier(l.processor, deployer);
        l.okbSent = okbBefore - deployer.balance;
    }

    /// @notice Resume a launch on an EXISTING processor created by `deployer`: reuse an already taped-out FeeTier
    ///         circuit owned by `deployer` if there is one, otherwise mint what is missing and tape out.
    function _resumeLaunch(address processor, address deployer) internal returns (Launch memory l) {
        uint256 okbBefore = deployer.balance;
        l.processor = processor;
        l.transistors = _verifyProcessor(processor, deployer);
        uint256 existing = _findFeeTierCircuit(processor, deployer);
        if (existing != 0) {
            l.circuitId = existing;
            l.circuitReused = true;
        } else {
            (, l.circuitId) = _tapeoutFeeTier(processor, deployer);
        }
        l.okbSent = okbBefore - deployer.balance;
    }

    /// @notice createCPU with the approved parameters, paying exactly `deployFee()`. Returns the new processor.
    function _createProcessor(address deployer) internal returns (address processor) {
        ITapeOutFactory factory = ITapeOutFactory(TAPEOUT_FACTORY);
        uint256 countBefore = factory.cpuCount();
        factory.createCPU{value: factory.deployFee()}(
            PROCESSOR_NAME, PROCESSOR_SYMBOL, PROCESSOR_STORY, PROCESSOR_SUPPLY_CAP, PROCESSOR_MINT_PRICE
        );
        uint256 countAfter = factory.cpuCount();
        if (countAfter != countBefore + 1) revert CpuCountMismatch(countBefore, countAfter);
        processor = factory.cpuAt(countAfter - 1);
        _verifyProcessor(processor, deployer);
    }

    /// @notice Mint the NAND the FeeTier netlist needs (only what the deployer lacks) and tape it out.
    function _tapeoutFeeTier(address processor, address deployer)
        internal
        returns (address transistors, uint256 circuitId)
    {
        transistors = _verifyProcessor(processor, deployer);
        ITapeOutTransistors t = ITapeOutTransistors(transistors);
        uint256 have = t.balanceOf(deployer, NAND);
        if (have < FeeTierCircuit.NAND_COUNT) {
            uint256 need = FeeTierCircuit.NAND_COUNT - have;
            t.mint{value: t.mintPrice() * need + t.protocolFee()}(NAND, need);
        }
        ITapeOutProcessor p = ITapeOutProcessor(processor);
        p.tapeout{value: p.TAPEOUT_FEE()}(FeeTierCircuit.NETLIST, FeeTierCircuit.N_INPUTS, FeeTierCircuit.N_OUTPUTS);
        circuitId = p.nextId();
        address owner = p.ownerOf(circuitId);
        if (owner != deployer) revert CircuitOwnerMismatch(circuitId, owner, deployer);
        _assertFeeTierTruthTable(processor, circuitId);
    }

    // ─────────────────────────────────────────────────────────────── checks

    /// @notice Reverts unless `processor` is a TapeOut processor created by `deployer` with the approved parameters.
    function _verifyProcessor(address processor, address deployer) internal view returns (address transistors) {
        if (!ITapeOutFactory(TAPEOUT_FACTORY).isCPU(processor)) revert NotTapeOutProcessor(processor);
        transistors = ITapeOutProcessor(processor).transistors();
        ITapeOutTransistors t = ITapeOutTransistors(transistors);
        address creator = t.creator();
        if (creator != deployer) revert NotProcessorCreator(processor, creator, deployer);
        if (!_eq(ITapeOutProcessorMeta(processor).name(), PROCESSOR_NAME)) revert ProcessorParamMismatch("name");
        if (!_eq(ITapeOutProcessorMeta(processor).symbol(), PROCESSOR_SYMBOL)) revert ProcessorParamMismatch("symbol");
        if (t.supplyCap() != PROCESSOR_SUPPLY_CAP) revert ProcessorParamMismatch("supplyCap");
        if (t.mintPrice() != PROCESSOR_MINT_PRICE) revert ProcessorParamMismatch("mintPrice");
    }

    /// @notice Reverts unless circuit `circuitId` evaluates FeeTierCircuit.expectedTier for all 8 inputs.
    function _assertFeeTierTruthTable(address processor, uint256 circuitId) internal view {
        for (uint8 x; x < 8; ++x) {
            if (!_evalMatches(processor, circuitId, x)) revert FeeTierEvalMismatch(circuitId, x);
        }
    }

    /// @return id The lowest circuit id owned by `deployer` that behaves as FeeTier v1, or 0 if none.
    function _findFeeTierCircuit(address processor, address deployer) internal view returns (uint256 id) {
        ITapeOutProcessor p = ITapeOutProcessor(processor);
        uint256 last = p.nextId();
        if (last > MAX_CIRCUIT_SCAN) last = MAX_CIRCUIT_SCAN;
        for (uint256 i = 1; i <= last; ++i) {
            try p.ownerOf(i) returns (address owner) {
                if (owner != deployer) continue;
            } catch {
                continue;
            }
            bool all = true;
            for (uint8 x; x < 8 && all; ++x) {
                all = _evalMatches(processor, i, x);
            }
            if (all) return i;
        }
    }

    function _evalMatches(address processor, uint256 circuitId, uint8 x) internal view returns (bool) {
        try ITapeOutProcessor(processor).eval(circuitId, abi.encodePacked(x)) returns (bytes memory out) {
            return out.length == 1 && uint8(out[0]) == FeeTierCircuit.expectedTier(x);
        } catch {
            return false;
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _logLaunch(Launch memory l, address deployer) internal pure {
        console2.log("deployer (creator)  :", deployer);
        console2.log("PROCESSOR           :", l.processor);
        console2.log("TRANSISTORS         :", l.transistors);
        console2.log("FEE_CIRCUIT_ID      :", l.circuitId);
        console2.log("circuit reused      :", l.circuitReused);
        console2.log("OKB sent (wei, excl. gas):", l.okbSent);
        console2.log(
            "Next: export PROCESSOR=%s FEE_CIRCUIT_ID=%s, then run script/Deploy.s.sol", l.processor, l.circuitId
        );
    }
}

/// @title LaunchProcessor
/// @notice Greg's PayLight processor launch, from his DEPLOYMENT WALLET (it becomes the processor `creator()` and
///         receives mint revenue). Spends ≈ 0.0066 (deployFee) + 0.00136 (7 NAND + protocol fee) + 0.0013 (tape-out)
///         ≈ 0.0093 OKB plus gas. No private key is ever read by this script.
///
/// DRY RUN (simulates on a fork of mainnet, sends nothing; DEPLOYER must hold >= 0.01 OKB on mainnet because the
/// fork reads real balances):
///   export DEPLOYER=0xYOUR_DEPLOYMENT_WALLET            # public address only
///   forge script script/LaunchProcessor.s.sol --fork-url https://rpc.xlayer.tech --sender $DEPLOYER -vvvv
///
/// BROADCAST (Greg's own computer only, after "yes, run it"):
///   forge script script/LaunchProcessor.s.sol --rpc-url https://rpc.xlayer.tech --broadcast --ledger --sender $DEPLOYER
///   # or with an encrypted Foundry keystore (`cast wallet import paylight-deployer --interactive`):
///   forge script script/LaunchProcessor.s.sol --rpc-url https://rpc.xlayer.tech --broadcast \
///     --account paylight-deployer --sender $DEPLOYER
///   Never use --private-key or --unsafe-password.
///
/// SAFEST (two broadcasts): the factory deploys processors with CREATE, so the processor address depends on the
/// factory's nonce. In the one-shot run above, the mint/tape-out transactions target the address seen in simulation;
/// if somebody else's createCPU lands between our createCPU and those transactions, they would go to the wrong
/// processor (worst case ≈ 0.003 OKB lost; rerun step 2). To rule that out entirely:
///   1) forge script script/LaunchProcessor.s.sol --sig "createProcessor()" --rpc-url https://rpc.xlayer.tech \
///        --broadcast --ledger --sender $DEPLOYER                  # logs PROCESSOR
///   2) PROCESSOR=0x... forge script script/LaunchProcessor.s.sol --rpc-url https://rpc.xlayer.tech \
///        --broadcast --ledger --sender $DEPLOYER                  # verifies creator, mints 7 NAND, tapes out
/// Re-running step 2 is safe: if a FeeTier circuit owned by the deployer already exists it is reused, not re-taped.
contract LaunchProcessor is Script, ProcessorLauncher {
    /// @notice Full launch, or (with env PROCESSOR set) resume on an existing processor created by the broadcaster.
    function run() external returns (Launch memory l) {
        if (block.chainid != LAUNCH_CHAIN_ID) revert WrongChain(block.chainid);
        address existing = vm.envOr("PROCESSOR", address(0));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        l = existing == address(0) ? _launchProcessor(deployer) : _resumeLaunch(existing, deployer);
        vm.stopBroadcast();
        _logLaunch(l, deployer);
    }

    /// @notice Step 1 of the two-broadcast route: createCPU only.
    function createProcessor() external returns (address processor) {
        if (block.chainid != LAUNCH_CHAIN_ID) revert WrongChain(block.chainid);
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        processor = _createProcessor(deployer);
        vm.stopBroadcast();
        console2.log("deployer (creator):", deployer);
        console2.log("PROCESSOR         :", processor);
        console2.log("TRANSISTORS       :", ITapeOutProcessor(processor).transistors());
        console2.log("Next: PROCESSOR=%s forge script script/LaunchProcessor.s.sol ... --broadcast", processor);
    }
}
