// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {PayLightGateway} from "../src/PayLightGateway.sol";
import {CashbackRouter} from "../src/CashbackRouter.sol";
import {MockTransistors} from "./mocks/MockTapeOut.sol";

/// @notice Transistors whose transfers can be switched to a silent no-op (simulates a broken TapeOut upgrade).
contract NoopTransferTransistors is MockTransistors {
    bool public noop;

    constructor() MockTransistors(1_000_000, 0.0001 ether, 0.00066 ether, address(0xC0FFEE)) {}

    function setNoop(bool v) external {
        noop = v;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data) public override {
        if (noop) return;
        super.safeTransferFrom(from, to, id, value, data);
    }
}

/// @notice Regression tests for the fixes applied after the Phase 1 security review (docs/SECURITY.md).
contract SecurityFixesTest is Fixture {
    // ── settlement window: the operator can't settle after the refund deadline (can't race a self-refund)

    function test_markFulfilled_closesAtRefundDeadline() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        _pay(q);
        uint64 deadline = gateway.getOrder(q.orderId).refundableAt;

        vm.warp(deadline); // still allowed exactly at the deadline
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, bytes32("ok"));

        PayLightGateway.Quote memory q2 = _quote(alice, 10e6, 0);
        _pay(q2);
        uint64 deadline2 = gateway.getOrder(q2.orderId).refundableAt;
        vm.warp(deadline2 + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PayLightGateway.SettlementWindowClosed.selector, deadline2));
        gateway.markFulfilled(q2.orderId, bytes32("late"));

        // the only way out is a refund to the payer (operator, or anyone via claimRefund)
        uint256 before = usdt0.balanceOf(alice);
        vm.prank(makeAddr("anyone"));
        gateway.claimRefund(q2.orderId);
        assertEq(usdt0.balanceOf(alice) - before, _total(q2));
    }

    // ── cashback must be backed by real base amount

    function test_cashbackFloor_blocksDustOrdersFromDrainingReserve() public {
        _topUp(1_000);
        // 50 units on a 1-unit (0.000001 USD₮0) order: rejected even with a valid signature
        PayLightGateway.Quote memory dust = _quote(alice, 1, 50);
        bytes memory sig = _sign(dust);
        vm.startPrank(alice);
        usdt0.approve(address(gateway), _total(dust));
        vm.expectRevert(PayLightGateway.CashbackNotBacked.selector);
        gateway.pay(dust, sig);
        vm.stopPrank();
    }

    function testFuzz_cashbackFloor(uint128 base, uint32 units) public {
        base = uint128(bound(base, 1, 29e6));
        units = uint32(bound(units, 1, 50));
        PayLightGateway.Quote memory q = _quote(alice, base, units);
        bytes memory sig = _sign(q);
        vm.startPrank(alice);
        usdt0.approve(address(gateway), _total(q));
        if (uint256(units) * gateway.MIN_BASE_PER_CASHBACK_UNIT() > base) {
            vm.expectRevert(PayLightGateway.CashbackNotBacked.selector);
        }
        gateway.pay(q, sig);
        vm.stopPrank();
    }

    // ── refunds release daily volume, bucketed by the day the order was paid

    function test_refundReleasesVolumeOfPaidDay() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 0);
        _pay(q);
        uint256 paidDay = block.timestamp / 1 days;
        assertEq(gateway.dailyVolume(paidDay), _total(q));

        vm.warp(block.timestamp + 1 days); // refund happens on a later day
        vm.prank(operator);
        gateway.refund(q.orderId);
        assertEq(gateway.dailyVolume(paidDay), 0, "released from the paid day");
        assertEq(gateway.dailyVolume(paidDay + 1), 0, "today untouched");
    }

    // ── router fails closed when a transfer reports success without moving tokens

    function test_router_distribute_failsClosedOnNoopTransfer() public {
        NoopTransferTransistors t = new NoopTransferTransistors();
        address fakeGateway = makeAddr("fakeGateway");
        CashbackRouter r = new CashbackRouter(fakeGateway, address(t), admin, keeper, 200_000);
        uint256 cost = r.topUpCost(100);
        vm.prank(keeper);
        r.topUp{value: cost}(100);

        bytes32 id = keccak256("o1");
        vm.prank(fakeGateway);
        r.credit(id, alice, 5);

        t.setNoop(true);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(CashbackRouter.TransferMismatch.selector);
        r.distribute(ids);

        // nothing was marked paid; once transfers work again the payout goes through
        (,, bool paid) = r.credits(id);
        assertFalse(paid);
        t.setNoop(false);
        assertEq(r.distribute(ids), 1);
        assertEq(t.balanceOf(alice, 0), 5);
    }

    // ── gas: a relayer forwarding a sane limit succeeds (precheck no longer demands ~554k)

    function test_payWithAuthorization_succeedsWith350kGas() public {
        _giveTransistors(alice, 50); // tier 1 -> real circuit evaluation
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 10);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        bytes memory sig = _sign(q);
        vm.prank(makeAddr("relayer"));
        gateway.payWithAuthorization{gas: 350_000}(q, sig, a);
        assertEq(gateway.getOrder(q.orderId).tier, 1);
    }
}
