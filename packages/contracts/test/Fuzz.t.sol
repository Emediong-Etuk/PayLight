// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Fixture} from "./utils/Fixture.sol";
import {PayLightGateway} from "../src/PayLightGateway.sol";
import {CashbackRouter} from "../src/CashbackRouter.sol";
import {FeeTierCircuit} from "../src/libraries/FeeTierCircuit.sol";
import {MockProcessor} from "./mocks/MockTapeOut.sol";

/// @notice Property-based tests for PayLightGateway + CashbackRouter: amounts, fees, tiers, caps, timestamps,
///         refund timing and cashback units (BUILD_BRIEF §5.4 "Fuzz: amounts, fees, timestamps").
contract PayLightFuzzTest is Fixture {
    uint32 internal constant MAX_CB = 50; // PayLightGateway.MAX_CASHBACK_UNITS
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address internal relayer = makeAddr("relayer");
    uint256 internal carolPk;
    address internal carol;

    function setUp() public override {
        super.setUp();
        (carol, carolPk) = makeAddrAndKey("carol");
        usdt0.mint(carol, 10_000e6);
    }

    // ─────────────────────────────────────────────────────────────── helpers

    function _ceilFee(uint256 base, uint256 bps) internal pure returns (uint256) {
        return (base * bps + 9_999) / 10_000;
    }

    /// @dev Largest baseAmount whose total (base + ceil fee) still fits under the current maxOrderAmount at `tier`
    ///      (0 if no base fits).
    function _maxBase(uint8 tier) internal view returns (uint128) {
        uint256 bps = gateway.tierFeeBps(tier);
        uint256 m = gateway.maxOrderAmount();
        uint256 x = (m * 10_000) / (10_000 + bps);
        while (x + 1 + _ceilFee(x + 1, bps) <= m) ++x;
        while (x > 0 && x + _ceilFee(x, bps) > m) --x;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    function _status(bytes32 id) internal view returns (PayLightGateway.Status) {
        return gateway.getOrder(id).status;
    }

    function _giveLatch(address to, uint256 amount) internal {
        vm.deal(to, to.balance + MINT_PRICE * amount + PROTOCOL_FEE);
        vm.prank(to);
        transistors.mint{value: MINT_PRICE * amount + PROTOCOL_FEE}(1, amount);
    }

    /// @dev Gives `payer` exactly `n` settled orders (each a tiny paid + fulfilled order, no cashback).
    function _settleOrders(address payer, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            PayLightGateway.Quote memory q = _quote(payer, 1e6, 0);
            _pay(q);
            vm.prank(operator);
            gateway.markFulfilled(q.orderId, bytes32(i + 1));
        }
        assertEq(gateway.settledOrders(payer), n, "settled orders");
    }

    function _inputBits(uint256 held, uint256 settled) internal view returns (uint8 input) {
        if (held >= gateway.tier1Holding()) input |= 1;
        if (held >= gateway.tier2Holding()) input |= 2;
        if (settled >= gateway.repeatOrders()) input |= 4;
    }

    /// @dev Pays `q` through one of the three paths (0 = approve + pay, 1 = permit, 2 = EIP-3009 via relayer).
    ///      All setup calls happen first, so an optional expectEmit applies to the payment call itself.
    function _payVia(uint8 path, PayLightGateway.Quote memory q, uint256 pk, bool checkEvent) internal {
        uint128 amount = _total(q);
        bytes memory sig = _sign(q);
        uint64 refundableAt = uint64(block.timestamp) + gateway.refundTimeout();
        PayLightGateway.PermitSig memory p;
        PayLightGateway.AuthorizationSig memory a;
        if (path == 0) {
            vm.prank(q.payer);
            usdt0.approve(address(gateway), amount);
        } else if (path == 1) {
            p = _permitSig(pk, q.payer, amount, block.timestamp + 1 hours);
        } else {
            a = _authSig(pk, q.payer, amount, q.orderId);
        }
        if (checkEvent) {
            vm.expectEmit(address(gateway));
            emit PayLightGateway.OrderPaid(
                q.orderId, q.payer, amount, q.fee, q.tier, q.cashbackUnits, refundableAt
            );
        }
        if (path == 0) {
            vm.prank(q.payer);
            gateway.pay(q, sig);
        } else if (path == 1) {
            vm.prank(q.payer);
            gateway.payWithPermit(q, sig, p);
        } else {
            vm.prank(relayer);
            gateway.payWithAuthorization(q, sig, a);
        }
    }

    /// @dev approve, then expect `revertData` from `pay`.
    function _payExpectRevert(PayLightGateway.Quote memory q, bytes memory revertData) internal {
        bytes memory sig = _sign(q);
        vm.prank(q.payer);
        usdt0.approve(address(gateway), _total(q));
        vm.expectRevert(revertData);
        vm.prank(q.payer);
        gateway.pay(q, sig);
    }

    // ─────────────────────────────────────────────────────────────── fee math

    /// @notice previewFee == ceil(base * bps / 1e4) for every tier and every uint128 base.
    function testFuzz_previewFee_isCeil(uint128 base, uint8 tier) public view {
        tier = uint8(bound(tier, 0, 2));
        uint256 bps = gateway.tierFeeBps(tier);
        uint128 fee = gateway.previewFee(base, tier);
        assertEq(fee, _ceilFee(base, bps), "ceil fee");
        // ceil: fee * 1e4 >= base * bps and (fee - 1) * 1e4 < base * bps
        assertGe(uint256(fee) * 10_000, uint256(base) * bps, "fee too low");
        if (fee > 0) assertLt((uint256(fee) - 1) * 10_000, uint256(base) * bps, "fee not minimal");
        assertLe(fee, base, "fee <= base (bps <= 2%)");
        assertEq(fee == 0, base == 0, "nonzero base -> nonzero fee (all bps > 0)");
    }

    /// @notice Admin can set any monotone tier table within MAX_FEE_BPS, and the ceil formula holds for it.
    function testFuzz_setTierFees_boundedAndCeil(uint16 b0, uint16 b1, uint16 b2, uint128 base) public {
        b0 = uint16(bound(b0, 0, gateway.MAX_FEE_BPS()));
        b1 = uint16(bound(b1, 0, b0));
        b2 = uint16(bound(b2, 0, b1));
        vm.expectEmit(address(gateway));
        emit PayLightGateway.TierFeesUpdated(b0, b1, b2);
        vm.prank(admin);
        gateway.setTierFees([b0, b1, b2]);
        uint16[3] memory bps = [b0, b1, b2];
        for (uint8 t; t < 3; ++t) {
            assertEq(gateway.tierFeeBps(t), bps[t]);
            assertEq(gateway.previewFee(base, t), _ceilFee(base, bps[t]), "ceil fee");
        }
    }

    /// @notice Any tier table that exceeds 2% or is not monotone (higher tier more expensive) is rejected.
    function testFuzz_setTierFees_outOfBounds_reverts(uint16 b0, uint16 b1, uint16 b2) public {
        vm.assume(b0 > 200 || b1 > b0 || b2 > b1);
        vm.expectRevert(PayLightGateway.OutOfBounds.selector);
        vm.prank(admin);
        gateway.setTierFees([b0, b1, b2]);
    }

    /// @notice Any fee other than the exact ceil fee is rejected with FeeMismatch(quoted, expected).
    function testFuzz_feeMismatch_reverts(uint128 base, uint128 badFee) public {
        base = uint128(bound(base, 1, _maxBase(0)));
        PayLightGateway.Quote memory q = _quote(alice, base, 0);
        uint128 expected = q.fee;
        vm.assume(badFee != expected);
        q.fee = badFee;
        bytes memory sig = _sign(q);
        vm.prank(alice);
        usdt0.approve(address(gateway), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PayLightGateway.FeeMismatch.selector, badFee, expected));
        vm.prank(alice);
        gateway.pay(q, sig);
    }

    // ─────────────────────────────────────────────────────────────── amounts, maxOrderAmount, conservation

    struct Snap {
        uint256 payer;
        uint256 gateway;
        uint256 treasury;
        uint256 supply;
    }

    function _snap(address payer) internal view returns (Snap memory s) {
        s.payer = usdt0.balanceOf(payer);
        s.gateway = usdt0.balanceOf(address(gateway));
        s.treasury = usdt0.balanceOf(treasury);
        s.supply = usdt0.totalSupply();
    }

    /// @notice For every payment path, fuzzed amount / cashback / timestamp: payer -amount, gateway +amount, then
    ///         either treasury +amount (settle) or payer +amount back (operator refund), also while paused.
    function testFuzz_pay_balancesConserve(
        uint8 path,
        uint128 base,
        uint32 units,
        uint256 warpBy,
        bool settle,
        bool pauseBeforeResolve
    ) public {
        path = uint8(bound(path, 0, 2));
        vm.warp(block.timestamp + bound(warpBy, 0, 10 * 365 days));
        base = uint128(bound(base, 1, _maxBase(0)));
        units = uint32(bound(units, 0, MAX_CB));
        _topUp(100);

        PayLightGateway.Quote memory q = _quote(alice, base, units);
        assertEq(q.tier, 0);
        assertEq(q.fee, _ceilFee(base, TIER0_BPS), "fee == ceil(base * bps / 1e4)");
        uint128 amount = base + q.fee;
        assertLe(amount, MAX_ORDER, "amount <= maxOrderAmount");

        Snap memory s0 = _snap(alice);
        _payVia(path, q, alicePk, true);

        assertEq(usdt0.balanceOf(alice), s0.payer - amount, "payer -amount");
        assertEq(usdt0.balanceOf(address(gateway)), s0.gateway + amount, "gateway +amount");
        assertEq(usdt0.balanceOf(treasury), s0.treasury, "treasury untouched");
        assertEq(gateway.totalPending(), amount, "pending");
        assertEq(gateway.dailyVolume(block.timestamp / 1 days), amount, "daily volume");
        PayLightGateway.Order memory o = gateway.getOrder(q.orderId);
        assertEq(o.payer, alice);
        assertEq(uint8(o.status), uint8(PayLightGateway.Status.Paid));
        assertEq(o.amount, amount);
        assertEq(o.fee, q.fee);
        assertEq(o.tier, 0);
        assertEq(o.cashbackUnits, units);
        assertEq(o.paidAt, block.timestamp);
        assertEq(o.refundableAt, block.timestamp + REFUND_TIMEOUT);
        assertFalse(o.cashbackCredited);

        if (pauseBeforeResolve) {
            vm.prank(operator);
            gateway.pause();
        }
        _resolveAndCheck(q, s0, settle);
    }

    function _resolveAndCheck(PayLightGateway.Quote memory q, Snap memory s0, bool settle) internal {
        uint128 amount = _total(q);
        uint32 units = q.cashbackUnits;
        if (settle) {
            bytes32 receipt = keccak256(abi.encode("receipt", q.orderId));
            vm.expectEmit(address(gateway));
            emit PayLightGateway.OrderFulfilled(q.orderId, receipt, units, units > 0);
            vm.prank(operator);
            gateway.markFulfilled(q.orderId, receipt);
            assertEq(usdt0.balanceOf(treasury), s0.treasury + amount, "treasury +amount");
            assertEq(usdt0.balanceOf(q.payer), s0.payer - amount, "payer stays -amount");
            assertEq(uint8(_status(q.orderId)), uint8(PayLightGateway.Status.Fulfilled));
            assertEq(gateway.settledOrders(q.payer), 1);
            assertEq(router.pendingUnits(), units);
        } else {
            vm.expectEmit(address(gateway));
            emit PayLightGateway.OrderRefunded(q.orderId, q.payer, amount, true);
            vm.prank(operator);
            gateway.refund(q.orderId);
            assertEq(usdt0.balanceOf(q.payer), s0.payer, "payer +amount back");
            assertEq(usdt0.balanceOf(treasury), s0.treasury, "treasury untouched");
            assertEq(uint8(_status(q.orderId)), uint8(PayLightGateway.Status.Refunded));
            assertEq(gateway.settledOrders(q.payer), 0);
            assertEq(router.pendingUnits(), 0);
        }
        assertEq(usdt0.balanceOf(address(gateway)), s0.gateway, "gateway back to start");
        assertEq(gateway.totalPending(), 0);
        assertEq(usdt0.totalSupply(), s0.supply, "no mint/burn");

        // terminal: neither settlement nor refund can run again
        vm.startPrank(operator);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.markFulfilled(q.orderId, bytes32(0));
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        gateway.refund(q.orderId);
        vm.stopPrank();
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1);
        vm.expectRevert(PayLightGateway.NotPaid.selector);
        vm.prank(q.payer);
        gateway.claimRefund(q.orderId);
    }

    /// @notice At each tier, the largest base that fits pays; one more unit reverts OrderTooLarge (fuzzed cap).
    function testFuzz_maxOrderAmount_boundary(uint128 cap, uint8 tierSel) public {
        tierSel = uint8(bound(tierSel, 0, 2));
        cap = uint128(bound(cap, 1, gateway.MAX_ORDER_HARD_CAP()));
        vm.startPrank(admin);
        gateway.setMaxOrderAmount(cap);
        gateway.setDailyVolumeCap(gateway.MAX_DAILY_HARD_CAP());
        vm.stopPrank();
        if (tierSel == 1) _giveTransistors(bob, TIER1_HOLDING);
        if (tierSel == 2) _giveTransistors(bob, TIER2_HOLDING);
        assertEq(gateway.computeTier(bob), tierSel);

        uint128 mb = _maxBase(tierSel);
        if (mb > 0) {
            PayLightGateway.Quote memory ok = _quote(bob, mb, 0);
            assertLe(_total(ok), cap);
            _pay(ok);
            assertEq(gateway.getOrder(ok.orderId).amount, _total(ok));
        }
        PayLightGateway.Quote memory tooBig = _quote(bob, mb + 1, 0);
        assertGt(_total(tooBig), cap);
        _payExpectRevert(tooBig, abi.encodeWithSelector(PayLightGateway.OrderTooLarge.selector));
    }

    /// @notice Any base whose total exceeds maxOrderAmount reverts OrderTooLarge, at every tier.
    function testFuzz_pay_overMaxOrder_reverts(uint128 base, uint8 tierSel) public {
        tierSel = uint8(bound(tierSel, 0, 2));
        if (tierSel == 1) _giveTransistors(alice, TIER1_HOLDING);
        if (tierSel == 2) _giveTransistors(alice, TIER2_HOLDING);
        base = uint128(bound(base, uint256(_maxBase(tierSel)) + 1, 1e30));
        PayLightGateway.Quote memory q = _quote(alice, base, 0);
        assertEq(q.tier, tierSel);
        assertGt(_total(q), MAX_ORDER);
        _payExpectRevert(q, abi.encodeWithSelector(PayLightGateway.OrderTooLarge.selector));
    }

    struct Acc {
        uint256 pending;
        uint256 treasury;
        uint256 units;
        uint256 sumParties;
        uint256 nPending;
        bytes32[] pendingIds;
    }

    /// @notice Random sequence of orders by two payers through random paths, each then settled, refunded, self-refunded
    ///         or left pending: USD₮0 is conserved and totalPending equals the sum of pending amounts.
    function testFuzz_manyOrders_conservation(uint256 seed, uint8 n) public {
        n = uint8(bound(n, 1, 10));
        _topUp(1_000);
        uint256 supply0 = usdt0.totalSupply();
        Acc memory acc;
        acc.sumParties = usdt0.balanceOf(alice) + usdt0.balanceOf(bob);
        acc.pendingIds = new bytes32[](n);

        for (uint256 i; i < n; ++i) {
            _randomOrderStep(uint256(keccak256(abi.encode(seed, i))), acc);
            assertEq(gateway.totalPending(), acc.pending, "totalPending == sum pending");
            assertEq(usdt0.balanceOf(address(gateway)), acc.pending, "gateway holds exactly pending");
            assertEq(usdt0.balanceOf(treasury), acc.treasury, "treasury == sum settled");
            assertEq(
                usdt0.balanceOf(alice) + usdt0.balanceOf(bob) + usdt0.balanceOf(address(gateway))
                    + usdt0.balanceOf(treasury),
                acc.sumParties,
                "conservation"
            );
            assertEq(router.pendingUnits(), acc.units, "router pending units");
        }
        uint256 sumPaid;
        for (uint256 j; j < acc.nPending; ++j) {
            sumPaid += gateway.getOrder(acc.pendingIds[j]).amount;
        }
        assertEq(sumPaid, gateway.totalPending());
        assertEq(usdt0.totalSupply(), supply0);
    }

    function _randomOrderStep(uint256 r, Acc memory acc) internal {
        (address payer, uint256 pk) = r & 1 == 1 ? (bob, bobPk) : (alice, alicePk);
        uint8 tier = gateway.computeTier(payer);
        uint128 base = uint128(bound(r >> 8, 1, _maxBase(tier)));
        PayLightGateway.Quote memory q = _quote(payer, base, uint32(bound(r >> 136, 0, MAX_CB)));
        assertEq(q.fee, _ceilFee(base, gateway.tierFeeBps(tier)));
        _payVia(uint8((r >> 2) % 3), q, pk, false);
        uint128 amount = _total(q);

        uint256 action = (r >> 4) % 4;
        if (action == 0) {
            vm.prank(operator);
            gateway.markFulfilled(q.orderId, bytes32(r));
            acc.treasury += amount;
            acc.units += q.cashbackUnits;
        } else if (action == 1) {
            vm.prank(operator);
            gateway.refund(q.orderId);
        } else if (action == 2) {
            vm.warp(gateway.getOrder(q.orderId).refundableAt + 1);
            vm.prank(payer);
            gateway.claimRefund(q.orderId);
        } else {
            acc.pending += amount;
            acc.pendingIds[acc.nPending++] = q.orderId;
        }
    }

    // ─────────────────────────────────────────────────────────────── daily cap

    /// @notice Daily cap at random day offsets (up to ~10 years ahead) and times of day, with a fuzzed cap: a second
    ///         order that would push the day over the cap reverts; the same order succeeds at 00:00:00 the next day.
    function testFuzz_dailyCap_acrossDayOffsets(
        uint256 dayOffset,
        uint256 secondOfDay,
        uint128 cap,
        uint128 base1,
        uint128 base2
    ) public {
        uint256 day = block.timestamp / 1 days + bound(dayOffset, 0, 3650);
        vm.warp(day * 1 days + bound(secondOfDay, 0, 1 days - 1));
        uint128 capV = uint128(bound(cap, 1, 3 * MAX_ORDER));
        vm.prank(admin);
        gateway.setDailyVolumeCap(capV);
        uint128 mb = _maxBase(0);
        base1 = uint128(bound(base1, 1, mb));
        base2 = uint128(bound(base2, 1, mb));

        uint256 vol;
        PayLightGateway.Quote memory q1 = _quote(alice, base1, 0);
        if (_total(q1) > capV) {
            _payExpectRevert(q1, abi.encodeWithSelector(PayLightGateway.DailyCapExceeded.selector));
        } else {
            _pay(q1);
            vol = _total(q1);
        }
        assertEq(gateway.dailyVolume(day), vol, "day volume after 1");

        PayLightGateway.Quote memory q2 = _quote(bob, base2, 0);
        uint128 amt2 = _total(q2);
        if (vol + amt2 > capV) {
            _payExpectRevert(q2, abi.encodeWithSelector(PayLightGateway.DailyCapExceeded.selector));
        } else {
            _pay(q2);
            vol += amt2;
        }
        assertEq(gateway.dailyVolume(day), vol, "day volume after 2");
        assertLe(vol, capV, "never above cap");

        // rollover: first second of the next UTC day starts a fresh bucket
        vm.warp((day + 1) * 1 days);
        PayLightGateway.Quote memory q3 = _quote(bob, base2, 0);
        if (amt2 > capV) {
            _payExpectRevert(q3, abi.encodeWithSelector(PayLightGateway.DailyCapExceeded.selector));
            assertEq(gateway.dailyVolume(day + 1), 0);
        } else {
            _pay(q3);
            assertEq(gateway.dailyVolume(day + 1), amt2, "next day bucket");
        }
        assertEq(gateway.dailyVolume(day), vol, "previous day untouched");
    }

    /// @notice Fill the cap at 23:59:59 on a random day; one more unit is rejected that second and accepted at 00:00:00.
    function testFuzz_dailyCap_rolloverBoundary(uint256 dayOffset, uint128 base) public {
        uint256 day = block.timestamp / 1 days + bound(dayOffset, 1, 3650);
        vm.warp((day + 1) * 1 days - 1); // last second of `day`
        base = uint128(bound(base, 1, _maxBase(0)));
        PayLightGateway.Quote memory q1 = _quote(alice, base, 0);
        vm.prank(admin);
        gateway.setDailyVolumeCap(_total(q1)); // cap == exactly one order
        _pay(q1);
        assertEq(gateway.dailyVolume(day), gateway.dailyVolumeCap());

        PayLightGateway.Quote memory q2 = _quote(bob, 1, 0);
        _payExpectRevert(q2, abi.encodeWithSelector(PayLightGateway.DailyCapExceeded.selector));

        vm.warp(block.timestamp + 1); // 00:00:00 of day + 1
        assertEq(block.timestamp / 1 days, day + 1);
        PayLightGateway.Quote memory q3 = _quote(bob, 1, 0);
        _pay(q3);
        assertEq(gateway.dailyVolume(day + 1), _total(q3));
        assertEq(gateway.dailyVolume(day), _total(q1));
    }

    // ─────────────────────────────────────────────────────────────── tier circuit

    /// @notice For fuzzed holdings (NAND + LATCH, 0..1000) and settled orders (0..5), computeTier equals
    ///         FeeTierCircuit.expectedTier(input bits), the circuit's raw output and circuitInput(); a payment at that
    ///         tier charges exactly ceil(base * tierFeeBps[tier] / 1e4).
    function testFuzz_computeTier_matchesCircuit(uint256 holdings, uint256 latchPart, uint8 settled, uint128 base)
        public
    {
        holdings = bound(holdings, 0, 1_000);
        latchPart = bound(latchPart, 0, holdings);
        settled = uint8(bound(settled, 0, 5));

        _settleOrders(carol, settled);
        if (holdings - latchPart > 0) _giveTransistors(carol, holdings - latchPart);
        if (latchPart > 0) _giveLatch(carol, latchPart);

        uint8 input = _inputBits(holdings, settled);
        uint8 expected = FeeTierCircuit.expectedTier(input);
        assertEq(gateway.computeTier(carol), expected, "computeTier == expectedTier(input)");
        (uint8 gotInput, uint256 held) = gateway.circuitInput(carol);
        assertEq(gotInput, input, "circuitInput bits");
        assertEq(held, holdings, "held = NAND + LATCH");
        assertEq(uint8(processor.eval(feeCircuitId, abi.encodePacked(input))[0]), expected, "raw circuit output");

        base = uint128(bound(base, 1, _maxBase(expected)));
        PayLightGateway.Quote memory q = _quote(carol, base, 0);
        assertEq(q.tier, expected);
        assertEq(q.fee, _ceilFee(base, gateway.tierFeeBps(expected)));
        _payVia(0, q, carolPk, true);
        assertEq(gateway.getOrder(q.orderId).tier, expected);
    }

    /// @notice Same parity with fuzzed thresholds (t1 1..1000, t2 t1..1000, r 1..5).
    function testFuzz_computeTier_fuzzedThresholds(uint128 t1, uint128 t2, uint32 r, uint256 holdings, uint8 settled)
        public
    {
        t1 = uint128(bound(t1, 1, 1_000));
        t2 = uint128(bound(t2, t1, 1_000));
        r = uint32(bound(r, 1, 5));
        holdings = bound(holdings, 0, 1_000);
        settled = uint8(bound(settled, 0, 5));

        vm.expectEmit(address(gateway));
        emit PayLightGateway.TierThresholdsUpdated(t1, t2, r);
        vm.prank(admin);
        gateway.setTierThresholds(t1, t2, r);

        _settleOrders(carol, settled);
        if (holdings > 0) _giveTransistors(carol, holdings);

        uint8 input = _inputBits(holdings, settled);
        assertEq(gateway.computeTier(carol), FeeTierCircuit.expectedTier(input), "computeTier == expectedTier(input)");
        (uint8 gotInput,) = gateway.circuitInput(carol);
        assertEq(gotInput, input);
    }

    /// @notice A quote whose tier differs from the on-chain tier reverts TierChanged(quoted, actual).
    function testFuzz_tierChanged_reverts(uint256 holdings, uint8 quotedTier, uint128 base) public {
        holdings = bound(holdings, 0, 1_000);
        if (holdings > 0) _giveTransistors(carol, holdings);
        uint8 actual = gateway.computeTier(carol);
        quotedTier = uint8(bound(quotedTier, 0, 2));
        vm.assume(quotedTier != actual);
        base = uint128(bound(base, 1, _maxBase(quotedTier)));

        PayLightGateway.Quote memory q = _quote(carol, base, 0);
        q.tier = quotedTier;
        q.fee = gateway.previewFee(base, quotedTier);
        _payExpectRevert(q, abi.encodeWithSelector(PayLightGateway.TierChanged.selector, quotedTier, actual));
    }

    /// @notice Whatever a broken / upgraded TapeOut returns (revert, empty, malformed, tier 3, gas bomb, return bomb,
    ///         short return), the tier falls back to 0 (highest fee) and payments keep working.
    function testFuzz_tapeOutFailure_fallsBackToTier0(uint8 modeSel, uint256 holdings, uint128 base) public {
        MockProcessor.Mode mode = MockProcessor.Mode(uint8(bound(modeSel, 1, 7)));
        holdings = bound(holdings, 0, 1_000);
        if (holdings > 0) _giveTransistors(carol, holdings);
        processor.setMode(mode);

        assertEq(gateway.computeTier(carol), 0, "fallback tier 0");
        base = uint128(bound(base, 1, _maxBase(0)));
        PayLightGateway.Quote memory q = _quote(carol, base, 0);
        assertEq(q.tier, 0);
        assertEq(q.fee, _ceilFee(base, TIER0_BPS));
        _payVia(0, q, carolPk, true);
        assertEq(uint8(_status(q.orderId)), uint8(PayLightGateway.Status.Paid));
    }

    // ─────────────────────────────────────────────────────────────── cashback units

    /// @notice cashbackUnits 0..50 are accepted, credited on settlement (if > 0) and distributed when the reserve
    ///         covers them, deferred otherwise; > 50 reverts TooMuchCashback.
    function testFuzz_cashbackUnits_creditAndDistribute(uint32 units, uint128 base, uint256 reserve) public {
        units = uint32(bound(units, 0, 80));
        base = uint128(bound(base, 1, _maxBase(0)));
        reserve = bound(reserve, 0, 100);

        if (units > MAX_CB) {
            PayLightGateway.Quote memory bad = _quote(alice, base, units);
            _payExpectRevert(bad, abi.encodeWithSelector(PayLightGateway.TooMuchCashback.selector));
            return;
        }
        if (reserve > 0) _topUp(reserve);
        PayLightGateway.Quote memory q = _quote(alice, base, units);
        _pay(q);

        bool credit = units > 0;
        bytes32 receipt = keccak256("rx");
        if (credit) {
            vm.expectEmit(address(router));
            emit CashbackRouter.CashbackCredited(q.orderId, alice, units);
        }
        vm.expectEmit(address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, receipt, units, credit);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, receipt);

        assertEq(gateway.getOrder(q.orderId).cashbackCredited, credit);
        (address cPayer, uint32 cUnits, bool cPaid) = router.credits(q.orderId);
        assertEq(cPayer, credit ? alice : address(0));
        assertEq(cUnits, units);
        assertFalse(cPaid);
        assertEq(router.pendingUnits(), units);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = q.orderId;
        uint256 paid;
        if (!credit) {
            paid = router.distribute(ids);
            assertEq(paid, 0);
            vm.expectRevert(PayLightGateway.NotCreditable.selector);
            vm.prank(operator);
            gateway.retryCashbackCredit(q.orderId);
        } else if (units <= reserve) {
            vm.expectEmit(address(router));
            emit CashbackRouter.CashbackPaid(q.orderId, alice, units);
            paid = router.distribute(ids);
            assertEq(paid, 1);
            assertEq(transistors.balanceOf(alice, 0), units);
            assertEq(router.distributedUnits(), units);
            assertEq(router.pendingUnits(), 0);
            // paying again is a no-op
            assertEq(router.distribute(ids), 0);
            assertEq(transistors.balanceOf(alice, 0), units);
        } else {
            vm.expectEmit(address(router));
            emit CashbackRouter.CashbackDeferred(q.orderId, alice, units, true);
            paid = router.distribute(ids);
            assertEq(paid, 0);
            assertEq(transistors.balanceOf(alice, 0), 0);
            assertEq(router.pendingUnits(), units);
            assertEq(router.distributedUnits(), 0);
        }
        assertEq(
            transistors.balanceOf(address(router), 0),
            router.reserveMinted() - router.distributedUnits(),
            "reserve accounting"
        );
        assertEq(router.reserveMinted(), reserve);
    }

    // ─────────────────────────────────────────────────────────────── timestamps & refunds

    /// @notice A quote is usable up to and including its expiry second, never after (fuzzed warp up to 2 years).
    function testFuzz_quoteExpiry(uint256 startOffset, uint256 dt, uint128 base) public {
        vm.warp(block.timestamp + bound(startOffset, 0, 5 * 365 days));
        base = uint128(bound(base, 1, _maxBase(0)));
        PayLightGateway.Quote memory q = _quote(alice, base, 0);
        bytes memory sig = _sign(q);
        dt = bound(dt, 0, 2 * 365 days);
        vm.warp(block.timestamp + dt);
        vm.prank(alice);
        usdt0.approve(address(gateway), _total(q));
        if (dt > QUOTE_TTL) vm.expectRevert(PayLightGateway.QuoteExpired.selector);
        vm.prank(alice);
        gateway.pay(q, sig);
        if (dt <= QUOTE_TTL) assertEq(uint8(_status(q.orderId)), uint8(PayLightGateway.Status.Paid));
    }

    /// @notice Self-refund timing at random payment times and timeouts: strictly after refundableAt only, payer only;
    ///         the deadline is snapshotted at payment and unaffected by later setRefundTimeout calls.
    function testFuzz_claimRefund_timing(uint256 payAt, uint64 timeout, uint64 laterTimeout, uint256 dt, uint8 path)
        public
    {
        vm.warp(block.timestamp + bound(payAt, 0, 10 * 365 days));
        timeout = uint64(bound(timeout, gateway.MIN_REFUND_TIMEOUT(), gateway.MAX_REFUND_TIMEOUT()));
        laterTimeout = uint64(bound(laterTimeout, gateway.MIN_REFUND_TIMEOUT(), gateway.MAX_REFUND_TIMEOUT()));
        vm.prank(admin);
        gateway.setRefundTimeout(timeout);

        PayLightGateway.Quote memory q = _quote(alice, 10e6, 3);
        _payVia(uint8(bound(path, 0, 2)), q, alicePk, true);
        uint64 paidAt = uint64(block.timestamp);
        uint64 refundableAt = paidAt + timeout;
        assertEq(gateway.getOrder(q.orderId).refundableAt, refundableAt);

        vm.prank(admin);
        gateway.setRefundTimeout(laterTimeout); // must not move the existing order's deadline
        assertEq(gateway.getOrder(q.orderId).refundableAt, refundableAt, "snapshot");

        dt = bound(dt, 0, 2 * uint256(timeout) + 1 days);
        vm.warp(paidAt + dt);

        // a non-payer can never self-refund, early or late
        vm.expectRevert(PayLightGateway.NotPayer.selector);
        vm.prank(bob);
        gateway.claimRefund(q.orderId);

        uint256 a0 = usdt0.balanceOf(alice);
        if (dt <= timeout) {
            vm.expectRevert(abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, refundableAt));
            vm.prank(alice);
            gateway.claimRefund(q.orderId);
            assertEq(uint8(_status(q.orderId)), uint8(PayLightGateway.Status.Paid));
            assertEq(gateway.totalPending(), _total(q));
        } else {
            vm.expectEmit(address(gateway));
            emit PayLightGateway.OrderRefunded(q.orderId, alice, _total(q), false);
            vm.prank(alice);
            gateway.claimRefund(q.orderId);
            assertEq(usdt0.balanceOf(alice), a0 + _total(q), "payer +amount back");
            assertEq(uint8(_status(q.orderId)), uint8(PayLightGateway.Status.Refunded));
            assertEq(gateway.totalPending(), 0);
            vm.expectRevert(PayLightGateway.NotPaid.selector);
            vm.prank(alice);
            gateway.claimRefund(q.orderId);
        }
    }

    /// @notice Exact boundary: at refundableAt + delta for delta in [-3, 3], the claim succeeds iff delta > 0.
    function testFuzz_claimRefund_aroundDeadline(uint256 payAt, uint64 timeout, int256 delta) public {
        vm.warp(block.timestamp + bound(payAt, 0, 10 * 365 days));
        timeout = uint64(bound(timeout, gateway.MIN_REFUND_TIMEOUT(), gateway.MAX_REFUND_TIMEOUT()));
        vm.prank(admin);
        gateway.setRefundTimeout(timeout);
        PayLightGateway.Quote memory q = _quote(bob, 5e6, 0);
        _pay(q);
        uint64 refundableAt = gateway.getOrder(q.orderId).refundableAt;
        assertEq(refundableAt, block.timestamp + timeout);

        delta = bound(delta, -3, 3);
        vm.warp(uint256(int256(uint256(refundableAt)) + delta));
        if (delta <= 0) {
            vm.expectRevert(abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, refundableAt));
        }
        vm.prank(bob);
        gateway.claimRefund(q.orderId);
        assertEq(
            uint8(_status(q.orderId)), uint8(delta > 0 ? PayLightGateway.Status.Refunded : PayLightGateway.Status.Paid)
        );
    }

    /// @notice Self-refund works while paused and with TapeOut in any failure mode (refunds never touch TapeOut).
    function testFuzz_claimRefund_pausedAndTapeOutBroken(uint8 modeSel, uint256 extra) public {
        PayLightGateway.Quote memory q = _quote(alice, 7e6, 5);
        _pay(q);
        vm.prank(operator);
        gateway.pause();
        processor.setMode(MockProcessor.Mode(uint8(bound(modeSel, 0, 7))));
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1 + bound(extra, 0, 5 * 365 days));
        uint256 a0 = usdt0.balanceOf(alice);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        assertEq(usdt0.balanceOf(alice), a0 + _total(q));
        assertTrue(gateway.paused());
    }

    /// @notice New payments of any shape revert EnforcedPause while paused, on all three paths.
    function testFuzz_paused_blocksAllPayPaths(uint8 path, uint128 base) public {
        base = uint128(bound(base, 1, _maxBase(0)));
        PayLightGateway.Quote memory q = _quote(alice, base, 1);
        bytes memory sig = _sign(q);
        PayLightGateway.PermitSig memory p = _permitSig(alicePk, alice, _total(q), block.timestamp + 1 hours);
        PayLightGateway.AuthorizationSig memory a = _authSig(alicePk, alice, _total(q), q.orderId);
        vm.prank(alice);
        usdt0.approve(address(gateway), _total(q));
        vm.prank(admin);
        gateway.pause();
        path = uint8(bound(path, 0, 2));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        if (path == 0) {
            vm.prank(alice);
            gateway.pay(q, sig);
        } else if (path == 1) {
            vm.prank(alice);
            gateway.payWithPermit(q, sig, p);
        } else {
            vm.prank(relayer);
            gateway.payWithAuthorization(q, sig, a);
        }
    }

    // ─────────────────────────────────────────────────────────────── signatures

    /// @notice A quote signed by any key other than quoteSigner reverts InvalidSignature.
    function testFuzz_wrongSigner_reverts(uint256 pk, uint128 base) public {
        pk = bound(pk, 1, SECP256K1_N - 1);
        vm.assume(pk != signerPk);
        base = uint128(bound(base, 1, _maxBase(0)));
        PayLightGateway.Quote memory q = _quote(alice, base, 0);
        bytes memory sig = _signWith(pk, q);
        vm.prank(alice);
        usdt0.approve(address(gateway), _total(q));
        vm.expectRevert(PayLightGateway.InvalidSignature.selector);
        vm.prank(alice);
        gateway.pay(q, sig);
    }

    /// @notice Changing any amount after signing (with a self-consistent fee) breaks the signature.
    function testFuzz_tamperedAmount_reverts(uint128 base, uint128 newBase, uint32 units, uint32 newUnits) public {
        uint128 mb = _maxBase(0);
        base = uint128(bound(base, 1, mb));
        newBase = uint128(bound(newBase, 1, mb));
        units = uint32(bound(units, 0, MAX_CB));
        newUnits = uint32(bound(newUnits, 0, MAX_CB));
        vm.assume(newBase != base || newUnits != units);
        PayLightGateway.Quote memory q = _quote(alice, base, units);
        bytes memory sig = _sign(q);
        q.baseAmount = newBase;
        q.fee = gateway.previewFee(newBase, 0);
        q.cashbackUnits = newUnits;
        vm.prank(alice);
        usdt0.approve(address(gateway), _total(q));
        vm.expectRevert(PayLightGateway.InvalidSignature.selector);
        vm.prank(alice);
        gateway.pay(q, sig);
    }

    // ─────────────────────────────────────────────────────────────── rescue

    /// @notice rescueToken can take only the USD₮0 excess above totalPending.
    function testFuzz_rescueToken_onlyExcess(uint128 base, uint256 excess, uint256 ask) public {
        base = uint128(bound(base, 1, _maxBase(0)));
        excess = bound(excess, 0, 1_000e6);
        PayLightGateway.Quote memory q = _quote(alice, base, 0);
        _pay(q);
        if (excess > 0) {
            vm.prank(bob);
            usdt0.transfer(address(gateway), excess); // mistaken direct transfer
        }
        ask = bound(ask, 0, 2_000e6);
        address to = makeAddr("rescueTo");
        if (ask > excess) {
            vm.expectRevert(PayLightGateway.RescueExceedsExcess.selector);
            vm.prank(admin);
            gateway.rescueToken(address(usdt0), to, ask);
        } else {
            vm.expectEmit(address(gateway));
            emit PayLightGateway.TokenRescued(address(usdt0), to, ask);
            vm.prank(admin);
            gateway.rescueToken(address(usdt0), to, ask);
            assertEq(usdt0.balanceOf(to), ask);
        }
        assertGe(usdt0.balanceOf(address(gateway)), gateway.totalPending(), "solvency");
        // the escrowed order is still fully refundable
        vm.prank(operator);
        gateway.refund(q.orderId);
        assertEq(gateway.totalPending(), 0);
    }
}
