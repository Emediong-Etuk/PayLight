// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {PayLightGateway} from "../../src/PayLightGateway.sol";
import {CashbackRouter} from "../../src/CashbackRouter.sol";
import {FeeTierCircuit} from "../../src/libraries/FeeTierCircuit.sol";
import {MockUSDT0} from "../mocks/MockUSDT0.sol";
import {MockTransistors, MockProcessor} from "../mocks/MockTapeOut.sol";

/// @notice Shared deployment + helpers for PayLight unit tests (mock USD₮0 and mock TapeOut that interprets netlists).
///         Parameters mirror the approved sheet (docs/PROCESSOR_PARAMS.md).
abstract contract Fixture is Test {
    // approved parameters
    uint256 internal constant SUPPLY_CAP = 1_000_000;
    uint256 internal constant MINT_PRICE = 0.0001 ether;
    uint256 internal constant PROTOCOL_FEE = 0.00066 ether;
    uint256 internal constant MAX_RESERVE = 200_000;
    uint16 internal constant TIER0_BPS = 100;
    uint16 internal constant TIER1_BPS = 50;
    uint16 internal constant TIER2_BPS = 25;
    uint128 internal constant TIER1_HOLDING = 50;
    uint128 internal constant TIER2_HOLDING = 500;
    uint32 internal constant REPEAT_ORDERS = 3;
    uint128 internal constant MAX_ORDER = 30e6;
    uint128 internal constant DAILY_CAP = 1_000e6;
    uint64 internal constant REFUND_TIMEOUT = 24 hours;
    uint64 internal constant QUOTE_TTL = 120;

    MockUSDT0 internal usdt0;
    MockTransistors internal transistors;
    MockProcessor internal processor;
    PayLightGateway internal gateway;
    CashbackRouter internal router;
    uint256 internal feeCircuitId;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    uint256 internal signerPk;
    address internal quoteSigner;
    uint256 internal alicePk;
    address internal alice;
    uint256 internal bobPk;
    address internal bob;

    uint256 internal nonce; // orderId salt

    function setUp() public virtual {
        vm.warp(1_760_000_000); // a realistic 2025-10 timestamp, mid-day
        (quoteSigner, signerPk) = makeAddrAndKey("quoteSigner");
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");

        usdt0 = new MockUSDT0();
        transistors = new MockTransistors(SUPPLY_CAP, MINT_PRICE, PROTOCOL_FEE, creator);
        processor = new MockProcessor(transistors);
        transistors.setProcessor(address(processor));

        // creator mints 7 NAND and tapes out the FeeTier circuit (circuit id 1)
        vm.deal(creator, 10 ether);
        vm.startPrank(creator);
        transistors.mint{value: MINT_PRICE * FeeTierCircuit.NAND_COUNT + PROTOCOL_FEE}(0, FeeTierCircuit.NAND_COUNT);
        processor.tapeout{value: processor.TAPEOUT_FEE()}(
            FeeTierCircuit.NETLIST, FeeTierCircuit.N_INPUTS, FeeTierCircuit.N_OUTPUTS
        );
        vm.stopPrank();
        feeCircuitId = processor.nextId();

        gateway = new PayLightGateway(_initParams());
        router = new CashbackRouter(address(gateway), address(transistors), admin, keeper, MAX_RESERVE);
        vm.prank(admin);
        gateway.setCashbackRouter(address(router));

        usdt0.mint(alice, 10_000e6);
        usdt0.mint(bob, 10_000e6);
        vm.deal(keeper, 1_000 ether);
    }

    function _initParams() internal view returns (PayLightGateway.InitParams memory p) {
        p.usdt0 = address(usdt0);
        p.processor = address(processor);
        p.admin = admin;
        p.operator = operator;
        p.treasury = treasury;
        p.quoteSigner = quoteSigner;
        p.feeCircuitId = feeCircuitId;
        p.tierFeeBps = [TIER0_BPS, TIER1_BPS, TIER2_BPS];
        p.tier1Holding = TIER1_HOLDING;
        p.tier2Holding = TIER2_HOLDING;
        p.repeatOrders = REPEAT_ORDERS;
        p.maxOrderAmount = MAX_ORDER;
        p.dailyVolumeCap = DAILY_CAP;
        p.refundTimeout = REFUND_TIMEOUT;
    }

    // ─────────────────────────────────────────── helpers

    function _newOrderId() internal returns (bytes32) {
        return keccak256(abi.encode("order", ++nonce));
    }

    /// @dev Builds a quote at the payer's current on-chain tier with the exact required fee.
    function _quote(address payer, uint128 baseAmount, uint32 units) internal returns (PayLightGateway.Quote memory q) {
        uint8 tier = gateway.computeTier(payer);
        q = PayLightGateway.Quote({
            orderId: _newOrderId(),
            payer: payer,
            baseAmount: baseAmount,
            fee: gateway.previewFee(baseAmount, tier),
            tier: tier,
            cashbackUnits: units,
            expiry: uint64(block.timestamp) + QUOTE_TTL
        });
    }

    function _sign(PayLightGateway.Quote memory q) internal view returns (bytes memory) {
        return _signWith(signerPk, q);
    }

    function _signWith(uint256 pk, PayLightGateway.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, gateway.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _total(PayLightGateway.Quote memory q) internal pure returns (uint128) {
        return q.baseAmount + q.fee;
    }

    /// @dev approve + pay as `q.payer`.
    function _pay(PayLightGateway.Quote memory q) internal {
        vm.startPrank(q.payer);
        usdt0.approve(address(gateway), _total(q));
        gateway.pay(q, _sign(q));
        vm.stopPrank();
    }

    function _permitSig(uint256 ownerPk, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (PayLightGateway.PermitSig memory p)
    {
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, owner, address(gateway), value, usdt0.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdt0.DOMAIN_SEPARATOR(), structHash));
        (p.v, p.r, p.s) = vm.sign(ownerPk, digest);
        p.deadline = deadline;
    }

    function _authSig(uint256 fromPk, address from, uint256 value, bytes32 orderId)
        internal
        view
        returns (PayLightGateway.AuthorizationSig memory a)
    {
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                usdt0.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                address(gateway),
                value,
                a.validAfter,
                a.validBefore,
                orderId
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdt0.DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(fromPk, digest);
    }

    function _giveTransistors(address to, uint256 amount) internal {
        vm.deal(to, to.balance + MINT_PRICE * amount + PROTOCOL_FEE);
        vm.prank(to);
        transistors.mint{value: MINT_PRICE * amount + PROTOCOL_FEE}(0, amount);
    }

    function _topUp(uint256 units) internal {
        uint256 cost = router.topUpCost(units);
        vm.prank(keeper);
        router.topUp{value: cost}(units);
    }
}
