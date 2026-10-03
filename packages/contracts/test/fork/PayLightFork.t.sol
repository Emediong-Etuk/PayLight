// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PayLightGateway} from "../../src/PayLightGateway.sol";
import {CashbackRouter} from "../../src/CashbackRouter.sol";
import {IUSDT0} from "../../src/interfaces/IUSDT0.sol";
import {ITapeOutFactory, ITapeOutProcessor, ITapeOutTransistors} from "../../src/interfaces/ITapeOut.sol";
import {FeeTierCircuit} from "../../src/libraries/FeeTierCircuit.sol";
import {Deploy, PayLightDeployer} from "../../script/Deploy.s.sol";
import {LaunchProcessor, ProcessorLauncher, ITapeOutProcessorMeta} from "../../script/LaunchProcessor.s.sol";

/// @dev Real USD₮0 getters beyond IUSDT0 (EIP-3009 state + typehash).
interface IUSDT0Fork is IUSDT0 {
    function RECEIVE_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @dev Real TapeOut transistor getter for creator mint revenue (docs/RESEARCH.md §1).
interface ITapeOutOwed {
    function owed(address account) external view returns (uint256);
}

/// @dev Used only to prove Deploy's preflight rejects a non-6-decimals "USD₮0".
contract ForkEighteenDecimalsToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @title PayLightForkTest
/// @notice Integration tests against the REAL X Layer mainnet contracts (TapeOut factory + USD₮0) on a fork.
///         Skipped unless FORK=1 so offline CI stays offline. Run:
///           FORK=1 forge test --match-path test/fork/PayLightFork.t.sol -vv
///         Optional FORK_BLOCK=<n> pins the fork block (default: latest).
/// @dev    setUp runs the REAL launch (script/LaunchProcessor.s.sol core: createCPU with the approved params, mint 7
///         NAND, tape out FeeTier v1) from a fresh "Greg" wallet, deploys gateway + router through
///         script/Deploy.s.sol's core `_deploy`, and tops up the router through the REAL transistor mint.
///         USD₮0 funding: forge-std `deal` (stdstore finds the balance slot behind the USD₮0 proxy; verified by
///         asserting balanceOf after the deal).
///         All actors are fresh `makeAddrAndKey` addresses with unusual labels: anvil's well-known default addresses
///         have code on X Layer mainnet and would make ERC-1155 safe mints revert.
contract PayLightForkTest is Test, PayLightDeployer, ProcessorLauncher {
    using stdStorage for StdStorage;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint64 internal constant QUOTE_TTL = 120;
    uint256 internal constant TOPUP = 1_000;
    uint256 internal constant USDT0_FUNDING = 1_000e6;

    ITapeOutFactory internal factory;
    IUSDT0Fork internal usdt0;
    ITapeOutProcessor internal processor;
    ITapeOutTransistors internal transistors;
    PayLightGateway internal gateway;
    CashbackRouter internal router;
    uint256 internal feeCircuitId;

    Launch internal launched;
    Deployment internal dep;
    DeployConfig internal cfg;
    uint256 internal cpuCountBefore;
    uint256 internal deployFeeAtLaunch;

    address internal greg;
    address internal admin;
    address internal operator;
    address internal keeper;
    address internal treasury;
    address internal relayer;
    address internal quoteSigner;
    uint256 internal signerPk;
    address internal alice;
    uint256 internal alicePk;
    address internal bob;
    uint256 internal bobPk;
    address internal carol;
    address internal dave;

    uint256 internal orderSalt;

    function setUp() public {
        if (!vm.envOr("FORK", false)) {
            vm.skip(true, "mainnet-fork suite: set FORK=1 (needs network)");
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(XLAYER_RPC);
        else vm.createSelectFork(XLAYER_RPC, forkBlock);
        assertEq(block.chainid, XLAYER_CHAIN_ID, "not X Layer");

        (greg,) = makeAddrAndKey("plfork/greg-deployment-wallet#9b1");
        (admin,) = makeAddrAndKey("plfork/gateway-admin#c42");
        (operator,) = makeAddrAndKey("plfork/operator#e07");
        (keeper,) = makeAddrAndKey("plfork/keeper#a5d");
        (treasury,) = makeAddrAndKey("plfork/treasury#31f");
        (relayer,) = makeAddrAndKey("plfork/relayer#77b");
        (quoteSigner, signerPk) = makeAddrAndKey("plfork/quote-signer#0d9");
        (alice, alicePk) = makeAddrAndKey("plfork/payer-alice#f6e");
        (bob, bobPk) = makeAddrAndKey("plfork/payer-bob#2c8");
        (carol,) = makeAddrAndKey("plfork/holder-carol#b13");
        (dave,) = makeAddrAndKey("plfork/repeat-dave#4a0");
        address[11] memory actors =
            [greg, admin, operator, keeper, treasury, relayer, quoteSigner, alice, bob, carol, dave];
        for (uint256 i; i < actors.length; ++i) {
            assertEq(actors[i].code.length, 0, "actor has code on X Layer");
        }

        factory = ITapeOutFactory(TAPEOUT_FACTORY);
        usdt0 = IUSDT0Fork(XLAYER_USDT0);
        assertGt(address(factory).code.length, 0, "factory");
        assertGt(address(usdt0).code.length, 0, "usdt0");

        // 1. Greg's launch, exactly as script/LaunchProcessor.s.sol runs it.
        cpuCountBefore = factory.cpuCount();
        deployFeeAtLaunch = factory.deployFee();
        vm.deal(greg, 1 ether);
        vm.startPrank(greg, greg);
        launched = _launchProcessor(greg);
        vm.stopPrank();
        processor = ITapeOutProcessor(launched.processor);
        transistors = ITapeOutTransistors(launched.transistors);
        feeCircuitId = launched.circuitId;

        // 2. Gateway + router through script/Deploy.s.sol's core, broadcaster == ADMIN.
        cfg = _defaultConfig(
            XLAYER_USDT0, launched.processor, feeCircuitId, admin, operator, keeper, treasury, quoteSigner
        );
        vm.startPrank(admin, admin);
        dep = _deploy(cfg, admin);
        vm.stopPrank();
        gateway = dep.gateway;
        router = dep.router;

        // 3. Reserve top-up through the REAL transistor mint.
        vm.deal(keeper, 100 ether);
        _topUp(TOPUP);

        // 4. Real USD₮0 for the payers.
        _fundUsdt0(alice, USDT0_FUNDING);
        _fundUsdt0(bob, USDT0_FUNDING);
    }

    // ═══════════════════════════════════════════════════════════════ LaunchProcessor (real TapeOut)

    function test_fork_launchProcessor_createsApprovedProcessor() public view {
        assertTrue(factory.isCPU(address(processor)), "isCPU");
        assertEq(factory.cpuCount(), cpuCountBefore + 1, "cpuCount");
        assertEq(factory.cpuAt(factory.cpuCount() - 1), address(processor), "cpuAt(last)");
        assertEq(ITapeOutProcessorMeta(address(processor)).name(), "PayLight");
        assertEq(ITapeOutProcessorMeta(address(processor)).symbol(), "PLIGHT");
        assertEq(processor.transistors(), address(transistors));
        assertEq(transistors.supplyCap(), 1_000_000);
        assertEq(transistors.mintPrice(), 0.0001 ether);
        assertEq(transistors.creator(), greg, "creator = deployment wallet");

        // FeeTier v1 is circuit #1, owned by Greg; its 7 NAND were burned (lifetime minted counter keeps them)
        assertEq(feeCircuitId, 1);
        assertEq(processor.nextId(), 1);
        assertEq(processor.ownerOf(1), greg);
        assertFalse(launched.circuitReused);
        assertEq(transistors.balanceOf(greg, NAND), 0, "7 NAND burned by tape-out");
        assertEq(transistors.minted(), FeeTierCircuit.NAND_COUNT + TOPUP);

        // exact OKB spent: deployFee + (7 x mintPrice + protocolFee) + TAPEOUT_FEE
        uint256 expectedSpend = deployFeeAtLaunch + FeeTierCircuit.NAND_COUNT * 0.0001 ether + transistors.protocolFee()
            + processor.TAPEOUT_FEE();
        assertEq(launched.okbSent, expectedSpend, "okbSent");
        assertEq(greg.balance, 1 ether - expectedSpend);
        // mint revenue (launch mint + reserve top-up) accrues to the creator
        assertEq(ITapeOutOwed(address(transistors)).owed(greg), (FeeTierCircuit.NAND_COUNT + TOPUP) * 0.0001 ether);
    }

    function test_fork_feeTierCircuit_truthTable() public view {
        bytes memory expected = hex"0001020201010202";
        for (uint8 x; x < 8; ++x) {
            bytes memory out = processor.eval(feeCircuitId, abi.encodePacked(x));
            assertEq(out.length, 1, "1 output byte");
            assertEq(uint8(out[0]), FeeTierCircuit.expectedTier(x), "reference");
            assertEq(out[0], expected[x], "published table");
        }
    }

    function test_fork_feeTierCircuit_evalFitsGatewayGasCap() public view {
        for (uint8 x; x < 8; ++x) {
            uint256 g = gasleft();
            processor.eval(feeCircuitId, abi.encodePacked(x));
            assertLt(g - gasleft(), gateway.EVAL_GAS_LIMIT(), "eval must fit the gateway's gas cap");
        }
    }

    function test_fork_launchProcessor_twoStepRoute_andResumeIsIdempotent() public {
        (address greg2,) = makeAddrAndKey("plfork/second-launch-wallet#5e2");
        assertEq(greg2.code.length, 0);
        vm.deal(greg2, 1 ether);

        vm.startPrank(greg2, greg2);
        address p2 = _createProcessor(greg2); // LaunchProcessor.createProcessor()
        assertEq(ITapeOutProcessor(p2).nextId(), 0, "no circuit yet");
        Launch memory l = _resumeLaunch(p2, greg2); // LaunchProcessor.run() with PROCESSOR=p2
        uint256 balAfterFirst = greg2.balance;
        Launch memory again = _resumeLaunch(p2, greg2); // rerun: must not tape out twice
        vm.stopPrank();

        assertEq(l.processor, p2);
        assertEq(l.transistors, ITapeOutProcessor(p2).transistors());
        assertEq(l.circuitId, 1);
        assertFalse(l.circuitReused);
        assertEq(
            l.okbSent,
            FeeTierCircuit.NAND_COUNT * 0.0001 ether + ITapeOutTransistors(l.transistors).protocolFee()
                + ITapeOutProcessor(p2).TAPEOUT_FEE()
        );
        assertEq(again.circuitId, 1);
        assertTrue(again.circuitReused);
        assertEq(again.okbSent, 0);
        assertEq(greg2.balance, balAfterFirst);
        assertEq(ITapeOutProcessor(p2).nextId(), 1);
        _assertFeeTierTruthTable(p2, 1);
    }

    function test_fork_launchProcessor_resumeMintsOnlyMissingNand() public {
        (address greg3,) = makeAddrAndKey("plfork/partial-launch-wallet#8c7");
        vm.deal(greg3, 1 ether);
        vm.startPrank(greg3, greg3);
        address p3 = _createProcessor(greg3);
        ITapeOutTransistors t3 = ITapeOutTransistors(ITapeOutProcessor(p3).transistors());
        t3.mint{value: t3.mintPrice() * 4 + t3.protocolFee()}(NAND, 4); // an interrupted earlier attempt
        Launch memory l = _resumeLaunch(p3, greg3);
        vm.stopPrank();
        assertEq(t3.minted(), FeeTierCircuit.NAND_COUNT, "only 3 more minted");
        assertEq(t3.balanceOf(greg3, NAND), 0);
        assertEq(l.circuitId, 1);
        assertEq(l.okbSent, 3 * t3.mintPrice() + t3.protocolFee() + ITapeOutProcessor(p3).TAPEOUT_FEE());
    }

    function test_fork_launchProcessor_rejectsForeignOrWrongProcessor() public {
        // someone else's processor (Greg created it, alice is the broadcaster)
        vm.expectRevert(abi.encodeWithSelector(NotProcessorCreator.selector, address(processor), greg, alice));
        this.ext_resumeLaunch(address(processor), alice);

        // not a TapeOut processor at all
        vm.expectRevert(abi.encodeWithSelector(NotTapeOutProcessor.selector, address(usdt0)));
        this.ext_resumeLaunch(address(usdt0), greg);

        // a real processor by the right wallet but with non-approved parameters
        (address greg4,) = makeAddrAndKey("plfork/wrong-params-wallet#d70");
        vm.deal(greg4, 1 ether);
        uint256 fee = factory.deployFee();
        vm.prank(greg4, greg4);
        factory.createCPU{value: fee}(
            "PayLightX", PROCESSOR_SYMBOL, PROCESSOR_STORY, PROCESSOR_SUPPLY_CAP, PROCESSOR_MINT_PRICE
        );
        address wrong = factory.cpuAt(factory.cpuCount() - 1);
        vm.expectRevert(abi.encodeWithSelector(ProcessorParamMismatch.selector, "name"));
        this.ext_resumeLaunch(wrong, greg4);

        vm.prank(greg4, greg4);
        factory.createCPU{value: fee}(PROCESSOR_NAME, PROCESSOR_SYMBOL, PROCESSOR_STORY, 21_000, PROCESSOR_MINT_PRICE);
        address wrongCap = factory.cpuAt(factory.cpuCount() - 1);
        vm.expectRevert(abi.encodeWithSelector(ProcessorParamMismatch.selector, "supplyCap"));
        this.ext_resumeLaunch(wrongCap, greg4);
    }

    // ═══════════════════════════════════════════════════════════════ Deploy script

    function test_fork_deploy_appliesApprovedConfig_andAdminWiresRouter() public view {
        assertTrue(dep.routerWired);
        assertEq(dep.deployer, admin);
        assertEq(dep.chainId, 196);
        assertEq(dep.transistors, address(transistors));

        assertEq(address(gateway.usdt0()), XLAYER_USDT0);
        assertEq(gateway.processor(), address(processor));
        assertEq(gateway.transistors(), address(transistors));
        assertEq(gateway.treasury(), treasury);
        assertEq(gateway.quoteSigner(), quoteSigner);
        assertEq(gateway.cashbackRouter(), address(router));
        assertEq(gateway.feeCircuitId(), feeCircuitId);
        assertEq(gateway.tierFeeBps(0), 100);
        assertEq(gateway.tierFeeBps(1), 50);
        assertEq(gateway.tierFeeBps(2), 25);
        assertEq(gateway.tier1Holding(), 50);
        assertEq(gateway.tier2Holding(), 500);
        assertEq(gateway.repeatOrders(), 3);
        assertEq(gateway.maxOrderAmount(), 30e6);
        assertEq(gateway.dailyVolumeCap(), 1_000e6);
        assertEq(gateway.refundTimeout(), 24 hours);
        assertTrue(gateway.hasRole(gateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(gateway.hasRole(gateway.OPERATOR_ROLE(), operator));
        assertFalse(gateway.hasRole(gateway.OPERATOR_ROLE(), admin));
        assertFalse(gateway.paused());

        assertEq(router.gateway(), address(gateway));
        assertEq(address(router.transistors()), address(transistors));
        assertEq(router.maxReserveMint(), 200_000);
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(router.hasRole(router.KEEPER_ROLE(), keeper));
        assertFalse(router.hasRole(router.KEEPER_ROLE(), admin));
    }

    function test_fork_deploy_nonAdminBroadcaster_leavesRouterUnwired_andPrintsCommand() public {
        (address hot,) = makeAddrAndKey("plfork/non-admin-deployer#6f1");
        vm.startPrank(hot, hot);
        Deployment memory d = _deploy(cfg, hot);
        vm.stopPrank();

        assertFalse(d.routerWired);
        assertEq(d.deployer, hot);
        assertEq(d.gateway.cashbackRouter(), address(0));
        assertFalse(d.gateway.hasRole(d.gateway.DEFAULT_ADMIN_ROLE(), hot));
        assertTrue(d.gateway.hasRole(d.gateway.DEFAULT_ADMIN_ROLE(), admin));

        string memory expected = string.concat(
            "cast send ",
            vm.toString(address(d.gateway)),
            " \"setCashbackRouter(address)\" ",
            vm.toString(address(d.router)),
            " --rpc-url https://rpc.xlayer.tech --ledger   # or: --account <admin-keystore>"
        );
        assertEq(_wireCommand(d), expected);
        string memory json = _serializeDeployment(cfg, d);
        assertFalse(vm.parseJsonBool(json, ".cashbackRouterWired"));
        assertEq(vm.parseJsonString(json, ".setCashbackRouterCommand"), expected);

        // the deployer cannot wire it; the admin runs the printed command
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, hot, bytes32(0))
        );
        vm.prank(hot);
        d.gateway.setCashbackRouter(address(d.router));

        vm.expectEmit(address(d.gateway));
        emit PayLightGateway.CashbackRouterUpdated(address(d.router));
        vm.prank(admin);
        d.gateway.setCashbackRouter(address(d.router));
        assertEq(d.gateway.cashbackRouter(), address(d.router));
    }

    function test_fork_deploy_preflightRejectsBadInputs() public {
        DeployConfig memory bad = cfg;
        bad.feeCircuitId = 2; // does not exist on the PayLight processor
        vm.expectRevert(abi.encodeWithSelector(FeeCircuitInvalid.selector, uint256(2), uint8(0)));
        this.ext_deploy(bad, address(this));

        bad = cfg;
        address empty = makeAddr("plfork/no-code-processor#e1a");
        bad.processor = empty;
        vm.expectRevert(abi.encodeWithSelector(NoCode.selector, "PROCESSOR", empty));
        this.ext_deploy(bad, address(this));

        bad = cfg;
        bad.usdt0 = address(new ForkEighteenDecimalsToken());
        vm.expectRevert(abi.encodeWithSelector(WrongDecimals.selector, uint8(18)));
        this.ext_deploy(bad, address(this));

        // feeCircuitId 0 (tiering disabled) is allowed: everyone is tier 0
        bad = cfg;
        bad.feeCircuitId = 0;
        Deployment memory d = this.ext_deploy(bad, address(this)); // not the admin: router left unwired
        assertFalse(d.routerWired);
        _giveTransistors(carol, 500);
        assertEq(d.gateway.computeTier(carol), 0);
    }

    /// @notice Everything that reads process env lives in this ONE test (tests run in parallel and env is global):
    ///         Deploy._loadConfig defaults/overrides/bounds, then the real `run()` entry points of both scripts.
    function test_fork_scripts_envConfig_andRunEntryPoints() public {
        // ── Deploy._loadConfig: required vars + approved defaults
        vm.setEnv("PROCESSOR", vm.toString(address(processor)));
        vm.setEnv("FEE_CIRCUIT_ID", vm.toString(feeCircuitId));
        vm.setEnv("ADMIN", vm.toString(admin));
        vm.setEnv("OPERATOR", vm.toString(operator));
        vm.setEnv("KEEPER", vm.toString(keeper));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("QUOTE_SIGNER", vm.toString(quoteSigner));

        DeployConfig memory c = _loadConfig();
        DeployConfig memory expected = cfg;
        assertEq(c.usdt0, XLAYER_USDT0, "USDT0 defaults to the real token on chainId 196");
        assertEq(keccak256(abi.encode(c)), keccak256(abi.encode(expected)), "approved defaults");

        // overrides
        vm.setEnv("TIER0_BPS", "150");
        vm.setEnv("MAX_ORDER_AMOUNT", "50000000");
        vm.setEnv("REFUND_TIMEOUT", "3600");
        vm.setEnv("MAX_RESERVE_MINT", "100000");
        c = _loadConfig();
        assertEq(c.tierFeeBps[0], 150);
        assertEq(c.tierFeeBps[1], 50);
        assertEq(c.maxOrderAmount, 50e6);
        assertEq(c.refundTimeout, 1 hours);
        assertEq(c.maxReserveMint, 100_000);

        // no silent truncation
        vm.setEnv("TIER0_BPS", "65536");
        vm.expectRevert(abi.encodeWithSelector(EnvValueTooLarge.selector, "TIER0_BPS", uint256(65536)));
        this.ext_loadConfig();

        // back to the approved defaults
        vm.setEnv("TIER0_BPS", "100");
        vm.setEnv("MAX_ORDER_AMOUNT", "30000000");
        vm.setEnv("REFUND_TIMEOUT", "86400");
        vm.setEnv("MAX_RESERVE_MINT", "200000");

        // ── LaunchProcessor.run(): full launch from forge's broadcaster (no PROCESSOR set)
        (, address broadcaster,) = vm.readCallers();
        assertEq(broadcaster.code.length, 0);
        vm.deal(broadcaster, 1 ether);
        LaunchProcessor launchScript = new LaunchProcessor();
        vm.setEnv("PROCESSOR", vm.toString(address(0)));
        Launch memory l = launchScript.run();
        assertEq(ITapeOutTransistors(l.transistors).creator(), broadcaster, "creator = broadcaster");
        assertEq(ITapeOutProcessorMeta(l.processor).name(), "PayLight");
        assertEq(ITapeOutTransistors(l.transistors).supplyCap(), 1_000_000);
        assertEq(ITapeOutTransistors(l.transistors).mintPrice(), 0.0001 ether);
        assertEq(l.circuitId, 1);
        assertFalse(l.circuitReused);
        assertEq(ITapeOutProcessor(l.processor).ownerOf(1), broadcaster);
        _assertFeeTierTruthTable(l.processor, 1);

        // ── LaunchProcessor.run() with PROCESSOR set: resume reuses the circuit and spends nothing
        vm.setEnv("PROCESSOR", vm.toString(l.processor));
        Launch memory again = launchScript.run();
        assertTrue(again.circuitReused);
        assertEq(again.circuitId, 1);
        assertEq(again.okbSent, 0);
        assertEq(ITapeOutProcessor(l.processor).nextId(), 1);

        // ── Deploy.run() on that processor, broadcaster == ADMIN: router wired
        vm.setEnv("FEE_CIRCUIT_ID", vm.toString(l.circuitId));
        vm.setEnv("ADMIN", vm.toString(broadcaster));
        Deploy deployScript = new Deploy();
        Deployment memory d = deployScript.run();
        assertTrue(d.routerWired);
        assertEq(d.deployer, broadcaster);
        assertEq(d.gateway.processor(), l.processor);
        assertEq(d.gateway.cashbackRouter(), address(d.router));
        assertTrue(d.gateway.hasRole(d.gateway.DEFAULT_ADMIN_ROLE(), broadcaster));
        assertEq(d.router.maxReserveMint(), 200_000);

        // ── Deploy.run() with a different ADMIN: router left unwired (the admin must run the printed command)
        vm.setEnv("ADMIN", vm.toString(admin));
        Deployment memory d2 = deployScript.run();
        assertFalse(d2.routerWired);
        assertEq(d2.gateway.cashbackRouter(), address(0));
        assertTrue(d2.gateway.hasRole(d2.gateway.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(d2.gateway.hasRole(d2.gateway.DEFAULT_ADMIN_ROLE(), broadcaster));

        // ── a wrong FEE_CIRCUIT_ID is caught by the preflight before anything is deployed
        vm.setEnv("FEE_CIRCUIT_ID", "7");
        vm.expectRevert(abi.encodeWithSelector(FeeCircuitInvalid.selector, uint256(7), uint8(0)));
        deployScript.run();
    }

    function test_fork_deploy_deploymentJson() public {
        string memory json = _serializeDeployment(cfg, dep);
        assertEq(_deploymentPath(196), "../../deployments/196.json");
        assertEq(vm.parseJsonUint(json, ".chainId"), 196);
        assertEq(vm.parseJsonUint(json, ".blockNumber"), dep.blockNumber);
        assertEq(vm.parseJsonAddress(json, ".deployer"), admin);
        assertEq(vm.parseJsonAddress(json, ".usdt0"), XLAYER_USDT0);
        assertEq(vm.parseJsonAddress(json, ".processor"), address(processor));
        assertEq(vm.parseJsonAddress(json, ".transistors"), address(transistors));
        assertEq(vm.parseJsonUint(json, ".feeCircuitId"), 1);
        assertTrue(vm.parseJsonBool(json, ".cashbackRouterWired"));
        assertEq(vm.parseJsonString(json, ".setCashbackRouterCommand"), "");

        assertEq(vm.parseJsonAddress(json, ".contracts.PayLightGateway.address"), address(gateway));
        assertEq(vm.parseJsonBytes(json, ".contracts.PayLightGateway.constructorArgs"), abi.encode(_gatewayParams(cfg)));
        uint256[] memory bps = vm.parseJsonUintArray(json, ".contracts.PayLightGateway.tierFeeBps");
        assertEq(bps.length, 3);
        assertEq(bps[0], 100);
        assertEq(bps[1], 50);
        assertEq(bps[2], 25);
        assertEq(vm.parseJsonUint(json, ".contracts.PayLightGateway.maxOrderAmount"), 30e6);
        assertEq(vm.parseJsonUint(json, ".contracts.PayLightGateway.dailyVolumeCap"), 1_000e6);
        assertEq(vm.parseJsonUint(json, ".contracts.PayLightGateway.refundTimeout"), 86_400);

        assertEq(vm.parseJsonAddress(json, ".contracts.CashbackRouter.address"), address(router));
        assertEq(
            vm.parseJsonBytes(json, ".contracts.CashbackRouter.constructorArgs"),
            abi.encode(address(gateway), address(transistors), admin, keeper, uint256(200_000))
        );
        assertEq(vm.parseJsonUint(json, ".contracts.CashbackRouter.maxReserveMint"), 200_000);

        // the recorded constructor args really reproduce the deployed contracts
        address r2 = _create(
            abi.encodePacked(
                type(CashbackRouter).creationCode, vm.parseJsonBytes(json, ".contracts.CashbackRouter.constructorArgs")
            )
        );
        assertEq(keccak256(r2.code), keccak256(address(router).code), "router runtime code");
        PayLightGateway g2 = PayLightGateway(
            _create(
                abi.encodePacked(
                    type(PayLightGateway).creationCode,
                    vm.parseJsonBytes(json, ".contracts.PayLightGateway.constructorArgs")
                )
            )
        );
        // (gateway runtime code embeds its own address via EIP712 immutables, so compare state instead)
        assertEq(address(g2.usdt0()), address(gateway.usdt0()));
        assertEq(g2.processor(), gateway.processor());
        assertEq(g2.transistors(), gateway.transistors());
        assertEq(g2.treasury(), gateway.treasury());
        assertEq(g2.quoteSigner(), gateway.quoteSigner());
        assertEq(g2.feeCircuitId(), gateway.feeCircuitId());
        assertEq(g2.maxOrderAmount(), gateway.maxOrderAmount());
        assertEq(g2.dailyVolumeCap(), gateway.dailyVolumeCap());
        assertEq(g2.refundTimeout(), gateway.refundTimeout());
        assertTrue(g2.hasRole(g2.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(g2.hasRole(g2.OPERATOR_ROLE(), operator));
    }

    // ═══════════════════════════════════════════════════════════════ Router top-up (real transistor mint)

    function test_fork_topUp_mintsReserveThroughRealTransistors() public {
        assertEq(transistors.balanceOf(address(router), NAND), TOPUP, "setUp top-up");
        assertEq(router.reserveMinted(), TOPUP);

        uint256 units = 2_500;
        uint256 cost = router.topUpCost(units);
        assertEq(cost, 0.0001 ether * units + transistors.protocolFee());
        uint256 owedBefore = ITapeOutOwed(address(transistors)).owed(greg);
        uint256 mintedBefore = transistors.minted();

        vm.expectRevert(abi.encodeWithSelector(CashbackRouter.WrongPayment.selector, cost));
        vm.prank(keeper);
        router.topUp{value: cost - 1}(units);

        vm.deal(alice, cost);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, router.KEEPER_ROLE()
            )
        );
        vm.prank(alice);
        router.topUp{value: cost}(units);

        vm.expectEmit(true, true, true, true, address(transistors));
        emit IERC1155.TransferSingle(address(router), address(0), address(router), NAND, units);
        vm.expectEmit(true, false, false, true, address(router));
        emit CashbackRouter.ReserveToppedUp(keeper, units, cost);
        vm.prank(keeper);
        router.topUp{value: cost}(units);

        assertEq(transistors.balanceOf(address(router), NAND), TOPUP + units);
        assertEq(router.reserveMinted(), TOPUP + units);
        assertEq(router.freeReserve(), TOPUP + units);
        assertEq(transistors.minted(), mintedBefore + units);
        assertEq(address(router).balance, 0, "router keeps no OKB");
        assertEq(ITapeOutOwed(address(transistors)).owed(greg) - owedBefore, units * 0.0001 ether, "creator revenue");

        // lifetime cap (20% of supply) enforced before any payment check
        uint256 over = router.maxReserveMint() - router.reserveMinted() + 1;
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        vm.prank(keeper);
        router.topUp(over);
    }

    function test_fork_router_rejectsDirectTransistorTransfers() public {
        _giveTransistors(carol, 5);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        vm.prank(carol);
        IERC1155(address(transistors)).safeTransferFrom(carol, address(router), NAND, 5, "");
        assertEq(transistors.balanceOf(address(router), NAND), TOPUP);
        assertEq(transistors.balanceOf(carol, NAND), 5);
    }

    // ═══════════════════════════════════════════════════════════════ Payments with REAL USD₮0

    function test_fork_pay_approve_markFulfilled_distribute() public {
        PayLightGateway.Quote memory q = _quote(alice, 3_300_000, 5);
        assertEq(q.tier, 0);
        assertEq(q.fee, 33_000); // 1.00%
        uint128 total = _total(q);
        uint256 aliceBefore = usdt0.balanceOf(alice);
        uint256 treasuryBefore = usdt0.balanceOf(treasury);
        bytes memory sig = _sign(q);

        vm.prank(alice);
        usdt0.approve(address(gateway), total);

        uint64 refundableAt = uint64(block.timestamp) + 24 hours;
        vm.expectEmit(true, true, false, true, address(gateway));
        emit PayLightGateway.OrderPaid(q.orderId, alice, total, q.fee, 0, 5, refundableAt);
        vm.expectEmit(true, true, false, true, address(usdt0));
        emit IERC20.Transfer(alice, address(gateway), total);
        vm.prank(alice);
        gateway.pay(q, sig);

        assertEq(usdt0.balanceOf(alice), aliceBefore - total);
        assertEq(usdt0.balanceOf(address(gateway)), total);
        assertEq(usdt0.allowance(alice, address(gateway)), 0);
        assertEq(gateway.totalPending(), total);
        assertEq(gateway.dailyVolume(block.timestamp / 1 days), total);
        PayLightGateway.Order memory o = gateway.getOrder(q.orderId);
        assertEq(o.payer, alice);
        assertEq(uint8(o.status), uint8(PayLightGateway.Status.Paid));
        assertEq(o.amount, total);
        assertEq(o.fee, 33_000);
        assertEq(o.refundableAt, refundableAt);
        assertEq(o.cashbackUnits, 5);

        // settle
        bytes32 receipt = keccak256("vtpass-tx-fork-0001");
        vm.expectEmit(true, true, false, true, address(usdt0));
        emit IERC20.Transfer(address(gateway), treasury, total);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackCredited(q.orderId, alice, 5);
        vm.expectEmit(true, false, false, true, address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, receipt, 5, true);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, receipt);

        assertEq(usdt0.balanceOf(treasury) - treasuryBefore, total);
        assertEq(usdt0.balanceOf(address(gateway)), 0);
        assertEq(gateway.totalPending(), 0);
        assertEq(gateway.settledOrders(alice), 1);
        o = gateway.getOrder(q.orderId);
        assertEq(uint8(o.status), uint8(PayLightGateway.Status.Fulfilled));
        assertTrue(o.cashbackCredited);
        assertEq(router.pendingUnits(), 5);
        assertEq(router.freeReserve(), TOPUP - 5);

        // distribute: permissionless, real ERC-1155 safe transfer to the payer
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = q.orderId;
        vm.expectEmit(true, true, true, true, address(transistors));
        emit IERC1155.TransferSingle(address(router), address(router), alice, NAND, 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(q.orderId, alice, 5);
        vm.prank(relayer);
        assertEq(router.distribute(ids), 1);

        assertEq(transistors.balanceOf(alice, NAND), 5);
        assertEq(transistors.balanceOf(address(router), NAND), TOPUP - 5);
        assertEq(router.distributedUnits(), 5);
        assertEq(router.pendingUnits(), 0);
        (,, bool paid) = router.credits(q.orderId);
        assertTrue(paid);
        assertEq(router.distribute(ids), 0, "second distribute is a no-op");
        assertEq(transistors.balanceOf(alice, NAND), 5);

        // terminal: no transition out of Fulfilled
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        vm.prank(operator);
        gateway.refund(q.orderId);
    }

    function test_fork_payWithPermit_realUsdt0() public {
        bytes32 expectedDomain = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(unicode"USD₮0")), keccak256("1"), 196, XLAYER_USDT0)
        );
        assertEq(usdt0.DOMAIN_SEPARATOR(), expectedDomain, "USD0 domain: name USD0, version 1, chainId 196");

        PayLightGateway.Quote memory q = _quote(bob, 10e6, 10);
        uint128 total = _total(q);
        uint256 nonceBefore = usdt0.nonces(bob);
        uint256 bobBefore = usdt0.balanceOf(bob);
        PayLightGateway.PermitSig memory p = _permitSig(bobPk, bob, total, block.timestamp + 1 hours);
        bytes memory sig = _sign(q);
        assertEq(usdt0.allowance(bob, address(gateway)), 0, "no prior approval");

        vm.expectEmit(true, true, false, true, address(gateway));
        emit PayLightGateway.OrderPaid(q.orderId, bob, total, q.fee, 0, 10, uint64(block.timestamp) + 24 hours);
        vm.expectEmit(true, true, false, true, address(usdt0));
        emit IERC20.Approval(bob, address(gateway), total);
        vm.expectEmit(true, true, false, true, address(usdt0));
        emit IERC20.Transfer(bob, address(gateway), total);
        vm.prank(bob);
        gateway.payWithPermit(q, sig, p);

        assertEq(usdt0.nonces(bob), nonceBefore + 1, "the REAL permit executed");
        assertEq(usdt0.allowance(bob, address(gateway)), 0);
        assertEq(usdt0.balanceOf(bob), bobBefore - total);
        assertEq(usdt0.balanceOf(address(gateway)), total);
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Paid));
        assertEq(gateway.totalPending(), total);
    }

    function test_fork_payWithPermit_frontRunPermitDoesNotGrief() public {
        PayLightGateway.Quote memory q = _quote(bob, 5e6, 2);
        uint128 total = _total(q);
        PayLightGateway.PermitSig memory p = _permitSig(bobPk, bob, total, block.timestamp + 1 hours);
        bytes memory sig = _sign(q);

        // an attacker submits bob's permit first, straight to the real USD₮0
        vm.prank(relayer);
        usdt0.permit(bob, address(gateway), total, p.deadline, p.v, p.r, p.s);
        assertEq(usdt0.allowance(bob, address(gateway)), total);

        vm.prank(bob);
        gateway.payWithPermit(q, sig, p); // permit now fails inside try/catch; the allowance is used
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Paid));
        assertEq(usdt0.allowance(bob, address(gateway)), 0);
        assertEq(usdt0.balanceOf(address(gateway)), total);
    }

    function test_fork_payWithPermit_badPermitFallsThroughToAllowanceCheck() public {
        PayLightGateway.Quote memory q = _quote(bob, 5e6, 2);
        uint128 total = _total(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, bob, total, block.timestamp + 1 hours); // wrong key
        bytes memory sig = _sign(q);
        uint256 nonceBefore = usdt0.nonces(bob);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance")); // permit swallowed, real transferFrom fails
        vm.prank(bob);
        gateway.payWithPermit(q, sig, p);
        assertEq(usdt0.nonces(bob), nonceBefore);
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.None));
    }

    function test_fork_payWithAuthorization_realUsdt0_gasless() public {
        assertEq(usdt0.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), RECEIVE_TYPEHASH);

        PayLightGateway.Quote memory q = _quote(alice, 10e6, 10);
        uint128 total = _total(q);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, total, q.orderId);
        bytes memory sig = _sign(q);
        uint256 aliceBefore = usdt0.balanceOf(alice);
        assertFalse(usdt0.authorizationState(alice, q.orderId));
        assertEq(alice.balance, 0, "payer holds no OKB");

        vm.expectEmit(true, true, false, true, address(gateway));
        emit PayLightGateway.OrderPaid(q.orderId, alice, total, q.fee, 0, 10, uint64(block.timestamp) + 24 hours);
        vm.expectEmit(true, true, false, true, address(usdt0));
        emit IERC20.Transfer(alice, address(gateway), total);
        vm.prank(relayer, relayer);
        gateway.payWithAuthorization(q, sig, a);

        assertTrue(usdt0.authorizationState(alice, q.orderId), "nonce = orderId consumed on the real token");
        assertEq(usdt0.balanceOf(alice), aliceBefore - total);
        assertEq(usdt0.balanceOf(address(gateway)), total);
        assertEq(alice.balance, 0, "still no OKB: the relayer paid gas");
        PayLightGateway.Order memory o = gateway.getOrder(q.orderId);
        assertEq(o.payer, alice);
        assertEq(uint8(o.status), uint8(PayLightGateway.Status.Paid));

        // replay of the same order is rejected before USD₮0 is touched
        vm.expectRevert(PayLightGateway.OrderExists.selector);
        vm.prank(relayer);
        gateway.payWithAuthorization(q, sig, a);
    }

    function test_fork_payWithAuthorization_wrongSigner_reverts() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 1);
        PayLightGateway.AuthorizationSig memory a = _authSig(bobPk, alice, _total(q), q.orderId); // bob signs for alice
        bytes memory sig = _sign(q);
        vm.expectRevert(bytes("TetherToken: invalid signature")); // real USD₮0's own error, bubbled up
        vm.prank(relayer);
        gateway.payWithAuthorization(q, sig, a);
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.None));
        assertEq(usdt0.balanceOf(address(gateway)), 0);
    }

    // ═══════════════════════════════════════════════════════════════ Refunds

    function test_fork_claimRefund_afterWarp_evenWhilePaused() public {
        PayLightGateway.Quote memory q = _quote(alice, 20e6, 3);
        uint128 total = _total(q);
        uint256 aliceBefore = usdt0.balanceOf(alice);
        _pay(q);
        uint64 refundableAt = gateway.getOrder(q.orderId).refundableAt;
        assertEq(refundableAt, uint64(block.timestamp) + 24 hours);

        vm.expectRevert(abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, refundableAt));
        vm.prank(alice);
        gateway.claimRefund(q.orderId);

        vm.warp(refundableAt); // strictly after is required
        vm.expectRevert(abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, refundableAt));
        vm.prank(alice);
        gateway.claimRefund(q.orderId);

        vm.warp(uint256(refundableAt) + 1);
        vm.prank(operator);
        gateway.pause(); // PayLight "disappears" / incident: self-refund must still work

        // anyone (here bob) may trigger the self-refund; the funds can only go to the payer (alice)
        vm.expectEmit(true, true, true, true, address(usdt0));
        emit IERC20.Transfer(address(gateway), alice, total);
        vm.expectEmit(true, true, false, true, address(gateway));
        emit PayLightGateway.OrderRefunded(q.orderId, alice, total, false);
        vm.prank(bob);
        gateway.claimRefund(q.orderId);

        assertEq(usdt0.balanceOf(alice), aliceBefore);
        assertEq(usdt0.balanceOf(address(gateway)), 0);
        assertEq(gateway.totalPending(), 0);
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Refunded));

        vm.expectRevert(PayLightGateway.NotPaid.selector);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, keccak256("late"));
    }

    function test_fork_operatorRefund_returnsFullAmount() public {
        PayLightGateway.Quote memory q = _quote(bob, 7e6, 1);
        uint128 total = _total(q);
        uint256 bobBefore = usdt0.balanceOf(bob);
        _pay(q);
        vm.expectEmit(true, true, false, true, address(gateway));
        emit PayLightGateway.OrderRefunded(q.orderId, bob, total, true);
        vm.prank(operator);
        gateway.refund(q.orderId);
        assertEq(usdt0.balanceOf(bob), bobBefore);
        assertEq(gateway.totalPending(), 0);
        assertEq(gateway.settledOrders(bob), 0);
    }

    // ═══════════════════════════════════════════════════════════════ Fee tiers on the REAL circuit

    function test_fork_tier1_viaHolding50RealTransistors() public {
        _giveTransistors(bob, 49);
        assertEq(gateway.computeTier(bob), 0);
        PayLightGateway.Quote memory stale = _quote(bob, 10e6, 1);
        assertEq(stale.fee, 100_000);

        _giveTransistors(bob, 1);
        assertEq(transistors.balanceOf(bob, NAND), 50);
        (uint8 input, uint256 held) = gateway.circuitInput(bob);
        assertEq(held, 50);
        assertEq(input, 1); // h1
        assertEq(gateway.computeTier(bob), 1);

        // a tier-0 quote is now rejected by the on-chain circuit
        bytes memory staleSig = _sign(stale);
        vm.prank(bob);
        usdt0.approve(address(gateway), _total(stale));
        vm.expectRevert(abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(0), uint8(1)));
        vm.prank(bob);
        gateway.pay(stale, staleSig);

        // a tier-0 fee on a tier-1 quote is rejected too
        PayLightGateway.Quote memory over = _quote(bob, 10e6, 1);
        over.fee = 100_000;
        bytes memory overSig = _sign(over);
        vm.expectRevert(abi.encodeWithSelector(PayLightGateway.FeeMismatch.selector, uint128(100_000), uint128(50_000)));
        vm.prank(bob);
        gateway.pay(over, overSig);

        PayLightGateway.Quote memory q = _quote(bob, 10e6, 1);
        assertEq(q.tier, 1);
        assertEq(q.fee, 50_000); // 0.50%
        uint128 total = _total(q);
        bytes memory sig = _sign(q);
        vm.prank(bob);
        usdt0.approve(address(gateway), total);
        vm.expectEmit(true, true, false, true, address(gateway));
        emit PayLightGateway.OrderPaid(q.orderId, bob, total, 50_000, 1, 1, uint64(block.timestamp) + 24 hours);
        vm.prank(bob);
        gateway.pay(q, sig);
        assertEq(gateway.getOrder(q.orderId).tier, 1);
        assertEq(usdt0.balanceOf(address(gateway)), 10_050_000);
    }

    /// @notice Every input combination reachable with real holdings (NAND and LATCH) and real settled orders:
    ///         gateway.computeTier == FeeTierCircuit.expectedTier == the real circuit's eval.
    function test_fork_computeTier_matchesCircuitAndReference_allReachableInputs() public {
        // carol: holdings only
        _assertTierParity(carol, 0, 0);
        _giveTransistors(carol, 25);
        _giveLatches(carol, 25); // LATCH (id 1) counts toward holdings
        _assertTierParity(carol, 1, 1);
        _giveTransistors(carol, 450);
        _assertTierParity(carol, 3, 2);

        // dave: three real settled orders, then holdings
        _fundUsdt0(dave, 100e6);
        for (uint256 i; i < 3; ++i) {
            assertEq(gateway.computeTier(dave), 0);
            PayLightGateway.Quote memory q = _quote(dave, 2e6, 1);
            _pay(q);
            vm.prank(operator);
            gateway.markFulfilled(q.orderId, keccak256(abi.encode("vtpass", i)));
        }
        assertEq(gateway.settledOrders(dave), 3);
        _assertTierParity(dave, 4, 1);
        _giveTransistors(dave, 50);
        _assertTierParity(dave, 5, 1);
        _giveTransistors(dave, 450);
        _assertTierParity(dave, 7, 2);

        // the tier-2 fee is 0.25% end to end
        PayLightGateway.Quote memory t2 = _quote(dave, 20e6, 1);
        assertEq(t2.tier, 2);
        assertEq(t2.fee, 50_000);
        _pay(t2);
        assertEq(gateway.getOrder(t2.orderId).tier, 2);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_fork_computeTier_matchesReference(uint256 held, uint32 settled) public {
        held = bound(held, 0, 700);
        settled = uint32(bound(settled, 0, 6));
        if (held > 0) _giveTransistors(carol, held);
        stdstore.target(address(gateway)).sig("settledOrders(address)").with_key(carol).checked_write(uint256(settled));

        uint8 expectedInput;
        if (held >= 50) expectedInput |= 1;
        if (held >= 500) expectedInput |= 2;
        if (settled >= 3) expectedInput |= 4;
        _assertTierParity(carol, expectedInput, FeeTierCircuit.expectedTier(expectedInput));
    }

    // ═══════════════════════════════════════════════════════════════ external wrappers (for expectRevert)

    function ext_resumeLaunch(address p, address deployer) external returns (Launch memory) {
        return _resumeLaunch(p, deployer);
    }

    function ext_deploy(DeployConfig memory c, address deployer) external returns (Deployment memory) {
        return _deploy(c, deployer);
    }

    function ext_loadConfig() external view returns (DeployConfig memory) {
        return _loadConfig();
    }

    // ═══════════════════════════════════════════════════════════════ helpers

    function _assertTierParity(address payer, uint8 expectedInput, uint8 expectedTier) internal view {
        (uint8 input,) = gateway.circuitInput(payer);
        assertEq(input, expectedInput, "circuit input");
        uint8 tier = gateway.computeTier(payer);
        assertEq(tier, expectedTier, "computeTier");
        assertEq(tier, FeeTierCircuit.expectedTier(input), "reference");
        bytes memory out = processor.eval(feeCircuitId, abi.encodePacked(input));
        assertEq(uint8(out[0]), tier, "real eval");
    }

    function _fundUsdt0(address to, uint256 amount) internal {
        deal(XLAYER_USDT0, to, amount);
        assertEq(usdt0.balanceOf(to), amount, "deal on USD0 proxy");
    }

    function _giveTransistors(address to, uint256 amount) internal {
        _mintTransistors(to, NAND, amount);
    }

    function _giveLatches(address to, uint256 amount) internal {
        _mintTransistors(to, 1, amount);
    }

    function _mintTransistors(address to, uint256 id, uint256 amount) internal {
        uint256 cost = transistors.mintPrice() * amount + transistors.protocolFee();
        vm.deal(to, to.balance + cost);
        uint256 before = transistors.balanceOf(to, id);
        vm.prank(to);
        transistors.mint{value: cost}(id, amount);
        assertEq(transistors.balanceOf(to, id), before + amount);
    }

    function _topUp(uint256 units) internal {
        uint256 cost = router.topUpCost(units);
        vm.prank(keeper);
        router.topUp{value: cost}(units);
    }

    function _quote(address payer, uint128 baseAmount, uint32 units) internal returns (PayLightGateway.Quote memory q) {
        uint8 tier = gateway.computeTier(payer);
        q = PayLightGateway.Quote({
            orderId: keccak256(abi.encode("plfork-order", ++orderSalt)),
            payer: payer,
            baseAmount: baseAmount,
            fee: gateway.previewFee(baseAmount, tier),
            tier: tier,
            cashbackUnits: units,
            expiry: uint64(block.timestamp) + QUOTE_TTL
        });
    }

    function _sign(PayLightGateway.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, gateway.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _total(PayLightGateway.Quote memory q) internal pure returns (uint128) {
        return q.baseAmount + q.fee;
    }

    function _pay(PayLightGateway.Quote memory q) internal {
        bytes memory sig = _sign(q);
        vm.startPrank(q.payer);
        usdt0.approve(address(gateway), _total(q));
        gateway.pay(q, sig);
        vm.stopPrank();
    }

    function _permitSig(uint256 ownerPk, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (PayLightGateway.PermitSig memory p)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(gateway), value, usdt0.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdt0.DOMAIN_SEPARATOR(), structHash));
        (p.v, p.r, p.s) = vm.sign(ownerPk, digest);
        p.deadline = deadline;
    }

    function _authSig(uint256 signerKey, address from, uint256 value, bytes32 orderId)
        internal
        view
        returns (PayLightGateway.AuthorizationSig memory a)
    {
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_TYPEHASH, from, address(gateway), value, a.validAfter, a.validBefore, orderId)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdt0.DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(signerKey, digest);
    }

    function _create(bytes memory initCode) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(a != address(0), "create failed");
    }
}
