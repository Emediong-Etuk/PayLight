// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {stdError} from "forge-std/StdError.sol";

import {Fixture} from "./utils/Fixture.sol";
import {PayLightGateway} from "../src/PayLightGateway.sol";
import {CashbackRouter} from "../src/CashbackRouter.sol";
import {FeeTierCircuit} from "../src/libraries/FeeTierCircuit.sol";
import {MockUSDT0} from "./mocks/MockUSDT0.sol";
import {MockProcessor} from "./mocks/MockTapeOut.sol";
import {GwFeeOnTransferToken, GwRouterMock, GwProcessorStub, GwBadTransistors} from "./mocks/gwMocks.sol";

/// @notice Unit tests for PayLightGateway: constructor, the three pay paths, settlement, refunds, the on-chain fee
///         tier (incl. every TapeOut failure mode), admin and views.
contract PayLightGatewayTest is Fixture {
    bytes32 internal constant ADMIN_ROLE = 0x00;
    bytes32 internal constant OP_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant QUOTE_TYPEHASH_EXPECTED = keccak256(
        "Quote(bytes32 orderId,address payer,uint128 baseAmount,uint128 fee,uint8 tier,uint32 cashbackUnits,uint64 expiry)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant RWA_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    /// @dev Largest base amount whose tier-0 total (base + 1% fee, rounded up) is exactly MAX_ORDER (30e6).
    uint128 internal constant MAX_BASE_TIER0 = 29_702_970;

    address internal carol = makeAddr("carol");
    address internal relayer = makeAddr("relayer");
    address internal attacker = makeAddr("attacker");

    // ═════════════════════════════════════════════════════════════════════════ helpers

    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _gatewayWith(address token, address proc, uint256 circuitId) internal returns (PayLightGateway gw) {
        PayLightGateway.InitParams memory p = _initParams();
        p.usdt0 = token;
        p.processor = proc;
        p.feeCircuitId = circuitId;
        gw = new PayLightGateway(p);
    }

    function _quoteOn(PayLightGateway gw, address payer, uint128 base, uint32 units)
        internal
        returns (PayLightGateway.Quote memory q)
    {
        uint8 tier = gw.computeTier(payer);
        q = PayLightGateway.Quote({
            orderId: _newOrderId(),
            payer: payer,
            baseAmount: base,
            fee: gw.previewFee(base, tier),
            tier: tier,
            cashbackUnits: units,
            expiry: uint64(block.timestamp) + QUOTE_TTL
        });
    }

    function _sigOn(PayLightGateway gw, uint256 pk, PayLightGateway.Quote memory q)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, gw.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Memory structs alias on assignment; this makes a real copy.
    function _copy(PayLightGateway.Quote memory q) internal pure returns (PayLightGateway.Quote memory c) {
        c = PayLightGateway.Quote({
            orderId: q.orderId,
            payer: q.payer,
            baseAmount: q.baseAmount,
            fee: q.fee,
            tier: q.tier,
            cashbackUnits: q.cashbackUnits,
            expiry: q.expiry
        });
    }

    function _approveAs(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        usdt0.approve(spender, amount);
    }

    /// @dev Approves the exact total as the payer, then expects `pay` to revert with `err`.
    function _expectPayRevert(PayLightGateway.Quote memory q, bytes memory sig, bytes memory err) internal {
        _approveAs(q.payer, address(gateway), uint256(q.baseAmount) + q.fee);
        vm.prank(q.payer);
        vm.expectRevert(err);
        gateway.pay(q, sig);
    }

    function _expectPayRevert(PayLightGateway.Quote memory q, bytes memory sig, bytes4 sel) internal {
        _expectPayRevert(q, sig, abi.encodeWithSelector(sel));
    }

    function _payWithSig(PayLightGateway.Quote memory q, bytes memory sig) internal {
        _approveAs(q.payer, address(gateway), uint256(q.baseAmount) + q.fee);
        vm.prank(q.payer);
        gateway.pay(q, sig);
    }

    function _fulfil(bytes32 id) internal {
        vm.prank(operator);
        gateway.markFulfilled(id, keccak256(abi.encode("receipt", id)));
    }

    function _assertStatus(bytes32 id, PayLightGateway.Status s) internal view {
        assertEq(uint8(gateway.getOrder(id).status), uint8(s), "status");
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    function _authSigFull(
        address token,
        uint256 pk,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 authNonce
    ) internal view returns (PayLightGateway.AuthorizationSig memory a) {
        a.validAfter = validAfter;
        a.validBefore = validBefore;
        bytes32 structHash = keccak256(abi.encode(RWA_TYPEHASH, from, to, value, validAfter, validBefore, authNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(pk, digest);
    }

    function _permitSigFull(address token, uint256 pk, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (PayLightGateway.PermitSig memory p)
    {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, ERC20Permit(token).nonces(owner), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (p.v, p.r, p.s) = vm.sign(pk, digest);
        p.deadline = deadline;
    }

    function _giveLatch(address to, uint256 amount) internal {
        vm.deal(to, to.balance + MINT_PRICE * amount + PROTOCOL_FEE);
        vm.prank(to);
        transistors.mint{value: MINT_PRICE * amount + PROTOCOL_FEE}(1, amount);
    }

    /// @dev Pays and settles `n` small orders for `payer` on the fixture gateway (no cashback).
    function _settleOrders(address payer, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            PayLightGateway.Quote memory q = _quote(payer, 1e6, 0);
            _pay(q);
            _fulfil(q.orderId);
        }
    }

    /// @dev Same as _settleOrders, on any gateway that uses the fixture's usdt0, signer and operator.
    function _settleOrdersOn(PayLightGateway gw, address payer, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            PayLightGateway.Quote memory q = _quoteOn(gw, payer, 1e6, 0);
            bytes memory sig = _sigOn(gw, signerPk, q);
            vm.startPrank(payer);
            usdt0.approve(address(gw), uint256(q.baseAmount) + q.fee);
            gw.pay(q, sig);
            vm.stopPrank();
            vm.prank(operator);
            gw.markFulfilled(q.orderId, bytes32(i));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════ constructor

    function test_constructor_initialState() public view {
        assertEq(address(gateway.usdt0()), address(usdt0));
        assertEq(gateway.processor(), address(processor));
        assertEq(gateway.transistors(), address(transistors));
        assertEq(gateway.OPERATOR_ROLE(), OP_ROLE);
        assertEq(gateway.DEFAULT_ADMIN_ROLE(), ADMIN_ROLE);
        assertTrue(gateway.hasRole(ADMIN_ROLE, admin));
        assertTrue(gateway.hasRole(OP_ROLE, operator));
        assertFalse(gateway.hasRole(OP_ROLE, admin));
        assertFalse(gateway.hasRole(ADMIN_ROLE, operator));
        assertFalse(gateway.hasRole(ADMIN_ROLE, address(this)), "deployer gets no role");
        assertEq(gateway.getRoleAdmin(OP_ROLE), ADMIN_ROLE);
        assertEq(gateway.treasury(), treasury);
        assertEq(gateway.quoteSigner(), quoteSigner);
        assertEq(gateway.cashbackRouter(), address(router)); // set by the fixture after deployment
        assertEq(gateway.feeCircuitId(), feeCircuitId);
        assertEq(gateway.tierFeeBps(0), TIER0_BPS);
        assertEq(gateway.tierFeeBps(1), TIER1_BPS);
        assertEq(gateway.tierFeeBps(2), TIER2_BPS);
        assertEq(gateway.tier1Holding(), TIER1_HOLDING);
        assertEq(gateway.tier2Holding(), TIER2_HOLDING);
        assertEq(gateway.repeatOrders(), REPEAT_ORDERS);
        assertEq(gateway.maxOrderAmount(), MAX_ORDER);
        assertEq(gateway.dailyVolumeCap(), DAILY_CAP);
        assertEq(gateway.refundTimeout(), REFUND_TIMEOUT);
        assertEq(gateway.totalPending(), 0);
        assertEq(gateway.dailyVolume(_today()), 0);
        assertFalse(gateway.paused());

        assertEq(gateway.QUOTE_TYPEHASH(), QUOTE_TYPEHASH_EXPECTED);
        assertEq(gateway.MAX_FEE_BPS(), 200);
        assertEq(gateway.MAX_CASHBACK_UNITS(), 50);
        assertEq(gateway.MAX_ORDER_HARD_CAP(), 5_000e6);
        assertEq(gateway.MAX_DAILY_HARD_CAP(), 100_000e6);
        assertEq(gateway.MIN_REFUND_TIMEOUT(), 1 hours);
        assertEq(gateway.MAX_REFUND_TIMEOUT(), 72 hours);
        assertEq(gateway.TIER_COUNT(), 3);
        assertEq(gateway.EVAL_GAS_LIMIT(), 300_000);
        assertEq(gateway.BALANCE_GAS_LIMIT(), 100_000);
        assertTrue(gateway.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_constructor_emitsAllConfigEvents_andStartsWithoutRouter() public {
        PayLightGateway.InitParams memory p = _initParams();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(true, true, true, true, predicted);
        emit IAccessControl.RoleGranted(ADMIN_ROLE, admin, address(this));
        vm.expectEmit(true, true, true, true, predicted);
        emit IAccessControl.RoleGranted(OP_ROLE, operator, address(this));
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.TreasuryUpdated(treasury);
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.QuoteSignerUpdated(quoteSigner);
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.FeeCircuitUpdated(feeCircuitId);
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.TierFeesUpdated(TIER0_BPS, TIER1_BPS, TIER2_BPS);
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.TierThresholdsUpdated(TIER1_HOLDING, TIER2_HOLDING, REPEAT_ORDERS);
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.MaxOrderAmountUpdated(MAX_ORDER);
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.DailyVolumeCapUpdated(DAILY_CAP);
        vm.expectEmit(true, true, true, true, predicted);
        emit PayLightGateway.RefundTimeoutUpdated(REFUND_TIMEOUT);
        PayLightGateway gw = new PayLightGateway(p);

        assertEq(address(gw), predicted);
        assertEq(gw.cashbackRouter(), address(0));
        assertEq(gw.totalPending(), 0);
        assertFalse(gw.paused());
        assertTrue(gw.domainSeparator() != gateway.domainSeparator(), "domain bound to address");
    }

    function _expectDeployRevert(PayLightGateway.InitParams memory p, bytes4 sel) internal {
        vm.expectRevert(sel);
        new PayLightGateway(p);
    }

    function test_constructor_revertsOnEachZeroAddress() public {
        PayLightGateway.InitParams memory p;

        p = _initParams();
        p.usdt0 = address(0);
        _expectDeployRevert(p, PayLightGateway.ZeroAddress.selector);

        p = _initParams();
        p.processor = address(0);
        _expectDeployRevert(p, PayLightGateway.ZeroAddress.selector);

        p = _initParams();
        p.admin = address(0);
        _expectDeployRevert(p, PayLightGateway.ZeroAddress.selector);

        p = _initParams();
        p.treasury = address(0);
        _expectDeployRevert(p, PayLightGateway.ZeroAddress.selector);

        p = _initParams();
        p.quoteSigner = address(0);
        _expectDeployRevert(p, PayLightGateway.ZeroAddress.selector);

        // processor whose transistors() is address(0)
        p = _initParams();
        p.processor = address(new GwProcessorStub(address(0), 0));
        _expectDeployRevert(p, PayLightGateway.ZeroAddress.selector);
    }

    function test_constructor_processorWithoutCode_reverts() public {
        PayLightGateway.InitParams memory p = _initParams();
        p.processor = makeAddr("notAProcessor");
        vm.expectRevert();
        new PayLightGateway(p);
    }

    function test_constructor_zeroOperator_isAllowed_andGrantsNoRole() public {
        PayLightGateway.InitParams memory p = _initParams();
        p.operator = address(0);
        PayLightGateway gw = new PayLightGateway(p);
        assertFalse(gw.hasRole(OP_ROLE, address(0)));
        assertFalse(gw.hasRole(OP_ROLE, operator));
        assertTrue(gw.hasRole(ADMIN_ROLE, admin));
    }

    function test_constructor_zeroFeeCircuit_isAllowed() public {
        PayLightGateway.InitParams memory p = _initParams();
        p.feeCircuitId = 0;
        PayLightGateway gw = new PayLightGateway(p);
        assertEq(gw.feeCircuitId(), 0);
        _giveTransistors(alice, 500);
        assertEq(gw.computeTier(alice), 0);
    }

    function test_constructor_tierFeeBounds() public {
        PayLightGateway.InitParams memory p;
        uint16[3][4] memory bad = [
            [uint16(201), uint16(0), uint16(0)], // tier 0 above MAX_FEE_BPS
            [uint16(100), uint16(101), uint16(0)], // tier 1 dearer than tier 0
            [uint16(100), uint16(50), uint16(51)], // tier 2 dearer than tier 1
            [uint16(201), uint16(201), uint16(201)]
        ];
        for (uint256 i; i < bad.length; ++i) {
            p = _initParams();
            p.tierFeeBps = bad[i];
            _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);
        }
        // boundaries accepted
        p = _initParams();
        p.tierFeeBps = [uint16(200), uint16(200), uint16(200)];
        PayLightGateway gw = new PayLightGateway(p);
        assertEq(gw.tierFeeBps(0), 200);
        assertEq(gw.tierFeeBps(2), 200);
        p.tierFeeBps = [uint16(0), uint16(0), uint16(0)];
        gw = new PayLightGateway(p);
        assertEq(gw.tierFeeBps(0), 0);
    }

    function test_constructor_tierThresholdBounds() public {
        PayLightGateway.InitParams memory p;

        p = _initParams();
        p.tier1Holding = 0;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.tier1Holding = 50;
        p.tier2Holding = 49;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.repeatOrders = 0;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        // t1 == t2 is allowed
        p = _initParams();
        p.tier1Holding = 7;
        p.tier2Holding = 7;
        p.repeatOrders = 1;
        PayLightGateway gw = new PayLightGateway(p);
        assertEq(gw.tier1Holding(), 7);
        assertEq(gw.tier2Holding(), 7);
        assertEq(gw.repeatOrders(), 1);
    }

    function test_constructor_capBounds() public {
        PayLightGateway.InitParams memory p;

        p = _initParams();
        p.maxOrderAmount = 0;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.maxOrderAmount = 5_000e6 + 1;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.dailyVolumeCap = 0;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.dailyVolumeCap = 100_000e6 + 1;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.maxOrderAmount = 5_000e6;
        p.dailyVolumeCap = 100_000e6;
        PayLightGateway gw = new PayLightGateway(p);
        assertEq(gw.maxOrderAmount(), 5_000e6);
        assertEq(gw.dailyVolumeCap(), 100_000e6);

        p.maxOrderAmount = 1;
        p.dailyVolumeCap = 1;
        gw = new PayLightGateway(p);
        assertEq(gw.maxOrderAmount(), 1);
        assertEq(gw.dailyVolumeCap(), 1);
    }

    function test_constructor_refundTimeoutBounds() public {
        PayLightGateway.InitParams memory p;

        p = _initParams();
        p.refundTimeout = 1 hours - 1;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.refundTimeout = 72 hours + 1;
        _expectDeployRevert(p, PayLightGateway.OutOfBounds.selector);

        p = _initParams();
        p.refundTimeout = 1 hours;
        assertEq(new PayLightGateway(p).refundTimeout(), 1 hours);
        p.refundTimeout = 72 hours;
        assertEq(new PayLightGateway(p).refundTimeout(), 72 hours);
    }

    // ═════════════════════════════════════════════════════════════════════════ pay: success

    function test_pay_success_stateAndEvent() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 7);
        assertEq(q.tier, 0);
        assertEq(q.fee, 100_000);
        bytes memory sig = _sign(q);
        uint128 total = 10_100_000;
        uint64 refundableAt = uint64(block.timestamp) + REFUND_TIMEOUT;
        uint256 aliceBefore = usdt0.balanceOf(alice);

        _approveAs(alice, address(gateway), total);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderPaid(q.orderId, alice, total, 100_000, 0, 7, refundableAt);
        vm.prank(alice);
        gateway.pay(q, sig);

        PayLightGateway.Order memory o = gateway.getOrder(q.orderId);
        assertEq(o.payer, alice);
        assertEq(o.paidAt, block.timestamp);
        assertEq(uint8(o.status), uint8(PayLightGateway.Status.Paid));
        assertEq(o.tier, 0);
        assertFalse(o.cashbackCredited);
        assertEq(o.amount, total);
        assertEq(o.fee, 100_000);
        assertEq(o.refundableAt, refundableAt);
        assertEq(o.cashbackUnits, 7);

        assertEq(usdt0.balanceOf(address(gateway)), total);
        assertEq(aliceBefore - usdt0.balanceOf(alice), total);
        assertEq(usdt0.allowance(alice, address(gateway)), 0);
        assertEq(gateway.totalPending(), total);
        assertEq(gateway.dailyVolume(_today()), total);
        assertEq(gateway.settledOrders(alice), 0);
    }

    function test_pay_success_tier1AndTier2_chargeLowerFees() public {
        _giveTransistors(bob, 50);
        PayLightGateway.Quote memory q1 = _quote(bob, 10e6, 1);
        assertEq(q1.tier, 1);
        assertEq(q1.fee, 50_000);
        bytes memory sig1 = _sign(q1);
        _approveAs(bob, address(gateway), _total(q1));
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderPaid(q1.orderId, bob, 10_050_000, 50_000, 1, 1, uint64(block.timestamp) + REFUND_TIMEOUT);
        vm.prank(bob);
        gateway.pay(q1, sig1);
        assertEq(gateway.getOrder(q1.orderId).tier, 1);

        _giveTransistors(bob, 450);
        PayLightGateway.Quote memory q2 = _quote(bob, 10e6, 1);
        assertEq(q2.tier, 2);
        assertEq(q2.fee, 25_000);
        _pay(q2);
        assertEq(gateway.getOrder(q2.orderId).tier, 2);
        assertEq(gateway.totalPending(), 10_050_000 + 10_025_000);
    }

    function test_pay_multipleOrders_accumulatePendingAndVolume() public {
        PayLightGateway.Quote memory a = _quote(alice, 5e6, 0);
        PayLightGateway.Quote memory b = _quote(bob, 7e6, 0);
        _pay(a);
        _pay(b);
        assertEq(gateway.totalPending(), uint256(_total(a)) + _total(b));
        assertEq(gateway.dailyVolume(_today()), uint256(_total(a)) + _total(b));
        assertEq(usdt0.balanceOf(address(gateway)), gateway.totalPending());
    }

    // ═════════════════════════════════════════════════════════════════════════ pay: validation

    function test_pay_revertsPayerMismatch() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        _approveAs(bob, address(gateway), _total(q));
        vm.prank(bob);
        vm.expectRevert(PayLightGateway.PayerMismatch.selector);
        gateway.pay(q, sig);

        // a zero payer in the quote also trips PayerMismatch on `pay` (msg.sender is never zero)
        q.payer = address(0);
        sig = _sign(q);
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.PayerMismatch.selector);
        gateway.pay(q, sig);
    }

    function test_pay_revertsOrderExists_replayAndAfterTerminalStates() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        _payWithSig(q, sig);

        // exact replay
        _expectPayRevert(q, sig, PayLightGateway.OrderExists.selector);

        // same orderId, different (validly signed) terms
        PayLightGateway.Quote memory q2 = _quote(alice, 2e6, 3);
        q2.orderId = q.orderId;
        _expectPayRevert(q2, _sign(q2), PayLightGateway.OrderExists.selector);

        // same orderId from another payer
        PayLightGateway.Quote memory q3 = _quote(bob, 1e6, 0);
        q3.orderId = q.orderId;
        _expectPayRevert(q3, _sign(q3), PayLightGateway.OrderExists.selector);

        // still blocked once fulfilled
        _fulfil(q.orderId);
        _expectPayRevert(q, sig, PayLightGateway.OrderExists.selector);

        // and once refunded
        PayLightGateway.Quote memory r = _quote(alice, 1e6, 0);
        bytes memory rsig = _sign(r);
        _payWithSig(r, rsig);
        vm.prank(operator);
        gateway.refund(r.orderId);
        _expectPayRevert(r, rsig, PayLightGateway.OrderExists.selector);
    }

    function test_orderExists_acrossPayPaths() public {
        // pay -> payWithPermit / payWithAuthorization
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        _payWithSig(q, sig);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.OrderExists.selector);
        gateway.payWithPermit(q, sig, p);
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.OrderExists.selector);
        gateway.payWithAuthorization(q, sig, a);

        // payWithAuthorization -> pay / payWithPermit
        PayLightGateway.Quote memory q2 = _quote(alice, 1e6, 0);
        bytes memory sig2 = _sign(q2);
        PayLightGateway.AuthorizationSig memory a2 = _authSig(alicePk, alice, _total(q2), q2.orderId);
        vm.prank(relayer);
        gateway.payWithAuthorization(q2, sig2, a2);
        _expectPayRevert(q2, sig2, PayLightGateway.OrderExists.selector);
        PayLightGateway.PermitSig memory p2 = _permitSig(alicePk, alice, _total(q2), block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.OrderExists.selector);
        gateway.payWithPermit(q2, sig2, p2);

        // payWithPermit -> payWithAuthorization / pay
        PayLightGateway.Quote memory q3 = _quote(alice, 1e6, 0);
        bytes memory sig3 = _sign(q3);
        PayLightGateway.PermitSig memory p3 = _permitSig(alicePk, alice, _total(q3), block.timestamp + 1 hours);
        vm.prank(alice);
        gateway.payWithPermit(q3, sig3, p3);
        PayLightGateway.AuthorizationSig memory a3 = _authSig(alicePk, alice, _total(q3), q3.orderId);
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.OrderExists.selector);
        gateway.payWithAuthorization(q3, sig3, a3);
        _expectPayRevert(q3, sig3, PayLightGateway.OrderExists.selector);

        assertEq(gateway.totalPending(), uint256(_total(q)) * 3);
    }

    function test_pay_quoteExpiry_boundary() public {
        // expiry == block.timestamp is still valid
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        q.expiry = uint64(block.timestamp);
        _payWithSig(q, _sign(q));
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);

        // a quote expiring at T works at T and fails at T+1
        PayLightGateway.Quote memory q2 = _quote(alice, 1e6, 0);
        bytes memory sig2 = _sign(q2);
        vm.warp(q2.expiry + 1);
        _expectPayRevert(q2, sig2, PayLightGateway.QuoteExpired.selector);
        vm.warp(q2.expiry);
        _payWithSig(q2, sig2);
        _assertStatus(q2.orderId, PayLightGateway.Status.Paid);
    }

    function test_quoteExpired_onPermitAndAuthorizationPaths() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        vm.warp(q.expiry + 1);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.QuoteExpired.selector);
        gateway.payWithPermit(q, sig, p);
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.QuoteExpired.selector);
        gateway.payWithAuthorization(q, sig, a);
    }

    function test_pay_revertsZeroAmount() public {
        PayLightGateway.Quote memory q = _quote(alice, 0, 0);
        assertEq(q.fee, 0);
        _expectPayRevert(q, _sign(q), PayLightGateway.ZeroAmount.selector);
    }

    function test_pay_cashbackUnits_boundary() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 51);
        _expectPayRevert(q, _sign(q), PayLightGateway.TooMuchCashback.selector);

        PayLightGateway.Quote memory ok = _quote(alice, 1e6, 50);
        _payWithSig(ok, _sign(ok));
        assertEq(gateway.getOrder(ok.orderId).cashbackUnits, 50);

        PayLightGateway.Quote memory big = _quote(alice, 1e6, type(uint32).max);
        _expectPayRevert(big, _sign(big), PayLightGateway.TooMuchCashback.selector);
    }

    function test_pay_revertsInvalidTier() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        q.tier = 3;
        _expectPayRevert(q, _sign(q), PayLightGateway.InvalidTier.selector);
        q.tier = 255;
        _expectPayRevert(q, _sign(q), PayLightGateway.InvalidTier.selector);
    }

    function test_pay_revertsFeeMismatch_offByOneBothWays() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        uint128 expected = q.fee;

        q.fee = expected + 1;
        _expectPayRevert(
            q, _sign(q), abi.encodeWithSelector(PayLightGateway.FeeMismatch.selector, expected + 1, expected)
        );
        q.fee = expected - 1;
        _expectPayRevert(
            q, _sign(q), abi.encodeWithSelector(PayLightGateway.FeeMismatch.selector, expected - 1, expected)
        );

        // fee for the wrong tier (tier-1 fee on a tier-1 quote is fine; a tier-0 fee on a tier-1 quote is not)
        q = _quote(alice, 10e6, 0);
        q.tier = 1;
        _expectPayRevert(q, _sign(q), abi.encodeWithSelector(PayLightGateway.FeeMismatch.selector, 100_000, 50_000));
    }

    function test_pay_feeTableChange_invalidatesOutstandingQuote() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        bytes memory sig = _sign(q);
        vm.prank(admin);
        gateway.setTierFees([uint16(80), uint16(50), uint16(25)]);
        _expectPayRevert(q, sig, abi.encodeWithSelector(PayLightGateway.FeeMismatch.selector, 100_000, 80_000));
    }

    function test_pay_orderTooLarge_boundary() public {
        PayLightGateway.Quote memory q = _quote(alice, MAX_BASE_TIER0, 0);
        assertEq(_total(q), MAX_ORDER, "exactly at the cap");
        _payWithSig(q, _sign(q));
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);

        PayLightGateway.Quote memory q2 = _quote(alice, MAX_BASE_TIER0 + 1, 0);
        assertEq(_total(q2), MAX_ORDER + 1, "one unit over");
        _expectPayRevert(q2, _sign(q2), PayLightGateway.OrderTooLarge.selector);
    }

    function test_pay_amountOverflow_reverts() public {
        PayLightGateway.Quote memory q = _quote(alice, type(uint128).max, 0);
        _expectPayRevert(q, _sign(q), stdError.arithmeticError);
    }

    function test_pay_dailyCap_boundary_andUtcRollover() public {
        vm.prank(admin);
        gateway.setDailyVolumeCap(20_200_000);
        uint256 day = _today();
        uint256 nextDayStart = (day + 1) * 1 days;

        PayLightGateway.Quote memory q1 = _quote(alice, 10e6, 0); // 10.1 USD₮0
        _pay(q1);
        PayLightGateway.Quote memory q2 = _quote(bob, 10e6, 0); // 10.1 USD₮0 -> exactly at the cap
        _pay(q2);
        assertEq(gateway.dailyVolume(day), 20_200_000);

        PayLightGateway.Quote memory q3 = _quote(alice, 1, 0); // 1 + 1 fee = 2 units over the cap
        _expectPayRevert(q3, _sign(q3), PayLightGateway.DailyCapExceeded.selector);

        // a refund does not free up daily volume (gross volume is tracked)
        vm.prank(operator);
        gateway.refund(q1.orderId);
        _expectPayRevert(q3, _sign(q3), PayLightGateway.DailyCapExceeded.selector);

        // last second of the same UTC day: still capped
        vm.warp(nextDayStart - 1);
        PayLightGateway.Quote memory q4 = _quote(alice, 1, 0);
        _expectPayRevert(q4, _sign(q4), PayLightGateway.DailyCapExceeded.selector);

        // UTC midnight: fresh cap
        vm.warp(nextDayStart);
        assertEq(_today(), day + 1);
        PayLightGateway.Quote memory q5 = _quote(alice, 10e6, 0);
        _pay(q5);
        PayLightGateway.Quote memory q6 = _quote(bob, 10e6, 0);
        _pay(q6);
        assertEq(gateway.dailyVolume(day + 1), 20_200_000);
        assertEq(gateway.dailyVolume(day), 20_200_000, "previous day untouched");
        PayLightGateway.Quote memory q7 = _quote(alice, 1, 0);
        _expectPayRevert(q7, _sign(q7), PayLightGateway.DailyCapExceeded.selector);
    }

    function test_dailyCap_appliesToPermitAndAuthorizationPaths() public {
        vm.prank(admin);
        gateway.setDailyVolumeCap(10_100_000);
        _pay(_quote(alice, 10e6, 0));

        PayLightGateway.Quote memory q = _quote(alice, 1, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.DailyCapExceeded.selector);
        gateway.payWithPermit(q, sig, p);
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.DailyCapExceeded.selector);
        gateway.payWithAuthorization(q, sig, a);
    }

    function test_pay_insufficientAllowanceOrBalance_reverts() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        // no approval
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), 0, _total(q))
        );
        gateway.pay(q, sig);
        // approval one short
        _approveAs(alice, address(gateway), _total(q) - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), _total(q) - 1, _total(q)
            )
        );
        gateway.pay(q, sig);

        // no balance
        PayLightGateway.Quote memory qc = _quote(carol, 1e6, 0);
        bytes memory sigc = _sign(qc);
        _approveAs(carol, address(gateway), _total(qc));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, _total(qc)));
        gateway.pay(qc, sigc);
    }

    // ═════════════════════════════════════════════════════════════════════════ signatures (EIP-712 binding)

    function test_sig_wrongSigner() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _expectPayRevert(q, _signWith(alicePk, q), PayLightGateway.InvalidSignature.selector);
        _expectPayRevert(q, _signWith(bobPk, q), PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_wrongPayerField() public {
        // signer quoted bob; alice tries to use it for herself
        PayLightGateway.Quote memory q = _quote(bob, 1e6, 0);
        bytes memory sig = _sign(q);
        q.payer = alice;
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_tamperedOrderId() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        q.orderId = keccak256("other order");
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_tamperedAmount() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        bytes memory sig = _sign(q);
        // a smaller base with the same (still correct) rounded-up fee
        q.baseAmount = 9_999_950;
        assertEq(gateway.previewFee(q.baseAmount, 0), q.fee);
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);

        // base and fee changed consistently
        q.baseAmount = 20e6;
        q.fee = 200_000;
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_tamperedFee() public {
        // the signer signed fee = expected + 1; the payer submits the (correct) expected fee
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        PayLightGateway.Quote memory signed = _copy(q);
        signed.fee = q.fee + 1;
        bytes memory sig = _sign(signed);
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_tamperedTier() public {
        // signer quoted tier 1 (with the tier-1 fee); payer submits tier 0 with the tier-0 fee
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        PayLightGateway.Quote memory signed = _copy(q);
        signed.tier = 1;
        signed.fee = gateway.previewFee(q.baseAmount, 1);
        bytes memory sig = _sign(signed);
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_tamperedUnits() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 5);
        bytes memory sig = _sign(q);
        q.cashbackUnits = 6;
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_tamperedExpiry() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        q.expiry += 1;
        _expectPayRevert(q, sig, PayLightGateway.InvalidSignature.selector);
    }

    function test_sig_malformed() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory good = _sign(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, gateway.quoteDigest(q));

        _expectPayRevert(q, "", PayLightGateway.InvalidSignature.selector);
        _expectPayRevert(q, abi.encodePacked(r, s), PayLightGateway.InvalidSignature.selector); // 64 bytes (no EIP-2098)
        _expectPayRevert(q, abi.encodePacked(good, uint8(0)), PayLightGateway.InvalidSignature.selector); // 66 bytes
        _expectPayRevert(q, abi.encodePacked(r, s, uint8(v + 2)), PayLightGateway.InvalidSignature.selector); // bad v
        _expectPayRevert(q, abi.encodePacked(bytes32(0), s, v), PayLightGateway.InvalidSignature.selector); // r = 0
        _expectPayRevert(q, new bytes(65), PayLightGateway.InvalidSignature.selector); // all zero

        // high-s (malleable) twin of a valid signature is rejected
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        _expectPayRevert(q, highS, PayLightGateway.InvalidSignature.selector);

        // the genuine signature still works
        _payWithSig(q, good);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    function test_sig_forDifferentGateway_isRejected() public {
        PayLightGateway other = new PayLightGateway(_initParams());
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        assertTrue(other.quoteDigest(q) != gateway.quoteDigest(q));
        bytes memory sigForOther = _sigOn(other, signerPk, q);
        _expectPayRevert(q, sigForOther, PayLightGateway.InvalidSignature.selector);

        // ...but is accepted by the gateway it was made for
        vm.startPrank(alice);
        usdt0.approve(address(other), _total(q));
        other.pay(q, sigForOther);
        vm.stopPrank();
        assertEq(uint8(other.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Paid));
    }

    function test_sig_forDifferentChainId_isRejected() public {
        uint256 chain = block.chainid;
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes32 here = gateway.quoteDigest(q);

        // signed for another chain, submitted here
        vm.chainId(chain + 1);
        bytes32 there = gateway.quoteDigest(q);
        assertTrue(there != here, "digest bound to chainId");
        bytes memory sigOtherChain = _sign(q);
        vm.chainId(chain);
        _expectPayRevert(q, sigOtherChain, PayLightGateway.InvalidSignature.selector);

        // signed here, replayed on another chain (same address)
        bytes memory sigHere = _sign(q);
        vm.chainId(chain + 1);
        _expectPayRevert(q, sigHere, PayLightGateway.InvalidSignature.selector);
        vm.chainId(chain);
        _payWithSig(q, sigHere);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    // ═════════════════════════════════════════════════════════════════════════ TierChanged

    function test_tierChanged_holdingsRiseBetweenQuoteAndPay() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        bytes memory sig = _sign(q);
        _giveTransistors(alice, 50);
        _expectPayRevert(q, sig, abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(0), uint8(1)));
        // re-quote at the new tier works
        PayLightGateway.Quote memory q2 = _quote(alice, 10e6, 0);
        assertEq(q2.tier, 1);
        _pay(q2);
    }

    function test_tierChanged_holdingsDropBetweenQuoteAndPay() public {
        _giveTransistors(bob, 50);
        PayLightGateway.Quote memory q = _quote(bob, 10e6, 0);
        assertEq(q.tier, 1);
        bytes memory sig = _sign(q);
        vm.prank(bob);
        transistors.safeTransferFrom(bob, carol, 0, 1, "");
        _expectPayRevert(q, sig, abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(1), uint8(0)));
    }

    function test_tierChanged_settledOrdersCrossThreshold() public {
        _settleOrders(alice, 2);
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        assertEq(q.tier, 0);
        bytes memory sig = _sign(q);
        _settleOrders(alice, 1);
        _expectPayRevert(q, sig, abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(0), uint8(1)));
    }

    function test_tierChanged_thresholdsChangedByAdmin() public {
        _giveTransistors(bob, 60);
        PayLightGateway.Quote memory q = _quote(bob, 10e6, 0);
        assertEq(q.tier, 1);
        bytes memory sig = _sign(q);
        vm.prank(admin);
        gateway.setTierThresholds(10, 60, 3);
        _expectPayRevert(q, sig, abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(1), uint8(2)));
    }

    function test_tierChanged_onPermitAndAuthorizationPaths() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        _giveTransistors(alice, 500);
        bytes memory err = abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(0), uint8(2));
        vm.prank(alice);
        vm.expectRevert(err);
        gateway.payWithPermit(q, sig, p);
        vm.prank(relayer);
        vm.expectRevert(err);
        gateway.payWithAuthorization(q, sig, a);
    }

    // ═════════════════════════════════════════════════════════════════════════ pause

    function test_whenNotPaused_onAllThreePayPaths() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(operator);
        gateway.pause();

        _expectPayRevert(q, sig, Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.payWithPermit(q, sig, p);
        vm.prank(relayer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.payWithAuthorization(q, sig, a);

        vm.prank(admin);
        gateway.unpause();
        _payWithSig(q, sig);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    // ═════════════════════════════════════════════════════════════════════════ payWithPermit

    function test_payWithPermit_success_stateAndEvent() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 4);
        bytes memory sig = _sign(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        uint256 nonceBefore = usdt0.nonces(alice);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderPaid(
            q.orderId, alice, _total(q), q.fee, 0, 4, uint64(block.timestamp) + REFUND_TIMEOUT
        );
        vm.prank(alice);
        gateway.payWithPermit(q, sig, p);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
        assertEq(usdt0.nonces(alice), nonceBefore + 1, "permit consumed");
        assertEq(usdt0.allowance(alice, address(gateway)), 0);
        assertEq(usdt0.balanceOf(address(gateway)), _total(q));
        assertEq(gateway.totalPending(), _total(q));
    }

    function test_payWithPermit_revertsPayerMismatch() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        vm.prank(bob);
        vm.expectRevert(PayLightGateway.PayerMismatch.selector);
        gateway.payWithPermit(q, sig, p);
    }

    function test_payWithPermit_frontRunPermit_stillSucceeds() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);

        // attacker copies the permit from the mempool and submits it first
        vm.prank(attacker);
        usdt0.permit(alice, address(gateway), _total(q), p.deadline, p.v, p.r, p.s);
        assertEq(usdt0.allowance(alice, address(gateway)), _total(q));

        // alice's tx: the inner permit now fails (nonce used), but the allowance is already there
        vm.prank(alice);
        gateway.payWithPermit(q, sig, p);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
        assertEq(usdt0.allowance(alice, address(gateway)), 0);
        assertEq(usdt0.balanceOf(address(gateway)), _total(q));
    }

    function test_payWithPermit_existingAllowance_withGarbagePermit_succeeds() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        _approveAs(alice, address(gateway), _total(q));
        PayLightGateway.PermitSig memory junk;
        vm.prank(alice);
        gateway.payWithPermit(q, sig, junk);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    function test_payWithPermit_insufficientAllowance_reverts() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        bytes memory sig = _sign(q);
        bytes memory err = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), 0, _total(q)
        );

        // permit for one unit less than the order total: the gateway's permit call fails, no allowance results
        PayLightGateway.PermitSig memory pShort =
            _permitSig(alicePk, alice, _total(q) - 1, block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(err);
        gateway.payWithPermit(q, sig, pShort);

        // expired permit
        PayLightGateway.PermitSig memory pExpired = _permitSig(alicePk, alice, _total(q), block.timestamp - 1);
        vm.prank(alice);
        vm.expectRevert(err);
        gateway.payWithPermit(q, sig, pExpired);

        // permit signed by someone else
        PayLightGateway.PermitSig memory pBob = _permitSig(bobPk, alice, _total(q), block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(err);
        gateway.payWithPermit(q, sig, pBob);

        // permit front-run AND then the allowance is spent elsewhere / reduced
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        vm.prank(attacker);
        usdt0.permit(alice, address(gateway), _total(q), p.deadline, p.v, p.r, p.s);
        _approveAs(alice, address(gateway), _total(q) - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), _total(q) - 1, _total(q)
            )
        );
        gateway.payWithPermit(q, sig, p);
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.None));
    }

    // ═════════════════════════════════════════════════════════════════════════ payWithAuthorization (EIP-3009)

    function test_payWithAuthorization_success_stateAndEvent() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 9);
        bytes memory sig = _sign(q);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        uint256 aliceBefore = usdt0.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderPaid(
            q.orderId, alice, _total(q), q.fee, 0, 9, uint64(block.timestamp) + REFUND_TIMEOUT
        );
        vm.prank(relayer);
        gateway.payWithAuthorization(q, sig, a);
        PayLightGateway.Order memory o = gateway.getOrder(q.orderId);
        assertEq(o.payer, alice);
        assertEq(o.amount, _total(q));
        assertEq(o.cashbackUnits, 9);
        assertEq(aliceBefore - usdt0.balanceOf(alice), _total(q));
        assertEq(usdt0.balanceOf(relayer), 0);
        assertTrue(usdt0.authorizationState(alice, q.orderId), "nonce == orderId consumed");
        assertEq(gateway.totalPending(), _total(q));
    }

    function test_payWithAuthorization_relayerCanBeAnyone() public {
        address[4] memory senders = [relayer, bob, alice, address(0xdead)];
        for (uint256 i; i < senders.length; ++i) {
            PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
            bytes memory sig = _sign(q);
            PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
            uint256 senderBal = usdt0.balanceOf(senders[i]);
            vm.prank(senders[i]);
            gateway.payWithAuthorization(q, sig, a);
            assertEq(gateway.getOrder(q.orderId).payer, alice);
            if (senders[i] != alice) assertEq(usdt0.balanceOf(senders[i]), senderBal, "relayer pays nothing");
        }
    }

    function test_payWithAuthorization_wrongNonce_fails() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.AuthorizationSig memory a = _authSigFull(
            address(usdt0),
            alicePk,
            alice,
            address(gateway),
            _total(q),
            block.timestamp - 1,
            block.timestamp + 1 hours,
            keccak256("not the order id")
        );
        vm.prank(relayer);
        vm.expectRevert(MockUSDT0.InvalidAuthorization.selector);
        gateway.payWithAuthorization(q, sig, a);
    }

    function test_payWithAuthorization_wrongValueOrPayee_fails() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        // value one short of the order total
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q) - 1, q.orderId);
        vm.prank(relayer);
        vm.expectRevert(MockUSDT0.InvalidAuthorization.selector);
        gateway.payWithAuthorization(q, sig, a);

        // authorization to a different payee
        a = _authSigFull(
            address(usdt0), alicePk, alice, relayer, _total(q), block.timestamp - 1, block.timestamp + 1 hours, q.orderId
        );
        vm.prank(relayer);
        vm.expectRevert(MockUSDT0.InvalidAuthorization.selector);
        gateway.payWithAuthorization(q, sig, a);

        // signed by bob for alice's funds
        a = _authSig(bobPk, alice, _total(q), q.orderId);
        vm.prank(relayer);
        vm.expectRevert(MockUSDT0.InvalidAuthorization.selector);
        gateway.payWithAuthorization(q, sig, a);
    }

    function test_payWithAuthorization_window_enforced() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.AuthorizationSig memory a = _authSigFull(
            address(usdt0), alicePk, alice, address(gateway), _total(q), block.timestamp, block.timestamp + 1, q.orderId
        );
        vm.prank(relayer);
        vm.expectRevert(MockUSDT0.AuthorizationNotYetValid.selector);
        gateway.payWithAuthorization(q, sig, a);

        a = _authSigFull(
            address(usdt0), alicePk, alice, address(gateway), _total(q), 0, block.timestamp, q.orderId
        );
        vm.prank(relayer);
        vm.expectRevert(MockUSDT0.AuthorizationExpired.selector);
        gateway.payWithAuthorization(q, sig, a);
    }

    function test_payWithAuthorization_reusedAuthorization_fails() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(relayer);
        gateway.payWithAuthorization(q, sig, a);

        // exact replay
        vm.prank(attacker);
        vm.expectRevert(PayLightGateway.OrderExists.selector);
        gateway.payWithAuthorization(q, sig, a);

        // replay after the order was refunded: still one order per id, ever
        vm.prank(operator);
        gateway.refund(q.orderId);
        vm.prank(attacker);
        vm.expectRevert(PayLightGateway.OrderExists.selector);
        gateway.payWithAuthorization(q, sig, a);

        // the same authorization attached to a new order (same amount) is bound to the old orderId
        PayLightGateway.Quote memory q2 = _quote(alice, 1e6, 0);
        assertEq(_total(q2), _total(q));
        bytes memory sig2 = _sign(q2);
        vm.prank(attacker);
        vm.expectRevert(MockUSDT0.InvalidAuthorization.selector);
        gateway.payWithAuthorization(q2, sig2, a);

        // and the token itself refuses a second use of the (from, nonce) pair
        vm.prank(address(gateway));
        vm.expectRevert(MockUSDT0.AuthorizationUsed.selector);
        usdt0.receiveWithAuthorization(
            alice, address(gateway), _total(q), a.validAfter, a.validBefore, q.orderId, a.v, a.r, a.s
        );
    }

    function test_payWithAuthorization_zeroPayer_reverts() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        q.payer = address(0);
        bytes memory sig = _sign(q);
        PayLightGateway.AuthorizationSig memory a;
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.ZeroAddress.selector);
        gateway.payWithAuthorization(q, sig, a);
    }

    function test_payWithAuthorization_invalidQuoteSignature_reverts() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _signWith(alicePk, q); // payer can't self-sign a quote
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.InvalidSignature.selector);
        gateway.payWithAuthorization(q, sig, a);
    }

    // ═════════════════════════════════════════════════════════════════════════ TransferMismatch

    function test_transferMismatch_feeOnTransferToken_allPaths() public {
        GwFeeOnTransferToken fot = new GwFeeOnTransferToken();
        PayLightGateway gw = _gatewayWith(address(fot), address(processor), feeCircuitId);
        fot.mint(alice, 1_000e6);

        // control: a normal transfer works
        PayLightGateway.Quote memory q0 = _quoteOn(gw, alice, 1e6, 0);
        bytes memory sig0 = _sigOn(gw, signerPk, q0);
        vm.startPrank(alice);
        fot.approve(address(gw), _total(q0));
        gw.pay(q0, sig0);
        vm.stopPrank();
        assertEq(fot.balanceOf(address(gw)), _total(q0));

        fot.setFeeOn(true);

        // pay
        PayLightGateway.Quote memory q = _quoteOn(gw, alice, 1e6, 0);
        bytes memory sig = _sigOn(gw, signerPk, q);
        vm.startPrank(alice);
        fot.approve(address(gw), _total(q));
        vm.expectRevert(PayLightGateway.TransferMismatch.selector);
        gw.pay(q, sig);
        vm.stopPrank();

        // payWithPermit
        PayLightGateway.PermitSig memory p =
            _permitSigFull(address(fot), alicePk, alice, address(gw), _total(q), block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.TransferMismatch.selector);
        gw.payWithPermit(q, sig, p);

        // payWithAuthorization
        PayLightGateway.AuthorizationSig memory a = _authSigFull(
            address(fot), alicePk, alice, address(gw), _total(q), block.timestamp - 1, block.timestamp + 1 hours, q.orderId
        );
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.TransferMismatch.selector);
        gw.payWithAuthorization(q, sig, a);

        assertEq(gw.totalPending(), _total(q0));
    }

    // ═════════════════════════════════════════════════════════════════════════ markFulfilled

    function test_markFulfilled_onlyOperator() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        address[3] memory callers = [alice, admin, treasury];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], OP_ROLE));
            gateway.markFulfilled(q.orderId, bytes32(0));
        }
    }

    function test_markFulfilled_revertsNotPaid_forNoneFulfilledRefunded() public {
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.markFulfilled(keccak256("unknown"), bytes32(0));

        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        _fulfil(q.orderId);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.markFulfilled(q.orderId, bytes32(0));

        PayLightGateway.Quote memory r = _quote(alice, 1e6, 0);
        _pay(r);
        vm.prank(operator);
        gateway.refund(r.orderId);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.markFulfilled(r.orderId, bytes32(0));
    }

    function test_markFulfilled_settlesToTreasury_creditsCashback() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 5);
        _pay(q);
        bytes32 receipt = keccak256("vtpass-tx");
        uint256 treasuryBefore = usdt0.balanceOf(treasury);

        vm.expectEmit(true, true, true, true, address(router));
        emit CashbackRouter.CashbackCredited(q.orderId, alice, 5);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, receipt, 5, true);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, receipt);

        PayLightGateway.Order memory o = gateway.getOrder(q.orderId);
        assertEq(uint8(o.status), uint8(PayLightGateway.Status.Fulfilled));
        assertTrue(o.cashbackCredited);
        assertEq(usdt0.balanceOf(treasury) - treasuryBefore, _total(q), "whole amount incl. fee to treasury");
        assertEq(usdt0.balanceOf(address(gateway)), 0);
        assertEq(gateway.totalPending(), 0);
        assertEq(gateway.settledOrders(alice), 1);
        (address payer, uint32 units, bool paid) = router.credits(q.orderId);
        assertEq(payer, alice);
        assertEq(units, 5);
        assertFalse(paid);
        assertEq(router.pendingUnits(), 5);
    }

    function test_markFulfilled_settledOrdersIncrementPerPayer() public {
        for (uint256 i = 1; i <= 4; ++i) {
            PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
            _pay(q);
            _fulfil(q.orderId);
            assertEq(gateway.settledOrders(alice), i);
        }
        assertEq(gateway.settledOrders(bob), 0);
        // refunds don't count
        PayLightGateway.Quote memory r = _quote(bob, 1e6, 0);
        _pay(r);
        vm.prank(operator);
        gateway.refund(r.orderId);
        assertEq(gateway.settledOrders(bob), 0);
    }

    function test_markFulfilled_zeroUnits_notCredited() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, bytes32("r"), 0, false);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, bytes32("r"));
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);
        (address payer,,) = router.credits(q.orderId);
        assertEq(payer, address(0));
    }

    function test_markFulfilled_routerUnset_thenRetrySucceeds() public {
        vm.prank(admin);
        gateway.setCashbackRouter(address(0));
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 8);
        _pay(q);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, bytes32("r"), 8, false);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, bytes32("r"));
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(usdt0.balanceOf(treasury), _total(q));

        // retry with no router: does not revert, reports false
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.CashbackCreditRetried(q.orderId, false);
        vm.prank(operator);
        gateway.retryCashbackCredit(q.orderId);
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);

        vm.prank(admin);
        gateway.setCashbackRouter(address(router));
        vm.expectEmit(true, true, true, true, address(router));
        emit CashbackRouter.CashbackCredited(q.orderId, alice, 8);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.CashbackCreditRetried(q.orderId, true);
        vm.prank(operator);
        gateway.retryCashbackCredit(q.orderId);
        assertTrue(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(router.pendingUnits(), 8);

        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotCreditable.selector);
        gateway.retryCashbackCredit(q.orderId);
    }

    function test_markFulfilled_routerReverts_settlementStillSucceeds_thenRetry() public {
        GwRouterMock r = new GwRouterMock();
        r.setMode(GwRouterMock.Mode.Revert);
        vm.prank(admin);
        gateway.setCashbackRouter(address(r));

        PayLightGateway.Quote memory q = _quote(alice, 10e6, 3);
        _pay(q);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, bytes32("r"), 3, false);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, bytes32("r"));
        _assertStatus(q.orderId, PayLightGateway.Status.Fulfilled);
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(usdt0.balanceOf(treasury), _total(q));
        assertEq(gateway.settledOrders(alice), 1);
        assertEq(gateway.totalPending(), 0);

        // retry while still broken: no revert, credited=false
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.CashbackCreditRetried(q.orderId, false);
        vm.prank(operator);
        gateway.retryCashbackCredit(q.orderId);
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);

        // router fixed
        r.setMode(GwRouterMock.Mode.Ok);
        vm.expectEmit(true, true, true, true, address(r));
        emit GwRouterMock.Credited(q.orderId, alice, 3);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.CashbackCreditRetried(q.orderId, true);
        vm.prank(operator);
        gateway.retryCashbackCredit(q.orderId);
        assertTrue(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(r.creditedUnits(q.orderId), 3);
        assertEq(r.creditedPayer(q.orderId), alice);
        assertEq(r.calls(), 1);
    }

    function test_markFulfilled_realRouterForOtherGateway_reverts_thenFixedRouterRetry() public {
        // a CashbackRouter wired to a different gateway reverts NotGateway on credit
        CashbackRouter wrong = new CashbackRouter(makeAddr("otherGateway"), address(transistors), admin, keeper, 1);
        vm.prank(admin);
        gateway.setCashbackRouter(address(wrong));
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 2);
        _pay(q);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, bytes32("r"), 2, false);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, bytes32("r"));

        vm.prank(admin);
        gateway.setCashbackRouter(address(router));
        vm.prank(operator);
        gateway.retryCashbackCredit(q.orderId);
        assertTrue(gateway.getOrder(q.orderId).cashbackCredited);
        (address payer, uint32 units,) = router.credits(q.orderId);
        assertEq(payer, alice);
        assertEq(units, 2);
    }

    function test_markFulfilled_gasBombRouter_settlementStillSucceeds() public {
        GwRouterMock r = new GwRouterMock();
        r.setMode(GwRouterMock.Mode.GasBomb);
        vm.prank(admin);
        gateway.setCashbackRouter(address(r));
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 3);
        _pay(q);
        vm.prank(operator);
        gateway.markFulfilled{gas: 1_000_000}(q.orderId, bytes32("r"));
        _assertStatus(q.orderId, PayLightGateway.Status.Fulfilled);
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(usdt0.balanceOf(treasury), _total(q));
    }

    function test_markFulfilled_routerWithoutCode_settlementStillSucceeds() public {
        // CONTRACT BUG: `try ICashbackRouter(router).credit(...)` on an address with no code fails Solidity's
        // extcodesize pre-check in the *caller*, which try/catch does not catch, so markFulfilled reverts and
        // settlement is blocked (contradicts "a failing cashback router never blocks settlement").
        address noCode = makeAddr("routerWithoutCode");
        vm.prank(admin);
        gateway.setCashbackRouter(noCode);
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 3);
        _pay(q);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, bytes32("r"));
        _assertStatus(q.orderId, PayLightGateway.Status.Fulfilled);
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(usdt0.balanceOf(treasury), _total(q));
    }

    function test_markFulfilled_and_retry_workWhilePaused() public {
        vm.prank(admin);
        gateway.setCashbackRouter(address(0));
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 2);
        _pay(q);
        vm.prank(operator);
        gateway.pause();
        _fulfil(q.orderId);
        _assertStatus(q.orderId, PayLightGateway.Status.Fulfilled);
        vm.prank(admin);
        gateway.setCashbackRouter(address(router));
        vm.prank(operator);
        gateway.retryCashbackCredit(q.orderId);
        assertTrue(gateway.getOrder(q.orderId).cashbackCredited);
        assertTrue(gateway.paused());
    }

    function test_retryCashbackCredit_notCreditable_allCases() public {
        // unknown order
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotCreditable.selector);
        gateway.retryCashbackCredit(keccak256("unknown"));

        // paid, not fulfilled
        PayLightGateway.Quote memory paid = _quote(alice, 1e6, 2);
        _pay(paid);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotCreditable.selector);
        gateway.retryCashbackCredit(paid.orderId);

        // refunded
        vm.prank(operator);
        gateway.refund(paid.orderId);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotCreditable.selector);
        gateway.retryCashbackCredit(paid.orderId);

        // fulfilled and already credited
        PayLightGateway.Quote memory done = _quote(alice, 1e6, 2);
        _pay(done);
        _fulfil(done.orderId);
        assertTrue(gateway.getOrder(done.orderId).cashbackCredited);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotCreditable.selector);
        gateway.retryCashbackCredit(done.orderId);

        // fulfilled with zero cashback units
        PayLightGateway.Quote memory zero = _quote(alice, 1e6, 0);
        _pay(zero);
        _fulfil(zero.orderId);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotCreditable.selector);
        gateway.retryCashbackCredit(zero.orderId);
    }

    function test_retryCashbackCredit_onlyOperator() public {
        vm.prank(admin);
        gateway.setCashbackRouter(address(0));
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 2);
        _pay(q);
        _fulfil(q.orderId);
        vm.prank(alice);
        vm.expectRevert(_unauthorized(alice, OP_ROLE));
        gateway.retryCashbackCredit(q.orderId);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, OP_ROLE));
        gateway.retryCashbackCredit(q.orderId);
    }

    // ═════════════════════════════════════════════════════════════════════════ refund (operator)

    function test_refund_success_fullAmountAndEvent() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 5);
        _pay(q);
        uint256 before = usdt0.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderRefunded(q.orderId, alice, _total(q), true);
        vm.prank(operator);
        gateway.refund(q.orderId);
        assertEq(usdt0.balanceOf(alice) - before, _total(q), "fee refunded too");
        _assertStatus(q.orderId, PayLightGateway.Status.Refunded);
        assertEq(gateway.totalPending(), 0);
        assertEq(usdt0.balanceOf(address(gateway)), 0);
        assertEq(gateway.settledOrders(alice), 0);
        (address payer,,) = router.credits(q.orderId);
        assertEq(payer, address(0), "no cashback for refunded orders");
    }

    function test_refund_onlyOperator() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        address[3] memory callers = [alice, admin, bob];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], OP_ROLE));
            gateway.refund(q.orderId);
        }
    }

    function test_refund_notPaidCases_doubleRefund_afterFulfil() public {
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.refund(keccak256("unknown"));

        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        vm.prank(operator);
        gateway.refund(q.orderId);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.refund(q.orderId);

        PayLightGateway.Quote memory f = _quote(alice, 1e6, 0);
        _pay(f);
        _fulfil(f.orderId);
        vm.prank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.refund(f.orderId);
    }

    function test_refund_worksWhilePaused() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        vm.prank(admin);
        gateway.pause();
        vm.prank(operator);
        gateway.refund(q.orderId);
        _assertStatus(q.orderId, PayLightGateway.Status.Refunded);
    }

    function test_refund_doesNotTouchTapeOut() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        processor.setMode(MockProcessor.Mode.GasBomb);
        vm.prank(operator);
        gateway.refund{gas: 200_000}(q.orderId);
        _assertStatus(q.orderId, PayLightGateway.Status.Refunded);
    }

    // ═════════════════════════════════════════════════════════════════════════ claimRefund (payer)

    function test_claimRefund_notPayer() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1);
        address[3] memory callers = [bob, operator, admin];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(PayLightGateway.NotPayer.selector);
            gateway.claimRefund(q.orderId);
        }
    }

    function test_claimRefund_timingBoundary_andEvent() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        _pay(q);
        uint64 refundableAt = gateway.getOrder(q.orderId).refundableAt;
        assertEq(refundableAt, block.timestamp + REFUND_TIMEOUT);
        bytes memory early = abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, refundableAt);

        vm.prank(alice);
        vm.expectRevert(early);
        gateway.claimRefund(q.orderId);

        vm.warp(refundableAt);
        vm.prank(alice);
        vm.expectRevert(early);
        gateway.claimRefund(q.orderId);

        vm.warp(refundableAt + 1);
        uint256 before = usdt0.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.OrderRefunded(q.orderId, alice, _total(q), false);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        assertEq(usdt0.balanceOf(alice) - before, _total(q));
        _assertStatus(q.orderId, PayLightGateway.Status.Refunded);
        assertEq(gateway.totalPending(), 0);
    }

    function test_claimRefund_worksWhilePaused_withoutTapeOut() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        vm.prank(operator);
        gateway.pause();
        processor.setMode(MockProcessor.Mode.Revert);
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        _assertStatus(q.orderId, PayLightGateway.Status.Refunded);
    }

    function test_claimRefund_deadlineSnapshot_unaffectedByLaterSetRefundTimeout() public {
        uint256 t0 = block.timestamp;
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        uint64 snap = uint64(t0) + REFUND_TIMEOUT;
        bytes memory early = abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, snap);

        // shortening the timeout does not make the existing order refundable earlier
        vm.prank(admin);
        gateway.setRefundTimeout(1 hours);
        assertEq(gateway.getOrder(q.orderId).refundableAt, snap);
        vm.warp(t0 + 1 hours + 1);
        vm.prank(alice);
        vm.expectRevert(early);
        gateway.claimRefund(q.orderId);

        // lengthening it does not push the existing deadline out
        vm.prank(admin);
        gateway.setRefundTimeout(72 hours);
        assertEq(gateway.getOrder(q.orderId).refundableAt, snap);
        vm.warp(snap);
        vm.prank(alice);
        vm.expectRevert(early);
        gateway.claimRefund(q.orderId);
        vm.warp(snap + 1);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        _assertStatus(q.orderId, PayLightGateway.Status.Refunded);

        // new orders use the new timeout
        PayLightGateway.Quote memory q2 = _quote(alice, 1e6, 0);
        _pay(q2);
        assertEq(gateway.getOrder(q2.orderId).refundableAt, block.timestamp + 72 hours);
    }

    function test_claimRefund_doubleClaim_afterFulfil_afterOperatorRefund_unknown() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        PayLightGateway.Quote memory f = _quote(alice, 1e6, 0);
        _pay(f);
        PayLightGateway.Quote memory r = _quote(alice, 1e6, 0);
        _pay(r);
        _fulfil(f.orderId);
        vm.prank(operator);
        gateway.refund(r.orderId);
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1);

        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.claimRefund(q.orderId);

        vm.prank(alice);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.claimRefund(f.orderId);

        vm.prank(alice);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.claimRefund(r.orderId);

        // unknown order: NotPaid is checked before NotPayer
        vm.prank(bob);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.claimRefund(keccak256("unknown"));
    }

    function test_claimRefund_thenOperatorCannotFulfilOrRefund() public {
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        vm.startPrank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.markFulfilled(q.orderId, bytes32(0));
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.refund(q.orderId);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════ computeTier: TapeOut failure modes

    function _assertFallsBackToTier0(MockProcessor.Mode m) internal {
        _giveTransistors(alice, 500);
        assertEq(gateway.computeTier(alice), 2, "normal mode: tier 2");

        processor.setMode(m);
        assertEq(gateway.computeTier(alice), 0, "fallback to tier 0");
        (uint8 input, uint256 held) = gateway.circuitInput(alice);
        assertEq(input, 3, "inputs unaffected");
        assertEq(held, 500);

        // a tier-0 quote (highest published fee) still pays
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 1);
        assertEq(q.tier, 0);
        assertEq(q.fee, 100_000);
        _pay(q);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
        assertEq(gateway.getOrder(q.orderId).tier, 0);

        // a stale tier-2 quote is rejected rather than undercharging
        PayLightGateway.Quote memory q2 = _quote(alice, 10e6, 1);
        q2.tier = 2;
        q2.fee = gateway.previewFee(10e6, 2);
        _expectPayRevert(q2, _sign(q2), abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(2), uint8(0)));

        // settlement and refunds are unaffected
        _fulfil(q.orderId);
        _assertStatus(q.orderId, PayLightGateway.Status.Fulfilled);

        processor.setMode(MockProcessor.Mode.Normal);
        assertEq(gateway.computeTier(alice), 2, "recovers");
    }

    function test_tapeOutFailure_Revert() public {
        _assertFallsBackToTier0(MockProcessor.Mode.Revert);
    }

    function test_tapeOutFailure_Empty() public {
        _assertFallsBackToTier0(MockProcessor.Mode.Empty);
    }

    function test_tapeOutFailure_BadOffset() public {
        _assertFallsBackToTier0(MockProcessor.Mode.BadOffset);
    }

    function test_tapeOutFailure_Tier3() public {
        _assertFallsBackToTier0(MockProcessor.Mode.Tier3);
    }

    function test_tapeOutFailure_GasBomb() public {
        _assertFallsBackToTier0(MockProcessor.Mode.GasBomb);
    }

    function test_tapeOutFailure_HugeReturn() public {
        _assertFallsBackToTier0(MockProcessor.Mode.HugeReturn);
    }

    function test_tapeOutFailure_ShortReturn() public {
        _assertFallsBackToTier0(MockProcessor.Mode.ShortReturn);
    }

    function test_tapeOutFailure_unknownCircuitId() public {
        _giveTransistors(alice, 500);
        vm.prank(admin);
        gateway.setFeeCircuit(999);
        assertEq(gateway.computeTier(alice), 0);
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    function test_computeTier_normalMode_truthTable() public {
        // (NAND, LATCH, settled) -> expected circuit input, tier. h2 without h1 is unreachable because t2 >= t1.
        uint256[3][10] memory s = [
            [uint256(0), 0, 0],
            [uint256(49), 0, 0],
            [uint256(50), 0, 0],
            [uint256(25), 25, 0],
            [uint256(499), 0, 0],
            [uint256(500), 0, 0],
            [uint256(0), 0, 2],
            [uint256(0), 0, 3],
            [uint256(50), 0, 3],
            [uint256(450), 50, 3]
        ];
        uint8[10] memory inputs = [0, 0, 1, 1, 1, 3, 0, 4, 5, 7];
        uint8[10] memory tiers = [0, 0, 1, 1, 1, 2, 0, 1, 1, 2];

        for (uint256 i; i < s.length; ++i) {
            address u = makeAddr(string(abi.encodePacked("tt", vm.toString(i))));
            usdt0.mint(u, 100e6);
            if (s[i][2] > 0) _settleOrders(u, s[i][2]);
            if (s[i][0] > 0) _giveTransistors(u, s[i][0]);
            if (s[i][1] > 0) _giveLatch(u, s[i][1]);

            (uint8 input, uint256 held) = gateway.circuitInput(u);
            assertEq(held, s[i][0] + s[i][1], "held = NAND + LATCH");
            assertEq(input, inputs[i], "circuit input");
            assertEq(gateway.computeTier(u), tiers[i], "tier");
            assertEq(tiers[i], FeeTierCircuit.expectedTier(inputs[i]), "reference");

            // and a quote at that tier pays with that tier's fee
            PayLightGateway.Quote memory q = _quote(u, 10e6, 0);
            assertEq(q.tier, tiers[i]);
            assertEq(q.fee, uint128(10e6) * gateway.tierFeeBps(tiers[i]) / 10_000);
            _pay(q);
            assertEq(gateway.getOrder(q.orderId).tier, tiers[i]);
        }
    }

    function test_computeTier_allEightCircuitInputs_viaProcessor() public view {
        for (uint8 x; x < 8; ++x) {
            bytes memory out = processor.eval(feeCircuitId, abi.encodePacked(x));
            assertEq(uint8(out[0]), FeeTierCircuit.expectedTier(x));
        }
    }

    function test_computeTier_feeCircuitZero_disablesTiering() public {
        _giveTransistors(bob, 500);
        assertEq(gateway.computeTier(bob), 2);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.FeeCircuitUpdated(0);
        vm.prank(admin);
        gateway.setFeeCircuit(0);
        assertEq(gateway.computeTier(bob), 0);
        // no TapeOut call and no gas guard when disabled
        processor.setMode(MockProcessor.Mode.GasBomb);
        assertEq(gateway.computeTier{gas: 30_000}(bob), 0);

        PayLightGateway.Quote memory q = _quote(bob, 10e6, 0);
        assertEq(q.tier, 0);
        _pay(q);
        PayLightGateway.Quote memory q2 = _quote(bob, 10e6, 0);
        q2.tier = 2;
        q2.fee = gateway.previewFee(10e6, 2);
        _expectPayRevert(q2, _sign(q2), abi.encodeWithSelector(PayLightGateway.TierChanged.selector, uint8(2), uint8(0)));

        // re-enable
        processor.setMode(MockProcessor.Mode.Normal);
        vm.prank(admin);
        gateway.setFeeCircuit(feeCircuitId);
        assertEq(gateway.computeTier(bob), 2);
    }

    function test_computeTier_insufficientGas_reverts() public {
        _giveTransistors(alice, 50);
        vm.expectRevert(PayLightGateway.InsufficientGasForTier.selector);
        gateway.computeTier{gas: 100_000}(alice);
        vm.expectRevert(PayLightGateway.InsufficientGasForTier.selector);
        gateway.computeTier{gas: 520_000}(alice);
        assertEq(gateway.computeTier{gas: 700_000}(alice), 1);
    }

    function test_pay_starvedGas_revertsInsteadOfFallingBack() public {
        _giveTransistors(alice, 50);
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        assertEq(q.tier, 1);
        bytes memory sig = _sign(q);
        _approveAs(alice, address(gateway), _total(q));
        vm.prank(alice);
        vm.expectRevert(PayLightGateway.InsufficientGasForTier.selector);
        gateway.pay{gas: 450_000}(q, sig);

        // a relayer cannot starve the tier lookup either
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(relayer);
        vm.expectRevert(PayLightGateway.InsufficientGasForTier.selector);
        gateway.payWithAuthorization{gas: 450_000}(q, sig, a);

        vm.prank(alice);
        gateway.pay{gas: 2_000_000}(q, sig);
        assertEq(gateway.getOrder(q.orderId).tier, 1);
    }

    /// @dev Sweeps the gas given to computeTier around the guard. With an eval that genuinely needs ~292k gas and
    ///      balance calls that burn their full 100k cap each, every non-reverting call must return the true tier:
    ///      the guard must never let a starved (but honest) TapeOut call silently degrade to tier 0.
    function test_computeTier_gasGuard_neverReturnsStarvedResult() public {
        GwBadTransistors bt = new GwBadTransistors();
        GwProcessorStub stub = new GwProcessorStub(address(bt), 290_000);
        PayLightGateway gw = _gatewayWith(address(usdt0), address(stub), 1);
        _settleOrdersOn(gw, bob, 3); // r = 1 -> tier 1 even when balances read 0
        assertEq(gw.computeTier(bob), 1, "calibration: heavy eval fits in the 300k cap");

        bt.setMode(GwBadTransistors.Mode.GasBomb);
        assertEq(gw.computeTier(bob), 1, "balances fail -> held 0, r still 1");

        uint256 ok;
        uint256 guarded;
        for (uint256 g = 480_000; g <= 640_000; g += 2_000) {
            vm.cool(address(gw));
            vm.cool(address(bt));
            vm.cool(address(stub));
            try gw.computeTier{gas: g}(bob) returns (uint8 t) {
                assertEq(t, 1, "starved TapeOut call degraded the tier");
                ++ok;
            } catch (bytes memory err) {
                if (err.length > 0) {
                    assertEq(bytes4(err), PayLightGateway.InsufficientGasForTier.selector);
                    ++guarded;
                }
            }
        }
        assertGt(ok, 0);
        assertGt(guarded, 0);
    }

    function test_computeTier_balanceFailureModes_fallBackToZeroHoldings() public {
        GwBadTransistors bt = new GwBadTransistors();
        GwProcessorStub stub = new GwProcessorStub(address(bt), 0);
        PayLightGateway gw = _gatewayWith(address(usdt0), address(stub), 1);
        assertEq(gw.transistors(), address(bt));
        bt.setBalance(alice, 0, 450);
        bt.setBalance(alice, 1, 50);
        assertEq(gw.computeTier(alice), 2);

        GwBadTransistors.Mode[3] memory failing =
            [GwBadTransistors.Mode.Revert, GwBadTransistors.Mode.GasBomb, GwBadTransistors.Mode.ShortReturn];
        for (uint256 i; i < failing.length; ++i) {
            bt.setMode(failing[i]);
            (uint8 input, uint256 held) = gw.circuitInput(alice);
            assertEq(held, 0);
            assertEq(input, 0);
            assertEq(gw.computeTier(alice), 0);
            PayLightGateway.Quote memory q = _quoteOn(gw, alice, 1e6, 0);
            bytes memory sig = _sigOn(gw, signerPk, q);
            vm.startPrank(alice);
            usdt0.approve(address(gw), _total(q));
            gw.pay(q, sig);
            vm.stopPrank();
            assertEq(uint8(gw.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Paid));
        }

        // a huge return is read safely (only 32 bytes copied)
        bt.setMode(GwBadTransistors.Mode.HugeReturn);
        (, uint256 heldHuge) = gw.circuitInput(alice);
        assertEq(heldHuge, 500);
        assertEq(gw.computeTier(alice), 2);
    }

    function test_computeTier_maxBalances_mustNotBlockPayments() public {
        // CONTRACT BUG: `_safeBalance(NAND) + _safeBalance(LATCH)` is a checked add on two untrusted TapeOut values.
        // A misbehaving / upgraded transistor contract returning huge balances makes computeTier panic (0x11), so
        // every pay* reverts -- TapeOut CAN block payments, contradicting the contract's stated guarantee.
        GwBadTransistors bt = new GwBadTransistors();
        GwProcessorStub stub = new GwProcessorStub(address(bt), 0);
        PayLightGateway gw = _gatewayWith(address(usdt0), address(stub), 1);
        bt.setMode(GwBadTransistors.Mode.MaxBalance);

        uint8 tier = gw.computeTier(alice);
        assertLt(tier, 3);
        PayLightGateway.Quote memory q = _quoteOn(gw, alice, 1e6, 0);
        bytes memory sig = _sigOn(gw, signerPk, q);
        vm.startPrank(alice);
        usdt0.approve(address(gw), _total(q));
        gw.pay(q, sig);
        vm.stopPrank();
        assertEq(uint8(gw.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Paid));
    }

    function test_circuitInput_view() public {
        (uint8 input, uint256 held) = gateway.circuitInput(alice);
        assertEq(input, 0);
        assertEq(held, 0);
        _giveTransistors(alice, 30);
        _giveLatch(alice, 20);
        (input, held) = gateway.circuitInput(alice);
        assertEq(held, 50);
        assertEq(input, 1);
        _giveTransistors(alice, 450);
        (input, held) = gateway.circuitInput(alice);
        assertEq(input, 3);
        _settleOrders(alice, 3);
        (input, held) = gateway.circuitInput(alice);
        assertEq(input, 7);
        assertEq(held, 500);
        // independent of the processor's health
        processor.setMode(MockProcessor.Mode.Revert);
        (input,) = gateway.circuitInput(alice);
        assertEq(input, 7);
    }

    // ═════════════════════════════════════════════════════════════════════════ admin

    function test_admin_everySetterRequiresAdmin() public {
        address[3] memory callers = [alice, operator, keeper];
        for (uint256 i; i < callers.length; ++i) {
            address who = callers[i];
            bytes memory err = _unauthorized(who, ADMIN_ROLE);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setTreasury(bob);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setQuoteSigner(bob);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setCashbackRouter(bob);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setFeeCircuit(2);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setTierFees([uint16(10), uint16(5), uint16(1)]);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setTierThresholds(1, 2, 3);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setMaxOrderAmount(1e6);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setDailyVolumeCap(1e6);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.setRefundTimeout(2 hours);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.unpause();

            vm.prank(who);
            vm.expectRevert(err);
            gateway.rescueToken(address(usdt0), who, 0);

            vm.prank(who);
            vm.expectRevert(err);
            gateway.grantRole(OP_ROLE, who);
        }
    }

    function test_setTreasury() public {
        vm.prank(admin);
        vm.expectRevert(PayLightGateway.ZeroAddress.selector);
        gateway.setTreasury(address(0));

        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.TreasuryUpdated(newTreasury);
        vm.prank(admin);
        gateway.setTreasury(newTreasury);
        assertEq(gateway.treasury(), newTreasury);

        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        _fulfil(q.orderId);
        assertEq(usdt0.balanceOf(newTreasury), _total(q));
        assertEq(usdt0.balanceOf(treasury), 0);
    }

    function test_setQuoteSigner() public {
        vm.prank(admin);
        vm.expectRevert(PayLightGateway.ZeroAddress.selector);
        gateway.setQuoteSigner(address(0));

        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory oldSig = _sign(q);
        (address newSigner, uint256 newPk) = makeAddrAndKey("newSigner");
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.QuoteSignerUpdated(newSigner);
        vm.prank(admin);
        gateway.setQuoteSigner(newSigner);
        assertEq(gateway.quoteSigner(), newSigner);

        _expectPayRevert(q, oldSig, PayLightGateway.InvalidSignature.selector);
        _payWithSig(q, _signWith(newPk, q));
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    function test_setCashbackRouter_includingZero() public {
        address r = makeAddr("r");
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.CashbackRouterUpdated(r);
        vm.prank(admin);
        gateway.setCashbackRouter(r);
        assertEq(gateway.cashbackRouter(), r);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.CashbackRouterUpdated(address(0));
        vm.prank(admin);
        gateway.setCashbackRouter(address(0));
        assertEq(gateway.cashbackRouter(), address(0));
    }

    function test_setFeeCircuit() public {
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.FeeCircuitUpdated(42);
        vm.prank(admin);
        gateway.setFeeCircuit(42);
        assertEq(gateway.feeCircuitId(), 42);
    }

    function test_setTierFees_boundsAndEvent() public {
        uint16[3][4] memory bad = [
            [uint16(201), uint16(0), uint16(0)],
            [uint16(100), uint16(101), uint16(0)],
            [uint16(100), uint16(50), uint16(51)],
            [uint16(type(uint16).max), uint16(0), uint16(0)]
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(PayLightGateway.OutOfBounds.selector);
            gateway.setTierFees(bad[i]);
        }
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.TierFeesUpdated(200, 150, 150);
        vm.prank(admin);
        gateway.setTierFees([uint16(200), uint16(150), uint16(150)]);
        assertEq(gateway.tierFeeBps(0), 200);
        assertEq(gateway.tierFeeBps(1), 150);
        assertEq(gateway.tierFeeBps(2), 150);
        assertEq(gateway.previewFee(10e6, 0), 200_000);

        // zero fees are allowed and pay with fee 0
        vm.prank(admin);
        gateway.setTierFees([uint16(0), uint16(0), uint16(0)]);
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        assertEq(q.fee, 0);
        _pay(q);
        assertEq(gateway.getOrder(q.orderId).amount, 10e6);
    }

    function test_setTierThresholds_boundsAndEvent() public {
        vm.startPrank(admin);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setTierThresholds(0, 10, 1);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setTierThresholds(10, 9, 1);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setTierThresholds(10, 20, 0);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.TierThresholdsUpdated(10, 10, 1);
        gateway.setTierThresholds(10, 10, 1);
        vm.stopPrank();
        assertEq(gateway.tier1Holding(), 10);
        assertEq(gateway.tier2Holding(), 10);
        assertEq(gateway.repeatOrders(), 1);

        _giveTransistors(bob, 10);
        assertEq(gateway.computeTier(bob), 2, "t1 == t2 -> straight to tier 2");
        _settleOrders(alice, 1);
        assertEq(gateway.computeTier(alice), 1);
    }

    function test_setMaxOrderAmount_boundsAndEvent() public {
        vm.startPrank(admin);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setMaxOrderAmount(0);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setMaxOrderAmount(5_000e6 + 1);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.MaxOrderAmountUpdated(5_000e6);
        gateway.setMaxOrderAmount(5_000e6);
        vm.stopPrank();
        assertEq(gateway.maxOrderAmount(), 5_000e6);

        PayLightGateway.Quote memory q = _quote(alice, 100e6, 0); // above the old 30 USD₮0 cap
        _pay(q);
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    function test_setDailyVolumeCap_boundsAndEvent() public {
        vm.startPrank(admin);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setDailyVolumeCap(0);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setDailyVolumeCap(100_000e6 + 1);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.DailyVolumeCapUpdated(100_000e6);
        gateway.setDailyVolumeCap(100_000e6);
        vm.stopPrank();
        assertEq(gateway.dailyVolumeCap(), 100_000e6);
    }

    function test_setRefundTimeout_boundsAndEvent() public {
        vm.startPrank(admin);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setRefundTimeout(1 hours - 1);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        gateway.setRefundTimeout(72 hours + 1);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.RefundTimeoutUpdated(1 hours);
        gateway.setRefundTimeout(1 hours);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.RefundTimeoutUpdated(72 hours);
        gateway.setRefundTimeout(72 hours);
        vm.stopPrank();
        assertEq(gateway.refundTimeout(), 72 hours);
    }

    function test_pause_byOperatorAndByAdmin_unpauseOnlyAdmin() public {
        vm.expectEmit(true, true, true, true, address(gateway));
        emit Pausable.Paused(operator);
        vm.prank(operator);
        gateway.pause();
        assertTrue(gateway.paused());

        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, ADMIN_ROLE));
        gateway.unpause();

        vm.expectEmit(true, true, true, true, address(gateway));
        emit Pausable.Unpaused(admin);
        vm.prank(admin);
        gateway.unpause();
        assertFalse(gateway.paused());

        vm.expectEmit(true, true, true, true, address(gateway));
        emit Pausable.Paused(admin);
        vm.prank(admin);
        gateway.pause();
        assertTrue(gateway.paused());

        // double pause / unpause while unpaused
        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.pause();
        vm.prank(admin);
        gateway.unpause();
        vm.prank(admin);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        gateway.unpause();
    }

    function test_pause_unauthorized() public {
        address[3] memory callers = [alice, treasury, keeper];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], OP_ROLE));
            gateway.pause();
        }
    }

    function test_roles_adminManagesOperators() public {
        vm.startPrank(admin);
        gateway.grantRole(OP_ROLE, keeper);
        gateway.revokeRole(OP_ROLE, operator);
        vm.stopPrank();

        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, OP_ROLE));
        gateway.markFulfilled(q.orderId, bytes32(0));
        vm.prank(keeper);
        gateway.markFulfilled(q.orderId, bytes32(0));
        _assertStatus(q.orderId, PayLightGateway.Status.Fulfilled);

        // a revoked operator can no longer pause either
        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, OP_ROLE));
        gateway.pause();
    }

    function test_rescueToken_nonUsdt0_fullyRescuable() public {
        MockUSDT0 other = new MockUSDT0();
        other.mint(address(gateway), 7e6);
        _pay(_quote(alice, 1e6, 0)); // pending USD₮0 is irrelevant for other tokens
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.TokenRescued(address(other), treasury, 7e6);
        vm.prank(admin);
        gateway.rescueToken(address(other), treasury, 7e6);
        assertEq(other.balanceOf(treasury), 7e6);
        assertEq(other.balanceOf(address(gateway)), 0);
    }

    function test_rescueToken_usdt0_onlyExcessAbovePending() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        _pay(q);
        uint256 pending = gateway.totalPending();

        // no excess: even 1 unit is refused, 0 is fine
        vm.prank(admin);
        vm.expectRevert(PayLightGateway.RescueExceedsExcess.selector);
        gateway.rescueToken(address(usdt0), treasury, 1);
        vm.prank(admin);
        gateway.rescueToken(address(usdt0), treasury, 0);

        // someone sends 5 USD₮0 directly
        usdt0.mint(address(gateway), 5e6);
        vm.prank(admin);
        vm.expectRevert(PayLightGateway.RescueExceedsExcess.selector);
        gateway.rescueToken(address(usdt0), treasury, 5e6 + 1);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit PayLightGateway.TokenRescued(address(usdt0), treasury, 5e6);
        vm.prank(admin);
        gateway.rescueToken(address(usdt0), treasury, 5e6);
        assertEq(usdt0.balanceOf(treasury), 5e6);
        assertEq(usdt0.balanceOf(address(gateway)), pending);

        vm.prank(admin);
        vm.expectRevert(PayLightGateway.RescueExceedsExcess.selector);
        gateway.rescueToken(address(usdt0), treasury, 1);

        // the escrow is intact: the payer can still be refunded in full
        vm.prank(operator);
        gateway.refund(q.orderId);
        assertEq(gateway.totalPending(), 0);
    }

    function test_rescueToken_usdt0_balanceBelowPending_reverts() public {
        _pay(_quote(alice, 10e6, 0));
        uint256 pending = gateway.totalPending();
        // simulate an external balance loss (e.g. issuer action) that breaks the invariant
        deal(address(usdt0), address(gateway), pending - 1);
        vm.prank(admin);
        vm.expectRevert(PayLightGateway.RescueExceedsExcess.selector);
        gateway.rescueToken(address(usdt0), treasury, 0);
    }

    function test_rescueToken_zeroRecipient_reverts() public {
        MockUSDT0 other = new MockUSDT0();
        other.mint(address(gateway), 1);
        vm.prank(admin);
        vm.expectRevert(PayLightGateway.ZeroAddress.selector);
        gateway.rescueToken(address(other), address(0), 1);
        vm.prank(admin);
        vm.expectRevert(PayLightGateway.ZeroAddress.selector);
        gateway.rescueToken(address(usdt0), address(0), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════ views

    function test_tierFeeBps_values_andInvalidTier() public {
        assertEq(gateway.tierFeeBps(0), 100);
        assertEq(gateway.tierFeeBps(1), 50);
        assertEq(gateway.tierFeeBps(2), 25);
        vm.expectRevert(PayLightGateway.InvalidTier.selector);
        gateway.tierFeeBps(3);
        vm.expectRevert(PayLightGateway.InvalidTier.selector);
        gateway.tierFeeBps(255);
        vm.expectRevert(PayLightGateway.InvalidTier.selector);
        gateway.previewFee(1e6, 3);
    }

    function test_previewFee_roundsUp() public view {
        // tier 0 = 100 bps
        assertEq(gateway.previewFee(0, 0), 0);
        assertEq(gateway.previewFee(1, 0), 1);
        assertEq(gateway.previewFee(99, 0), 1);
        assertEq(gateway.previewFee(100, 0), 1);
        assertEq(gateway.previewFee(101, 0), 2);
        assertEq(gateway.previewFee(10_000, 0), 100);
        assertEq(gateway.previewFee(10_001, 0), 101);
        assertEq(gateway.previewFee(3_300_000, 0), 33_000);
        // tier 1 = 50 bps
        assertEq(gateway.previewFee(1, 1), 1);
        assertEq(gateway.previewFee(200, 1), 1);
        assertEq(gateway.previewFee(201, 1), 2);
        // tier 2 = 25 bps
        assertEq(gateway.previewFee(1, 2), 1);
        assertEq(gateway.previewFee(400, 2), 1);
        assertEq(gateway.previewFee(401, 2), 2);
        // no overflow at the top of the range
        uint128 max = type(uint128).max;
        assertEq(gateway.previewFee(max, 0), uint128((uint256(max) * 100 + 9_999) / 10_000));
    }

    function test_quoteDigest_matchesManualEip712() public view {
        PayLightGateway.Quote memory q = PayLightGateway.Quote({
            orderId: keccak256("manual"),
            payer: alice,
            baseAmount: 12_345_678,
            fee: 123_457,
            tier: 0,
            cashbackUnits: 12,
            expiry: 1_760_000_120
        });
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("PayLightGateway")), keccak256(bytes("1")), block.chainid, address(gateway)
            )
        );
        assertEq(gateway.domainSeparator(), domain);
        assertEq(gateway.QUOTE_TYPEHASH(), QUOTE_TYPEHASH_EXPECTED);
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH_EXPECTED, q.orderId, q.payer, q.baseAmount, q.fee, q.tier, q.cashbackUnits, q.expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        assertEq(gateway.quoteDigest(q), digest);

        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = gateway.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "PayLightGateway");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(gateway));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_quoteDigest_manualSignaturePays() public {
        PayLightGateway.Quote memory q = _quote(alice, 2e6, 1);
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("PayLightGateway")), keccak256(bytes("1")), block.chainid, address(gateway)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH_EXPECTED, q.orderId, q.payer, q.baseAmount, q.fee, q.tier, q.cashbackUnits, q.expiry
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        _payWithSig(q, abi.encodePacked(r, s, v));
        _assertStatus(q.orderId, PayLightGateway.Status.Paid);
    }

    function test_domainSeparator_tracksChainId() public {
        bytes32 before = gateway.domainSeparator();
        uint256 chain = block.chainid;
        vm.chainId(chain + 7);
        bytes32 expected = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("PayLightGateway")), keccak256(bytes("1")), chain + 7, address(gateway)
            )
        );
        assertEq(gateway.domainSeparator(), expected);
        assertTrue(expected != before);
        vm.chainId(chain);
        assertEq(gateway.domainSeparator(), before);
    }

    function test_getOrder_unknownIsEmpty() public view {
        PayLightGateway.Order memory o = gateway.getOrder(keccak256("nothing"));
        assertEq(o.payer, address(0));
        assertEq(uint8(o.status), uint8(PayLightGateway.Status.None));
        assertEq(o.amount, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════ fuzz

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_previewFee_isCeil(uint128 base, uint8 tier) public view {
        tier = uint8(bound(tier, 0, 2));
        uint256 bps = gateway.tierFeeBps(tier);
        assertEq(gateway.previewFee(base, tier), (uint256(base) * bps + 9_999) / 10_000);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_pay_anyValidAmount(uint128 base, uint32 units) public {
        base = uint128(bound(base, 1, MAX_BASE_TIER0));
        units = uint32(bound(units, 0, 50));
        PayLightGateway.Quote memory q = _quote(alice, base, units);
        _pay(q);
        PayLightGateway.Order memory o = gateway.getOrder(q.orderId);
        assertEq(o.amount, uint256(base) + q.fee);
        assertEq(o.fee, (uint256(base) * 100 + 9_999) / 10_000);
        assertEq(usdt0.balanceOf(address(gateway)), gateway.totalPending());
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_claimRefund_timing(uint256 dt) public {
        dt = bound(dt, 0, 10 days);
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        _pay(q);
        uint64 refundableAt = gateway.getOrder(q.orderId).refundableAt;
        vm.warp(block.timestamp + dt);
        vm.prank(alice);
        if (dt <= REFUND_TIMEOUT) {
            vm.expectRevert(abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, refundableAt));
            gateway.claimRefund(q.orderId);
        } else {
            gateway.claimRefund(q.orderId);
            _assertStatus(q.orderId, PayLightGateway.Status.Refunded);
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_payWithAuthorization_anyRelayer(address sender) public {
        vm.assume(sender != address(0) && sender != alice);
        PayLightGateway.Quote memory q = _quote(alice, 1e6, 0);
        bytes memory sig = _sign(q);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        uint256 senderBal = usdt0.balanceOf(sender);
        vm.prank(sender);
        gateway.payWithAuthorization(q, sig, a);
        assertEq(gateway.getOrder(q.orderId).payer, alice);
        assertEq(usdt0.balanceOf(sender), senderBal);
    }
}
