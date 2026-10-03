// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {CommonBase} from "forge-std/Base.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PayLightGateway} from "../src/PayLightGateway.sol";
import {CashbackRouter} from "../src/CashbackRouter.sol";
import {ITapeOutProcessor} from "../src/interfaces/ITapeOut.sol";
import {FeeTierCircuit} from "../src/libraries/FeeTierCircuit.sol";

/// @title PayLightDeployer
/// @notice Core deployment logic for PayLightGateway + CashbackRouter, shared by `Deploy.run()` and the mainnet-fork
///         test (test/fork/PayLightFork.t.sol), which calls `_deploy` under `vm.startPrank(deployer, deployer)`.
/// @dev    No broadcast cheatcodes and no file writes in here: `run()` owns both.
abstract contract PayLightDeployer is CommonBase {
    /// @notice USD₮0 on X Layer mainnet (6 decimals, EIP-2612 + EIP-3009).
    address internal constant XLAYER_USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    uint256 internal constant XLAYER_CHAIN_ID = 196;
    string internal constant XLAYER_RPC = "https://rpc.xlayer.tech";
    uint8 internal constant USDT0_DECIMALS = 6;

    // ── APPROVED defaults (docs/PROCESSOR_PARAMS.md §2). Each can be overridden by the env var named in _loadConfig.
    uint16 internal constant DEFAULT_TIER0_BPS = 100; // 1.00%
    uint16 internal constant DEFAULT_TIER1_BPS = 50; // 0.50%
    uint16 internal constant DEFAULT_TIER2_BPS = 25; // 0.25%
    uint128 internal constant DEFAULT_TIER1_HOLDING = 50;
    uint128 internal constant DEFAULT_TIER2_HOLDING = 500;
    uint32 internal constant DEFAULT_REPEAT_ORDERS = 3;
    uint128 internal constant DEFAULT_MAX_ORDER_AMOUNT = 30e6; // 30 USD₮0
    uint128 internal constant DEFAULT_DAILY_VOLUME_CAP = 1_000e6; // 1,000 USD₮0
    uint64 internal constant DEFAULT_REFUND_TIMEOUT = 24 hours;
    uint256 internal constant DEFAULT_MAX_RESERVE_MINT = 200_000; // 20% of the 1,000,000 supply cap

    struct DeployConfig {
        address usdt0;
        address processor;
        uint256 feeCircuitId;
        address admin;
        address operator;
        address keeper;
        address treasury;
        address quoteSigner;
        uint16[3] tierFeeBps;
        uint128 tier1Holding;
        uint128 tier2Holding;
        uint32 repeatOrders;
        uint128 maxOrderAmount;
        uint128 dailyVolumeCap;
        uint64 refundTimeout;
        uint256 maxReserveMint;
    }

    struct Deployment {
        PayLightGateway gateway;
        CashbackRouter router;
        address transistors;
        address deployer;
        /// @dev True if `gateway.setCashbackRouter(router)` was executed (only possible when deployer == admin).
        bool routerWired;
        uint256 chainId;
        uint256 blockNumber;
        uint256 timestamp;
    }

    error MissingUsdt0(uint256 chainId);
    error NoCode(string what, address account);
    error WrongDecimals(uint8 decimals);
    error EnvValueTooLarge(string name, uint256 value);
    error FeeCircuitInvalid(uint256 circuitId, uint8 input);
    error DeploymentsDirMissing(string fix);

    // ─────────────────────────────────────────────────────────────── config

    /// @notice Reads the deployment config from the environment.
    ///         Required: PROCESSOR, FEE_CIRCUIT_ID, ADMIN, OPERATOR, KEEPER, TREASURY, QUOTE_SIGNER.
    ///         Optional (approved defaults): USDT0 (real USD₮0 on chainId 196, required elsewhere), TIER0_BPS,
    ///         TIER1_BPS, TIER2_BPS, TIER1_HOLDING, TIER2_HOLDING, REPEAT_ORDERS, MAX_ORDER_AMOUNT, DAILY_VOLUME_CAP,
    ///         REFUND_TIMEOUT (seconds), MAX_RESERVE_MINT.
    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.usdt0 = vm.envOr("USDT0", block.chainid == XLAYER_CHAIN_ID ? XLAYER_USDT0 : address(0));
        if (cfg.usdt0 == address(0)) revert MissingUsdt0(block.chainid);
        cfg.processor = vm.envAddress("PROCESSOR");
        cfg.feeCircuitId = vm.envUint("FEE_CIRCUIT_ID");
        cfg.admin = vm.envAddress("ADMIN");
        cfg.operator = vm.envAddress("OPERATOR");
        cfg.keeper = vm.envAddress("KEEPER");
        cfg.treasury = vm.envAddress("TREASURY");
        cfg.quoteSigner = vm.envAddress("QUOTE_SIGNER");

        // Each narrowing cast below is bounded by _envUintMax.
        // forge-lint: disable-start(unsafe-typecast)
        cfg.tierFeeBps[0] = uint16(_envUintMax("TIER0_BPS", DEFAULT_TIER0_BPS, type(uint16).max));
        cfg.tierFeeBps[1] = uint16(_envUintMax("TIER1_BPS", DEFAULT_TIER1_BPS, type(uint16).max));
        cfg.tierFeeBps[2] = uint16(_envUintMax("TIER2_BPS", DEFAULT_TIER2_BPS, type(uint16).max));
        cfg.tier1Holding = uint128(_envUintMax("TIER1_HOLDING", DEFAULT_TIER1_HOLDING, type(uint128).max));
        cfg.tier2Holding = uint128(_envUintMax("TIER2_HOLDING", DEFAULT_TIER2_HOLDING, type(uint128).max));
        cfg.repeatOrders = uint32(_envUintMax("REPEAT_ORDERS", DEFAULT_REPEAT_ORDERS, type(uint32).max));
        cfg.maxOrderAmount = uint128(_envUintMax("MAX_ORDER_AMOUNT", DEFAULT_MAX_ORDER_AMOUNT, type(uint128).max));
        cfg.dailyVolumeCap = uint128(_envUintMax("DAILY_VOLUME_CAP", DEFAULT_DAILY_VOLUME_CAP, type(uint128).max));
        cfg.refundTimeout = uint64(_envUintMax("REFUND_TIMEOUT", DEFAULT_REFUND_TIMEOUT, type(uint64).max));
        // forge-lint: disable-end(unsafe-typecast)
        cfg.maxReserveMint = vm.envOr("MAX_RESERVE_MINT", DEFAULT_MAX_RESERVE_MINT);
    }

    /// @notice The approved defaults for every tunable, with the given addresses.
    function _defaultConfig(
        address usdt0,
        address processor,
        uint256 feeCircuitId,
        address admin,
        address operator,
        address keeper,
        address treasury,
        address quoteSigner
    ) internal pure returns (DeployConfig memory cfg) {
        cfg.usdt0 = usdt0;
        cfg.processor = processor;
        cfg.feeCircuitId = feeCircuitId;
        cfg.admin = admin;
        cfg.operator = operator;
        cfg.keeper = keeper;
        cfg.treasury = treasury;
        cfg.quoteSigner = quoteSigner;
        cfg.tierFeeBps = [DEFAULT_TIER0_BPS, DEFAULT_TIER1_BPS, DEFAULT_TIER2_BPS];
        cfg.tier1Holding = DEFAULT_TIER1_HOLDING;
        cfg.tier2Holding = DEFAULT_TIER2_HOLDING;
        cfg.repeatOrders = DEFAULT_REPEAT_ORDERS;
        cfg.maxOrderAmount = DEFAULT_MAX_ORDER_AMOUNT;
        cfg.dailyVolumeCap = DEFAULT_DAILY_VOLUME_CAP;
        cfg.refundTimeout = DEFAULT_REFUND_TIMEOUT;
        cfg.maxReserveMint = DEFAULT_MAX_RESERVE_MINT;
    }

    function _gatewayParams(DeployConfig memory cfg) internal pure returns (PayLightGateway.InitParams memory p) {
        p.usdt0 = cfg.usdt0;
        p.processor = cfg.processor;
        p.admin = cfg.admin;
        p.operator = cfg.operator;
        p.treasury = cfg.treasury;
        p.quoteSigner = cfg.quoteSigner;
        p.feeCircuitId = cfg.feeCircuitId;
        p.tierFeeBps = cfg.tierFeeBps;
        p.tier1Holding = cfg.tier1Holding;
        p.tier2Holding = cfg.tier2Holding;
        p.repeatOrders = cfg.repeatOrders;
        p.maxOrderAmount = cfg.maxOrderAmount;
        p.dailyVolumeCap = cfg.dailyVolumeCap;
        p.refundTimeout = cfg.refundTimeout;
    }

    // ─────────────────────────────────────────────────────────────── deploy

    /// @notice Deploys PayLightGateway, then CashbackRouter, and wires the router into the gateway if (and only if)
    ///         `deployer` — the account making these calls — is the gateway admin.
    function _deploy(DeployConfig memory cfg, address deployer) internal returns (Deployment memory d) {
        _preflight(cfg);

        d.gateway = new PayLightGateway(_gatewayParams(cfg));
        d.transistors = d.gateway.transistors();
        d.router = new CashbackRouter(address(d.gateway), d.transistors, cfg.admin, cfg.keeper, cfg.maxReserveMint);

        d.deployer = deployer;
        if (deployer == cfg.admin) {
            d.gateway.setCashbackRouter(address(d.router));
            d.routerWired = true;
        }
        d.chainId = block.chainid;
        d.blockNumber = block.number;
        d.timestamp = block.timestamp;
    }

    /// @notice Sanity checks against the live chain before spending gas: code exists, USD₮0 has 6 decimals, and
    ///         FEE_CIRCUIT_ID really is "PayLight FeeTier v1" on PROCESSOR (all 8 inputs). 0 disables tiering.
    function _preflight(DeployConfig memory cfg) internal view {
        if (cfg.usdt0.code.length == 0) revert NoCode("USDT0", cfg.usdt0);
        if (cfg.processor.code.length == 0) revert NoCode("PROCESSOR", cfg.processor);
        uint8 dec = IERC20Metadata(cfg.usdt0).decimals();
        if (dec != USDT0_DECIMALS) revert WrongDecimals(dec);
        if (cfg.feeCircuitId == 0) return;
        for (uint8 x; x < 8; ++x) {
            bool ok;
            try ITapeOutProcessor(cfg.processor).eval(cfg.feeCircuitId, abi.encodePacked(x)) returns (bytes memory o) {
                ok = o.length == 1 && uint8(o[0]) == FeeTierCircuit.expectedTier(x);
            } catch {}
            if (!ok) revert FeeCircuitInvalid(cfg.feeCircuitId, x);
        }
    }

    // ─────────────────────────────────────────────────────────────── output

    /// @notice The exact command the admin must run when the deployer is not the admin.
    function _wireCommand(Deployment memory d) internal pure returns (string memory) {
        return string.concat(
            "cast send ",
            vm.toString(address(d.gateway)),
            " \"setCashbackRouter(address)\" ",
            vm.toString(address(d.router)),
            " --rpc-url ",
            XLAYER_RPC,
            " --ledger   # or: --account <admin-keystore>"
        );
    }

    /// @dev Relative to the Foundry project root (packages/contracts); foundry.toml grants read-write here.
    string internal constant DEPLOYMENTS_DIR = "../../deployments";

    function _deploymentPath(uint256 chainId) internal pure returns (string memory) {
        return string.concat(DEPLOYMENTS_DIR, "/", vm.toString(chainId), ".json");
    }

    /// @dev Foundry's fs_permissions only work for a directory that already exists (vm.createDir is refused too), so
    ///      check it before anything is broadcast rather than failing after.
    function _deploymentsDirExists() internal view returns (bool ok) {
        try vm.isDir(DEPLOYMENTS_DIR) returns (bool isDir) {
            ok = isDir;
        } catch {}
    }

    /// @notice deployments/<chainId>.json content. Transaction hashes are added afterwards from
    ///         broadcast/Deploy.s.sol/<chainId>/run-latest.json.
    function _serializeDeployment(DeployConfig memory cfg, Deployment memory d) internal returns (string memory json) {
        PayLightGateway.InitParams memory p = _gatewayParams(cfg);

        string memory g = "paylight.deploy.gateway";
        vm.serializeAddress(g, "address", address(d.gateway));
        vm.serializeBytes(g, "constructorArgs", abi.encode(p));
        vm.serializeAddress(g, "usdt0", p.usdt0);
        vm.serializeAddress(g, "processor", p.processor);
        vm.serializeAddress(g, "admin", p.admin);
        vm.serializeAddress(g, "operator", p.operator);
        vm.serializeAddress(g, "treasury", p.treasury);
        vm.serializeAddress(g, "quoteSigner", p.quoteSigner);
        vm.serializeUint(g, "feeCircuitId", p.feeCircuitId);
        uint256[] memory bps = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            bps[i] = p.tierFeeBps[i];
        }
        vm.serializeUint(g, "tierFeeBps", bps);
        vm.serializeUint(g, "tier1Holding", p.tier1Holding);
        vm.serializeUint(g, "tier2Holding", p.tier2Holding);
        vm.serializeUint(g, "repeatOrders", p.repeatOrders);
        vm.serializeUint(g, "maxOrderAmount", p.maxOrderAmount);
        vm.serializeUint(g, "dailyVolumeCap", p.dailyVolumeCap);
        string memory gJson = vm.serializeUint(g, "refundTimeout", p.refundTimeout);

        string memory r = "paylight.deploy.router";
        vm.serializeAddress(r, "address", address(d.router));
        vm.serializeBytes(
            r,
            "constructorArgs",
            abi.encode(address(d.gateway), d.transistors, cfg.admin, cfg.keeper, cfg.maxReserveMint)
        );
        vm.serializeAddress(r, "gateway", address(d.gateway));
        vm.serializeAddress(r, "transistors", d.transistors);
        vm.serializeAddress(r, "admin", cfg.admin);
        vm.serializeAddress(r, "keeper", cfg.keeper);
        string memory rJson = vm.serializeUint(r, "maxReserveMint", cfg.maxReserveMint);

        string memory c = "paylight.deploy.contracts";
        vm.serializeString(c, "PayLightGateway", gJson);
        string memory cJson = vm.serializeString(c, "CashbackRouter", rJson);

        string memory root = "paylight.deploy.root";
        vm.serializeUint(root, "chainId", d.chainId);
        vm.serializeUint(root, "blockNumber", d.blockNumber);
        vm.serializeUint(root, "timestamp", d.timestamp);
        vm.serializeAddress(root, "deployer", d.deployer);
        vm.serializeAddress(root, "usdt0", cfg.usdt0);
        vm.serializeAddress(root, "processor", cfg.processor);
        vm.serializeAddress(root, "transistors", d.transistors);
        vm.serializeUint(root, "feeCircuitId", cfg.feeCircuitId);
        vm.serializeBool(root, "cashbackRouterWired", d.routerWired);
        vm.serializeString(root, "setCashbackRouterCommand", d.routerWired ? "" : _wireCommand(d));
        vm.serializeString(
            root, "txHashes", "TODO: copy from broadcast/Deploy.s.sol/<chainId>/run-latest.json after broadcasting"
        );
        json = vm.serializeString(root, "contracts", cJson);
    }

    /// @dev Optional uint env var with a default, bounded so a typo can't silently truncate.
    function _envUintMax(string memory name, uint256 dflt, uint256 max) internal view returns (uint256 v) {
        v = vm.envOr(name, dflt);
        if (v > max) revert EnvValueTooLarge(name, v);
    }
}

/// @title Deploy
/// @notice Deploys PayLightGateway then CashbackRouter on X Layer (after the processor launch, see
///         script/LaunchProcessor.s.sol) and writes deployments/<chainId>.json. No private key is ever read.
///
/// ENV (public values only — never put keys in env files):
///   export PROCESSOR=0x...  FEE_CIRCUIT_ID=1
///   export ADMIN=0x...  OPERATOR=0x...  KEEPER=0x...  TREASURY=0x...  QUOTE_SIGNER=0x...
///   # optional overrides (approved defaults shown): TIER0_BPS=100 TIER1_BPS=50 TIER2_BPS=25 TIER1_HOLDING=50
///   #   TIER2_HOLDING=500 REPEAT_ORDERS=3 MAX_ORDER_AMOUNT=30000000 DAILY_VOLUME_CAP=1000000000
///   #   REFUND_TIMEOUT=86400 MAX_RESERVE_MINT=200000 USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
///
/// DRY RUN (fork simulation; broadcasts nothing and does not write deployments/<chainId>.json, prints it instead):
///   forge script script/Deploy.s.sol --fork-url https://rpc.xlayer.tech --sender $ADMIN -vvvv
///
/// BROADCAST (Greg's own computer only, after "yes, run it"). deployments/ must exist at the repo root first
/// (`mkdir -p deployments`): Foundry's fs_permissions refuse to create it, so the script checks before sending anything.
///   forge script script/Deploy.s.sol --rpc-url https://rpc.xlayer.tech --broadcast --slow --ledger --sender $ADMIN
///   # or with an encrypted Foundry keystore (`cast wallet import paylight-admin --interactive`):
///   forge script script/Deploy.s.sol --rpc-url https://rpc.xlayer.tech --broadcast --slow \
///     --account paylight-admin --sender $ADMIN
///   Never use --private-key or --unsafe-password.
///
/// If the broadcaster is not ADMIN, the router is NOT wired; the script prints the exact `cast send` command the
/// admin must run (also stored as `setCashbackRouterCommand` in the JSON).
contract Deploy is Script, PayLightDeployer {
    function run() external returns (Deployment memory d) {
        DeployConfig memory cfg = _loadConfig();
        bool writeFile =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (writeFile && !_deploymentsDirExists()) {
            revert DeploymentsDirMissing("run `mkdir -p deployments` at the repo root, then re-run (nothing was sent)");
        }

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = _deploy(cfg, deployer);
        vm.stopBroadcast();

        console2.log("chainId          :", d.chainId);
        console2.log("deployer         :", deployer);
        console2.log("PayLightGateway  :", address(d.gateway));
        console2.log("CashbackRouter   :", address(d.router));
        console2.log("transistors      :", d.transistors);
        if (d.routerWired) {
            console2.log("gateway.setCashbackRouter(router) executed by the admin");
        } else {
            console2.log("Deployer is NOT the admin, so the router is NOT wired. The admin must run:");
            console2.log(_wireCommand(d));
        }

        string memory json = _serializeDeployment(cfg, d);
        string memory path = _deploymentPath(d.chainId);
        if (writeFile) {
            vm.writeJson(json, path);
            console2.log("wrote", path);
        } else {
            console2.log("dry run: not writing", path);
            console2.log(json);
        }
        console2.log("Next: keeper tops up the reserve: router.topUp{value: router.topUpCost(units)}(units)");
    }
}
