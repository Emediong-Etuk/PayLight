// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {PayLightGateway} from "../src/PayLightGateway.sol";
import {FeeTierCircuit} from "../src/libraries/FeeTierCircuit.sol";

/// @notice End-to-end happy paths. Deeper suites live in the other test files.
contract SmokeTest is Fixture {
    function test_feeTierCircuit_truthTable() public view {
        for (uint8 x; x < 8; ++x) {
            bytes memory out = processor.eval(feeCircuitId, abi.encodePacked(x));
            assertEq(uint8(out[0]), FeeTierCircuit.expectedTier(x), "tier");
        }
    }

    function test_pay_settle_cashback() public {
        _topUp(1_000);
        PayLightGateway.Quote memory q = _quote(alice, 3_300_000, 5); // ~₦5,000 at an illustrative rate
        assertEq(q.tier, 0);
        assertEq(q.fee, 33_000); // 1.00%
        _pay(q);

        assertEq(usdt0.balanceOf(address(gateway)), 3_333_000);
        assertEq(gateway.totalPending(), 3_333_000);

        vm.prank(operator);
        gateway.markFulfilled(q.orderId, keccak256("vtpass-tx-1"));
        assertEq(usdt0.balanceOf(treasury), 3_333_000);
        assertEq(gateway.totalPending(), 0);
        assertEq(gateway.settledOrders(alice), 1);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = q.orderId;
        assertEq(router.distribute(ids), 1);
        assertEq(transistors.balanceOf(alice, 0), 5);
        assertEq(router.distributedUnits(), 5);
    }

    function test_payWithPermit() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 10);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        bytes memory sig = _sign(q);
        vm.prank(alice);
        gateway.payWithPermit(q, sig, p);
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Paid));
    }

    function test_payWithAuthorization_gasless() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 10);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        bytes memory sig = _sign(q);
        address relayer = makeAddr("relayer");
        vm.prank(relayer); // alice spends no gas
        gateway.payWithAuthorization(q, sig, a);
        assertEq(gateway.getOrder(q.orderId).payer, alice);
        assertEq(usdt0.balanceOf(address(gateway)), _total(q));
    }

    function test_tierUpgrades_withHoldingsAndRepeatOrders() public {
        _giveTransistors(bob, 50);
        assertEq(gateway.computeTier(bob), 1);
        _giveTransistors(bob, 450);
        assertEq(gateway.computeTier(bob), 2);

        // alice reaches tier 1 through 3 settled orders
        for (uint256 i; i < 3; ++i) {
            PayLightGateway.Quote memory q = _quote(alice, 1e6, 1);
            _pay(q);
            vm.prank(operator);
            gateway.markFulfilled(q.orderId, bytes32(i));
        }
        assertEq(gateway.computeTier(alice), 1);
        PayLightGateway.Quote memory q2 = _quote(alice, 10e6, 1);
        assertEq(q2.fee, 50_000); // 0.50%
    }

    function test_claimRefund_afterTimeout() public {
        PayLightGateway.Quote memory q = _quote(alice, 10e6, 1);
        _pay(q);
        uint256 before = usdt0.balanceOf(alice);
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        assertEq(usdt0.balanceOf(alice) - before, _total(q));
        assertEq(gateway.totalPending(), 0);
    }
}
