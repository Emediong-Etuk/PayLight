// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Fixture} from "../utils/Fixture.sol";
import {PayLightGateway} from "../../src/PayLightGateway.sol";
import {CashbackRouter} from "../../src/CashbackRouter.sol";
import {MockUSDT0} from "../mocks/MockUSDT0.sol";
import {MockTransistors, MockProcessor} from "../mocks/MockTapeOut.sol";

/// @notice Stateful handler for the PayLight invariant suite. Several actors pay through all three paths; the operator
///         settles and refunds; payers self-refund after warping; admin pauses / unpauses / swaps the cashback router;
///         the keeper tops up the reserve; anyone distributes; TapeOut misbehaves; time moves forward.
///         Every action states its expected outcome up front (vm.expectRevert with the exact error, or vm.expectEmit),
///         and the suite runs with fail_on_revert = true, so any unexpected revert or wrong error fails the campaign.
///         Ghost state mirrors every order's lifecycle and the router's credit book.
contract PayLightHandler is Test {
    struct Deps {
        PayLightGateway gateway;
        CashbackRouter router;
        MockUSDT0 usdt0;
        MockTransistors transistors;
        MockProcessor processor;
        address admin;
        address operator;
        address keeper;
        address treasury;
        uint256 signerPk;
    }

    uint256 internal constant MAX_UNITS = 50;
    uint64 internal constant QUOTE_TTL = 120;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    PayLightGateway public immutable gateway;
    CashbackRouter public immutable router;
    MockUSDT0 public immutable usdt0;
    MockTransistors public immutable transistors;
    MockProcessor public immutable processor;
    address public immutable admin;
    address public immutable operator;
    address public immutable keeper;
    address public immutable treasury;
    uint256 internal immutable signerPk;
    address public immutable relayer;

    address[] public actors;
    mapping(address => uint256) internal _pkOf;
    mapping(address => uint256) internal _actorIdx; // index + 1

    uint256 public currentTime;
    uint256 internal _nonce;

    // ── ghost: orders
    bytes32[] internal _orders;
    bytes32[] internal _pending;
    mapping(bytes32 => uint256) internal _pendingIdx; // index + 1
    mapping(bytes32 => PayLightGateway.Status) public ghostStatus;
    mapping(bytes32 => address) public ghostPayer;
    mapping(bytes32 => uint128) public ghostAmount;
    mapping(bytes32 => uint32) public ghostUnits;
    mapping(bytes32 => uint64) public ghostRefundableAt;
    mapping(bytes32 => uint256) public ghostPaidDay;
    uint256 public ghostTotalPending;
    uint256 public ghostSettledVolume; // all USD₮0 ever sent to the treasury
    uint256 public ghostRefundedVolume;
    uint256[] internal _days;
    mapping(uint256 => uint256) public ghostDailyVolume;

    // ── ghost: cashback
    bytes32[] internal _credited;
    mapping(bytes32 => bool) public ghostCredited;
    mapping(bytes32 => bool) public ghostCreditPaid;
    uint256 public ghostPendingUnits; // credited but not yet paid
    uint256 public ghostDistributed;
    uint256 public ghostReserveMinted;
    bool public routerEnabled = true;

    // ── call summary
    uint256 public nPaid;
    uint256 public nPayRejectedPaused;
    uint256 public nPayRejectedCap;
    uint256 public nFulfilled;
    uint256 public nCredited;
    uint256 public nRefunded;
    uint256 public nClaimed;
    uint256 public nClaimTooEarly;
    uint256 public nClaimNotPayer;
    uint256 public nSettleAfterDeadline;
    uint256 public nTerminalTouches;
    uint256 public nPauses;
    uint256 public nUnpauses;
    uint256 public nTopUps;
    uint256 public nCashbackPaid;
    uint256 public nRetries;
    uint256 public nUnauthorized;

    constructor(Deps memory d, address[] memory actors_, uint256[] memory pks) {
        gateway = d.gateway;
        router = d.router;
        usdt0 = d.usdt0;
        transistors = d.transistors;
        processor = d.processor;
        admin = d.admin;
        operator = d.operator;
        keeper = d.keeper;
        treasury = d.treasury;
        signerPk = d.signerPk;
        relayer = makeAddr("inv-relayer");
        for (uint256 i; i < actors_.length; ++i) {
            actors.push(actors_[i]);
            _pkOf[actors_[i]] = pks[i];
            _actorIdx[actors_[i]] = i + 1;
        }
        currentTime = block.timestamp;
        ghostReserveMinted = d.router.reserveMinted();
        ghostDistributed = d.router.distributedUnits();
        ghostPendingUnits = d.router.pendingUnits();
    }

    modifier useTime() {
        vm.warp(currentTime);
        _;
    }

    // ═════════════════════════════════════════════════════════════ actions: pay

    function pay(uint256 actorSeed, uint256 baseSeed, uint256 unitsSeed) external useTime {
        _payFlow(0, actorSeed, baseSeed, unitsSeed);
    }

    function payWithPermit(uint256 actorSeed, uint256 baseSeed, uint256 unitsSeed) external useTime {
        _payFlow(1, actorSeed, baseSeed, unitsSeed);
    }

    function payWithAuthorization(uint256 actorSeed, uint256 baseSeed, uint256 unitsSeed) external useTime {
        _payFlow(2, actorSeed, baseSeed, unitsSeed);
    }

    function _payFlow(uint8 path, uint256 actorSeed, uint256 baseSeed, uint256 unitsSeed) internal {
        address payer = actors[actorSeed % actors.length];
        uint8 tier = gateway.computeTier(payer);
        uint128 base = uint128(_bound(baseSeed, 1, _maxBase(tier)));
        PayLightGateway.Quote memory q = PayLightGateway.Quote({
            orderId: keccak256(abi.encode("inv-order", ++_nonce)),
            payer: payer,
            baseAmount: base,
            fee: gateway.previewFee(base, tier),
            tier: tier,
            cashbackUnits: uint32(_bound(unitsSeed, 0, base / 250_000 < MAX_UNITS ? base / 250_000 : MAX_UNITS)),
            expiry: uint64(block.timestamp) + QUOTE_TTL
        });
        uint128 amount = q.baseAmount + q.fee;
        // fee is exactly the published ceil fee
        assertEq(uint256(q.fee), (uint256(base) * gateway.tierFeeBps(tier) + 9_999) / 10_000, "ceil fee");

        bytes memory err;
        if (gateway.paused()) {
            err = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
            ++nPayRejectedPaused;
        } else if (gateway.dailyVolume(block.timestamp / 1 days) + amount > gateway.dailyVolumeCap()) {
            err = abi.encodeWithSelector(PayLightGateway.DailyCapExceeded.selector);
            ++nPayRejectedCap;
        }
        uint256 payerBefore = usdt0.balanceOf(payer);
        _submit(path, q, err);
        if (err.length != 0) {
            assertEq(usdt0.balanceOf(payer), payerBefore, "rejected payment moved funds");
            return;
        }
        assertEq(usdt0.balanceOf(payer), payerBefore - amount, "payer -amount");
        _recordPaid(q, amount);
    }

    function _submit(uint8 path, PayLightGateway.Quote memory q, bytes memory err) internal {
        uint128 amount = q.baseAmount + q.fee;
        bytes memory sig = _signQuote(q);
        PayLightGateway.PermitSig memory p;
        PayLightGateway.AuthorizationSig memory a;
        if (path == 0) {
            vm.prank(q.payer);
            usdt0.approve(address(gateway), amount);
        } else if (path == 1) {
            p = _permit(q.payer, amount);
        } else {
            a = _auth(q.payer, amount, q.orderId);
        }
        uint64 refundableAt = uint64(block.timestamp) + gateway.refundTimeout();
        if (err.length != 0) {
            vm.expectRevert(err);
        } else {
            vm.expectEmit(address(gateway));
            emit PayLightGateway.OrderPaid(q.orderId, q.payer, amount, q.fee, q.tier, q.cashbackUnits, refundableAt);
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

    function _recordPaid(PayLightGateway.Quote memory q, uint128 amount) internal {
        bytes32 id = q.orderId;
        uint64 refundableAt = uint64(block.timestamp) + gateway.refundTimeout();
        _orders.push(id);
        _pending.push(id);
        _pendingIdx[id] = _pending.length;
        ghostStatus[id] = PayLightGateway.Status.Paid;
        ghostPayer[id] = q.payer;
        ghostAmount[id] = amount;
        ghostUnits[id] = q.cashbackUnits;
        ghostRefundableAt[id] = refundableAt;
        ghostTotalPending += amount;
        uint256 day = block.timestamp / 1 days;
        if (ghostDailyVolume[day] == 0) _days.push(day);
        ghostDailyVolume[day] += amount;
        ghostPaidDay[id] = day;
        ++nPaid;

        PayLightGateway.Order memory o = gateway.getOrder(id);
        assertEq(o.payer, q.payer, "order payer");
        assertEq(o.amount, amount, "order amount");
        assertEq(o.fee, q.fee, "order fee");
        assertEq(o.tier, q.tier, "order tier");
        assertEq(o.cashbackUnits, q.cashbackUnits, "order units");
        assertEq(o.refundableAt, refundableAt, "order refundableAt");
        assertEq(o.paidAt, block.timestamp, "order paidAt");
    }

    // ═════════════════════════════════════════════════════════════ actions: settle / refund

    function markFulfilled(uint256 orderSeed, bytes32 receipt) external useTime {
        (bool any, bytes32 id, bool pending) = _pickOrder(orderSeed);
        if (!any) return;
        if (!pending) {
            ++nTerminalTouches;
            vm.expectRevert(PayLightGateway.NotPaid.selector);
            vm.prank(operator);
            gateway.markFulfilled(id, receipt);
            return;
        }
        if (block.timestamp > ghostRefundableAt[id]) {
            // past the refund deadline the order can only be refunded, never settled
            vm.expectRevert(
                abi.encodeWithSelector(PayLightGateway.SettlementWindowClosed.selector, ghostRefundableAt[id])
            );
            vm.prank(operator);
            gateway.markFulfilled(id, receipt);
            ++nSettleAfterDeadline;
            return;
        }
        address payer = ghostPayer[id];
        uint128 amount = ghostAmount[id];
        uint32 units = ghostUnits[id];
        bool expectCredit = routerEnabled && units > 0;
        uint256 treasuryBefore = usdt0.balanceOf(treasury);
        uint32 settledBefore = gateway.settledOrders(payer);

        vm.expectEmit(address(gateway));
        emit PayLightGateway.OrderFulfilled(id, receipt, units, expectCredit);
        vm.prank(operator);
        gateway.markFulfilled(id, receipt);

        assertEq(usdt0.balanceOf(treasury), treasuryBefore + amount, "treasury +amount");
        assertEq(gateway.settledOrders(payer), settledBefore + 1, "settled +1");
        assertEq(gateway.getOrder(id).cashbackCredited, expectCredit, "credited flag");
        _close(id, PayLightGateway.Status.Fulfilled);
        ghostSettledVolume += amount;
        ++nFulfilled;
        if (expectCredit) _recordCredit(id);
    }

    function refund(uint256 orderSeed) external useTime {
        (bool any, bytes32 id, bool pending) = _pickOrder(orderSeed);
        if (!any) return;
        if (!pending) {
            ++nTerminalTouches;
            vm.expectRevert(PayLightGateway.NotPaid.selector);
            vm.prank(operator);
            gateway.refund(id);
            return;
        }
        _expectRefund(id, true);
        vm.prank(operator);
        gateway.refund(id);
        _afterRefund(id);
        ++nRefunded;
    }

    /// @param modeSeed 0 mod 4: a non-payer tries; 1 mod 4: try now (early -> RefundTooEarly); else warp past deadline.
    function claimRefund(uint256 orderSeed, uint256 modeSeed) external useTime {
        (bool any, bytes32 id, bool pending) = _pickOrder(orderSeed);
        if (!any) return;
        address payer = ghostPayer[id];
        if (!pending) {
            ++nTerminalTouches;
            vm.warp(block.timestamp + 73 hours); // even far past any deadline, a closed order stays closed
            vm.expectRevert(PayLightGateway.NotPaid.selector);
            vm.prank(payer);
            gateway.claimRefund(id);
            vm.warp(currentTime);
            return;
        }
        uint256 mode = modeSeed % 4;
        address caller = payer;
        if (mode == 0) {
            ++nClaimNotPayer; // a third party triggers; funds still go to the payer
            caller = _otherActor(payer, modeSeed >> 8);
        }
        uint64 refundableAt = ghostRefundableAt[id]; // snapshot taken at payment time
        if (block.timestamp <= refundableAt) {
            if (mode == 1) {
                ++nClaimTooEarly;
                vm.expectRevert(abi.encodeWithSelector(PayLightGateway.RefundTooEarly.selector, refundableAt));
                vm.prank(payer);
                gateway.claimRefund(id);
                return;
            }
            _setTime(uint256(refundableAt) + 1 + ((modeSeed >> 16) % 1 hours));
        }
        _expectRefund(id, false);
        vm.prank(caller);
        gateway.claimRefund(id);
        _afterRefund(id);
        ++nClaimed;
    }

    function _expectRefund(bytes32 id, bool byOperator) internal {
        vm.expectEmit(address(gateway));
        emit PayLightGateway.OrderRefunded(id, ghostPayer[id], ghostAmount[id], byOperator);
    }

    function _afterRefund(bytes32 id) internal {
        ghostDailyVolume[ghostPaidDay[id]] -= ghostAmount[id]; // refunds release their day's volume
        _close(id, PayLightGateway.Status.Refunded);
        ghostRefundedVolume += ghostAmount[id];
    }

    function retryCashback(uint256 orderSeed) external useTime {
        uint256 len = _orders.length;
        if (len == 0) return;
        uint256 start = orderSeed % len;
        bytes32 id;
        bool found;
        for (uint256 k; k < len; ++k) {
            bytes32 c = _orders[(start + k) % len];
            if (ghostStatus[c] == PayLightGateway.Status.Fulfilled && !ghostCredited[c] && ghostUnits[c] > 0) {
                (id, found) = (c, true);
                break;
            }
        }
        if (!found) {
            vm.expectRevert(PayLightGateway.NotCreditable.selector);
            vm.prank(operator);
            gateway.retryCashbackCredit(_orders[start]);
            return;
        }
        bool expectCredit = routerEnabled;
        vm.expectEmit(address(gateway));
        emit PayLightGateway.CashbackCreditRetried(id, expectCredit);
        vm.prank(operator);
        gateway.retryCashbackCredit(id);
        ++nRetries;
        if (expectCredit) _recordCredit(id);
    }

    // ═════════════════════════════════════════════════════════════ actions: admin / keeper / anyone

    function togglePause(uint256 seed) external useTime {
        if (gateway.paused()) {
            if (seed % 4 == 0) {
                // the operator may pause but never unpause
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE
                    )
                );
                vm.prank(operator);
                gateway.unpause();
                return;
            }
            vm.prank(admin);
            gateway.unpause();
            ++nUnpauses;
        } else if (seed % 4 == 1) {
            // pause only on 1 in 4 toggles so most of each run is spent unpaused (payments are the interesting part)
            vm.prank((seed >> 8) % 2 == 0 ? admin : operator);
            gateway.pause();
            ++nPauses;
        }
    }

    function setCashbackRouterEnabled(bool on) external useTime {
        address target = on ? address(router) : address(0);
        vm.expectEmit(address(gateway));
        emit PayLightGateway.CashbackRouterUpdated(target);
        vm.prank(admin);
        gateway.setCashbackRouter(target);
        routerEnabled = on;
    }

    /// @notice Admin changes the refund timeout; existing orders keep their snapshotted deadline (checked in claims).
    function setRefundTimeout(uint256 seed) external useTime {
        uint64 t = uint64(_bound(seed, gateway.MIN_REFUND_TIMEOUT(), gateway.MAX_REFUND_TIMEOUT()));
        vm.prank(admin);
        gateway.setRefundTimeout(t);
    }

    function topUp(uint256 unitsSeed) external useTime {
        uint256 remaining = router.maxReserveMint() - router.reserveMinted();
        if (remaining == 0) {
            uint256 c1 = router.topUpCost(1);
            vm.deal(keeper, c1);
            vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
            vm.prank(keeper);
            router.topUp{value: c1}(1);
            return;
        }
        uint256 units = _bound(unitsSeed, 0, remaining < 2_000 ? remaining : 2_000);
        uint256 cost = router.topUpCost(units);
        vm.deal(keeper, cost + 1);
        if (unitsSeed % 11 == 0) {
            // wrong payment is rejected with the exact expected cost
            vm.expectRevert(abi.encodeWithSelector(CashbackRouter.WrongPayment.selector, cost));
            vm.prank(keeper);
            router.topUp{value: cost + 1}(units);
            return;
        }
        vm.expectEmit(address(router));
        emit CashbackRouter.ReserveToppedUp(keeper, units, cost);
        vm.prank(keeper);
        router.topUp{value: cost}(units);
        ghostReserveMinted += units;
        ++nTopUps;
    }

    /// @notice Anyone distributes a random batch (credited, uncredited and unknown ids, possibly duplicated). The handler
    ///         predicts exactly which credits get paid and checks the return value and every actor's NAND balance.
    function distribute(uint256 seed, uint256 lenSeed, uint256 callerSeed) external useTime {
        bytes32[] memory ids = _buildBatch(seed, _bound(lenSeed, 1, 6));
        uint256 n = actors.length;
        uint256[] memory nandBefore = new uint256[](n);
        uint256[] memory delta = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nandBefore[i] = transistors.balanceOf(actors[i], 0);
        }

        uint256 available = transistors.balanceOf(address(router), 0);
        uint256 expectedPaid;
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            if (!ghostCredited[id] || ghostCreditPaid[id]) continue;
            uint32 u = ghostUnits[id];
            if (u > available) continue; // deferred: reserve can't cover it yet
            available -= u;
            ghostCreditPaid[id] = true;
            ghostPendingUnits -= u;
            ghostDistributed += u;
            delta[_actorIdx[ghostPayer[id]] - 1] += u;
            ++expectedPaid;
        }

        address caller = callerSeed % 3 == 0 ? actors[callerSeed % n] : address(uint160(uint256(keccak256(abi.encode(callerSeed)))));
        vm.prank(caller);
        uint256 paid = router.distribute(ids);
        assertEq(paid, expectedPaid, "distribute paid count");
        for (uint256 i; i < n; ++i) {
            assertEq(transistors.balanceOf(actors[i], 0), nandBefore[i] + delta[i], "payer NAND delta");
        }
        nCashbackPaid += paid;
    }

    function _buildBatch(uint256 seed, uint256 len) internal view returns (bytes32[] memory ids) {
        ids = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (_credited.length > 0 && r % 4 != 0) {
                ids[i] = _credited[(r >> 8) % _credited.length];
            } else if (_orders.length > 0 && r % 8 == 0) {
                ids[i] = _orders[(r >> 8) % _orders.length];
            } else {
                ids[i] = keccak256(abi.encode("unknown-order", r));
            }
        }
    }

    /// @notice Actors buy transistors (NAND or LATCH), which moves them across fee tiers.
    function buyTransistors(uint256 actorSeed, uint256 amountSeed, bool latch) external useTime {
        address a = actors[actorSeed % actors.length];
        uint256 amount = _bound(amountSeed, 1, 300);
        uint256 cost = transistors.mintPrice() * amount + transistors.protocolFee();
        vm.deal(a, cost);
        vm.prank(a);
        transistors.mint{value: cost}(latch ? 1 : 0, amount);
    }

    /// @notice TapeOut is upgradeable by a third party: make it misbehave (or recover). Payments must keep working.
    function setTapeOutMode(uint256 seed) external useTime {
        MockProcessor.Mode m = seed % 3 == 0 ? MockProcessor.Mode(1 + (seed >> 8) % 7) : MockProcessor.Mode.Normal;
        processor.setMode(m);
    }

    function warp(uint256 dt) external useTime {
        _setTime(currentTime + _bound(dt, 1, 3 days));
    }

    /// @notice Role checks: a random actor (no roles) can't settle, refund, retry, top up, pause, unpause or credit.
    function unauthorized(uint256 actorSeed, uint256 which, uint256 orderSeed) external useTime {
        address caller = actors[actorSeed % actors.length];
        bytes32 id = _orders.length > 0 ? _orders[orderSeed % _orders.length] : keccak256(abi.encode(orderSeed));
        uint256 w = which % 7;
        bytes32 opRole = gateway.OPERATOR_ROLE();
        if (w == 0) {
            vm.expectRevert(_unauth(caller, opRole));
            vm.prank(caller);
            gateway.markFulfilled(id, bytes32(0));
        } else if (w == 1) {
            vm.expectRevert(_unauth(caller, opRole));
            vm.prank(caller);
            gateway.refund(id);
        } else if (w == 2) {
            vm.expectRevert(_unauth(caller, opRole));
            vm.prank(caller);
            gateway.retryCashbackCredit(id);
        } else if (w == 3) {
            vm.expectRevert(_unauth(caller, router.KEEPER_ROLE()));
            vm.prank(caller);
            router.topUp(1);
        } else if (w == 4) {
            vm.expectRevert(_unauth(caller, opRole));
            vm.prank(caller);
            gateway.pause();
        } else if (w == 5) {
            vm.expectRevert(_unauth(caller, DEFAULT_ADMIN_ROLE));
            vm.prank(caller);
            gateway.unpause();
        } else {
            vm.expectRevert(CashbackRouter.NotGateway.selector);
            vm.prank(caller);
            router.credit(id, caller, 1);
        }
        ++nUnauthorized;
    }

    // ═════════════════════════════════════════════════════════════ internal

    function _unauth(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    function _setTime(uint256 t) internal {
        currentTime = t;
        vm.warp(t);
    }

    /// @dev Mostly picks a pending order; 1 in 5 picks any order (possibly terminal) to test terminal-state reverts.
    function _pickOrder(uint256 seed) internal view returns (bool any, bytes32 id, bool pending) {
        if (_orders.length == 0) return (false, bytes32(0), false);
        if (_pending.length > 0 && seed % 5 != 0) {
            return (true, _pending[(seed / 5) % _pending.length], true);
        }
        id = _orders[seed % _orders.length];
        return (true, id, ghostStatus[id] == PayLightGateway.Status.Paid);
    }

    function _close(bytes32 id, PayLightGateway.Status s) internal {
        assertEq(uint8(ghostStatus[id]), uint8(PayLightGateway.Status.Paid), "closing a non-pending order");
        ghostStatus[id] = s;
        ghostTotalPending -= ghostAmount[id];
        uint256 idx = _pendingIdx[id] - 1;
        bytes32 last = _pending[_pending.length - 1];
        _pending[idx] = last;
        _pendingIdx[last] = idx + 1;
        _pending.pop();
        delete _pendingIdx[id];
        assertEq(uint8(gateway.getOrder(id).status), uint8(s), "on-chain status after close");
    }

    function _recordCredit(bytes32 id) internal {
        ghostCredited[id] = true;
        _credited.push(id);
        ghostPendingUnits += ghostUnits[id];
        ++nCredited;
    }

    function _otherActor(address not, uint256 seed) internal view returns (address) {
        uint256 n = actors.length;
        uint256 i = _actorIdx[not] - 1;
        return actors[(i + 1 + seed % (n - 1)) % n];
    }

    function _maxBase(uint8 tier) internal view returns (uint128) {
        uint256 bps = gateway.tierFeeBps(tier);
        uint256 m = gateway.maxOrderAmount();
        uint256 x = (m * 10_000) / (10_000 + bps);
        while (x + 1 + (((x + 1) * bps + 9_999) / 10_000) <= m) ++x;
        while (x > 0 && x + ((x * bps + 9_999) / 10_000) > m) --x;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    function _signQuote(PayLightGateway.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, gateway.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _permit(address owner, uint256 value) internal view returns (PayLightGateway.PermitSig memory p) {
        p.deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(gateway),
                value,
                usdt0.nonces(owner),
                p.deadline
            )
        );
        (p.v, p.r, p.s) =
            vm.sign(_pkOf[owner], keccak256(abi.encodePacked("\x19\x01", usdt0.DOMAIN_SEPARATOR(), structHash)));
    }

    function _auth(address from, uint256 value, bytes32 orderId)
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
        (a.v, a.r, a.s) =
            vm.sign(_pkOf[from], keccak256(abi.encodePacked("\x19\x01", usdt0.DOMAIN_SEPARATOR(), structHash)));
    }

    // ═════════════════════════════════════════════════════════════ views for the invariant contract

    function ordersLength() external view returns (uint256) {
        return _orders.length;
    }

    function orderAt(uint256 i) external view returns (bytes32) {
        return _orders[i];
    }

    function pendingLength() external view returns (uint256) {
        return _pending.length;
    }

    function pendingAt(uint256 i) external view returns (bytes32) {
        return _pending[i];
    }

    function creditedLength() external view returns (uint256) {
        return _credited.length;
    }

    function creditedAt(uint256 i) external view returns (bytes32) {
        return _credited[i];
    }

    function daysLength() external view returns (uint256) {
        return _days.length;
    }

    function dayAt(uint256 i) external view returns (uint256) {
        return _days[i];
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}

/// @notice Invariant suite (BUILD_BRIEF §5.4): escrow solvency, pending accounting, terminal states, USD₮0 conservation,
///         cashback reserve accounting and the credit book, plus an end-of-run liveness check that every pending order
///         can be self-refunded and every credit paid out even with PayLight gone, the gateway paused and TapeOut broken.
/// forge-config: default.invariant.fail-on-revert = true
contract PayLightInvariantTest is Fixture {
    PayLightHandler internal handler;
    uint256 internal initialSupply;
    address[] internal actorList;

    function setUp() public override {
        super.setUp();
        // a tighter daily cap than the pilot default so the cap is hit regularly within a run
        vm.prank(admin);
        gateway.setDailyVolumeCap(150e6);
        _topUp(300);

        string[3] memory names = ["carol", "dave", "erin"];
        uint256[] memory pks = new uint256[](5);
        actorList.push(alice);
        pks[0] = alicePk;
        actorList.push(bob);
        pks[1] = bobPk;
        for (uint256 i; i < 3; ++i) {
            (address a, uint256 pk) = makeAddrAndKey(names[i]);
            usdt0.mint(a, 10_000e6);
            actorList.push(a);
            pks[i + 2] = pk;
        }

        handler = new PayLightHandler(
            PayLightHandler.Deps({
                gateway: gateway,
                router: router,
                usdt0: usdt0,
                transistors: transistors,
                processor: processor,
                admin: admin,
                operator: operator,
                keeper: keeper,
                treasury: treasury,
                signerPk: signerPk
            }),
            actorList,
            pks
        );
        initialSupply = usdt0.totalSupply();

        bytes4[] memory sel = new bytes4[](16);
        sel[0] = PayLightHandler.pay.selector;
        sel[1] = PayLightHandler.payWithPermit.selector;
        sel[2] = PayLightHandler.payWithAuthorization.selector;
        sel[3] = PayLightHandler.markFulfilled.selector;
        sel[4] = PayLightHandler.refund.selector;
        sel[5] = PayLightHandler.claimRefund.selector;
        sel[6] = PayLightHandler.retryCashback.selector;
        sel[7] = PayLightHandler.togglePause.selector;
        sel[8] = PayLightHandler.setCashbackRouterEnabled.selector;
        sel[9] = PayLightHandler.setRefundTimeout.selector;
        sel[10] = PayLightHandler.topUp.selector;
        sel[11] = PayLightHandler.distribute.selector;
        sel[12] = PayLightHandler.buyTransistors.selector;
        sel[13] = PayLightHandler.setTapeOutMode.selector;
        sel[14] = PayLightHandler.warp.selector;
        sel[15] = PayLightHandler.unauthorized.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    // ─────────────────────────────────────────────────────────────── 1. solvency

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_gatewaySolvent() public view {
        assertGe(usdt0.balanceOf(address(gateway)), gateway.totalPending(), "balanceOf(gateway) >= totalPending");
        // nobody can donate in this model, so the escrow holds exactly the pending amount
        assertEq(usdt0.balanceOf(address(gateway)), gateway.totalPending(), "balance == totalPending");
    }

    // ─────────────────────────────────────────────────────────────── 2. pending accounting

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_totalPendingIsSumOfPaidOrders() public view {
        uint256 sumOnChain;
        uint256 sumGhost;
        uint256 n = handler.ordersLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.orderAt(i);
            PayLightGateway.Order memory o = gateway.getOrder(id);
            if (o.status == PayLightGateway.Status.Paid) sumOnChain += o.amount;
            if (handler.ghostStatus(id) == PayLightGateway.Status.Paid) sumGhost += handler.ghostAmount(id);
        }
        assertEq(gateway.totalPending(), sumOnChain, "totalPending == sum(Paid amounts)");
        assertEq(gateway.totalPending(), sumGhost, "totalPending == ghost sum");
        assertEq(gateway.totalPending(), handler.ghostTotalPending(), "totalPending == ghost running total");
        uint256 sumPendingList;
        for (uint256 i; i < handler.pendingLength(); ++i) {
            sumPendingList += handler.ghostAmount(handler.pendingAt(i));
        }
        assertEq(sumPendingList, sumOnChain, "pending list == Paid orders");
    }

    // ─────────────────────────────────────────────────────────────── 3. terminal states are final

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_terminalStatesAreFinal() public view {
        uint256 n = handler.ordersLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.orderAt(i);
            PayLightGateway.Order memory o = gateway.getOrder(id);
            PayLightGateway.Status g = handler.ghostStatus(id);
            // the ghost only ever moves Paid -> Fulfilled | Refunded, so equality means no order left a terminal state
            assertEq(uint8(o.status), uint8(g), "status == last ghost status");
            assertTrue(o.status != PayLightGateway.Status.None, "known order vanished");
            // order data is immutable once recorded
            assertEq(o.payer, handler.ghostPayer(id), "payer immutable");
            assertEq(o.amount, handler.ghostAmount(id), "amount immutable");
            assertEq(o.refundableAt, handler.ghostRefundableAt(id), "refundableAt immutable");
            if (o.status == PayLightGateway.Status.Refunded) assertFalse(o.cashbackCredited, "refunded but credited");
        }
    }

    // ─────────────────────────────────────────────────────────────── 4. USD₮0 conservation

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_usdt0Conserved() public view {
        uint256 sum = usdt0.balanceOf(address(gateway)) + usdt0.balanceOf(treasury);
        for (uint256 i; i < actorList.length; ++i) {
            sum += usdt0.balanceOf(actorList[i]);
        }
        assertEq(sum, initialSupply, "actors + gateway + treasury == initial supply");
        assertEq(usdt0.totalSupply(), initialSupply, "no mint/burn after setUp");
        assertEq(usdt0.balanceOf(treasury), handler.ghostSettledVolume(), "treasury == sum of settled amounts");
        assertEq(usdt0.balanceOf(address(router)), 0, "router never holds USD0");
    }

    // ─────────────────────────────────────────────────────────────── 5. reserve accounting

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_routerReserveAccounting() public view {
        assertEq(
            transistors.balanceOf(address(router), 0),
            router.reserveMinted() - router.distributedUnits(),
            "router NAND == reserveMinted - distributedUnits"
        );
        assertEq(transistors.balanceOf(address(router), 1), 0, "router never holds LATCH");
        assertEq(router.reserveMinted(), handler.ghostReserveMinted(), "reserveMinted == ghost");
        assertEq(router.distributedUnits(), handler.ghostDistributed(), "distributedUnits == ghost");
    }

    // ─────────────────────────────────────────────────────────────── 6. reserve bounds

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_routerReserveBounds() public view {
        assertLe(router.distributedUnits(), router.reserveMinted(), "distributed <= minted");
        assertLe(router.reserveMinted(), router.maxReserveMint(), "minted <= maxReserveMint");
        assertLe(router.maxReserveMint() * router.MAX_RESERVE_DIVISOR(), transistors.supplyCap(), "<= 20% of supply");
    }

    // ─────────────────────────────────────────────────────────────── 7. pending units

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_routerPendingUnitsMatchGhost() public view {
        uint256 unpaid;
        uint256 n = handler.creditedLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.creditedAt(i);
            (,, bool paid) = router.credits(id);
            assertEq(paid, handler.ghostCreditPaid(id), "credit paid flag == ghost");
            if (!paid) unpaid += handler.ghostUnits(id);
        }
        assertEq(router.pendingUnits(), unpaid, "pendingUnits == sum(credited, unpaid units)");
        assertEq(router.pendingUnits(), handler.ghostPendingUnits(), "pendingUnits == ghost running total");
    }

    // ─────────────────────────────────────────────────────────────── 8. credited => fulfilled

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_creditedOrdersAreFulfilled() public view {
        uint256 n = handler.creditedLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.creditedAt(i);
            PayLightGateway.Order memory o = gateway.getOrder(id);
            assertEq(uint8(o.status), uint8(PayLightGateway.Status.Fulfilled), "credited order is Fulfilled");
            assertTrue(o.cashbackCredited, "gateway marks it credited");
            (address payer, uint32 units,) = router.credits(id);
            assertEq(payer, o.payer, "credit payer == order payer");
            assertEq(units, o.cashbackUnits, "credit units == order units");
        }
        // and conversely: every order the router knows about is a credited, fulfilled order
        uint256 m = handler.ordersLength();
        for (uint256 i; i < m; ++i) {
            bytes32 id = handler.orderAt(i);
            (address payer,,) = router.credits(id);
            PayLightGateway.Order memory o = gateway.getOrder(id);
            assertEq(payer != address(0), o.cashbackCredited, "router credit <=> gateway credited flag");
            assertEq(o.cashbackCredited, handler.ghostCredited(id), "credited flag == ghost");
        }
    }

    // ─────────────────────────────────────────────────────────────── extra: daily volume

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_dailyVolumeTrackedAndCapped() public view {
        uint256 n = handler.daysLength();
        for (uint256 i; i < n; ++i) {
            uint256 day = handler.dayAt(i);
            assertEq(gateway.dailyVolume(day), handler.ghostDailyVolume(day), "dailyVolume == ghost");
            assertLe(gateway.dailyVolume(day), gateway.dailyVolumeCap(), "dailyVolume <= cap");
        }
    }

    // ─────────────────────────────────────────────────────────────── liveness at the end of every run

    /// @notice PayLight disappears: gateway paused, TapeOut broken, no operator. Every still-pending order can be
    ///         self-refunded by its payer after its own snapshotted deadline, the escrow empties to zero, and every
    ///         credited cashback can still be paid out once the reserve covers it.
    function afterInvariant() public {
        if (!gateway.paused()) {
            vm.prank(admin);
            gateway.pause();
        }
        processor.setMode(MockProcessor.Mode.Revert);
        vm.warp(handler.currentTime() + gateway.MAX_REFUND_TIMEOUT() + 1);

        uint256 np = handler.pendingLength();
        bytes32[] memory pend = new bytes32[](np);
        for (uint256 i; i < np; ++i) {
            pend[i] = handler.pendingAt(i);
        }
        for (uint256 i; i < np; ++i) {
            address payer = handler.ghostPayer(pend[i]);
            uint256 before = usdt0.balanceOf(payer);
            vm.prank(payer);
            gateway.claimRefund(pend[i]);
            assertEq(usdt0.balanceOf(payer), before + handler.ghostAmount(pend[i]), "self-refund amount");
        }
        assertEq(gateway.totalPending(), 0, "all pending refunded");
        assertEq(usdt0.balanceOf(address(gateway)), 0, "escrow empty");

        uint256 owed = router.pendingUnits();
        uint256 bal = transistors.balanceOf(address(router), 0);
        if (owed > bal && router.reserveMinted() + (owed - bal) <= router.maxReserveMint()) _topUp(owed - bal);
        uint256 nc = handler.creditedLength();
        bytes32[] memory credited = new bytes32[](nc);
        for (uint256 i; i < nc; ++i) {
            credited[i] = handler.creditedAt(i);
        }
        router.distribute(credited);
        assertEq(router.pendingUnits(), 0, "all credits paid");
        assertEq(
            transistors.balanceOf(address(router), 0),
            router.reserveMinted() - router.distributedUnits(),
            "reserve accounting after drain"
        );
    }

    // ─────────────────────────────────────────────────────────────── deterministic handler sanity check

    /// @notice Drives every handler action once on a fixed path, so a broken handler can't make the invariants vacuous.
    function test_handler_exercisesEveryAction() public {
        handler.pay(0, 10e6, 5);
        handler.payWithPermit(1, 20e6, 50);
        handler.payWithAuthorization(2, 3e6, 0);
        handler.payWithAuthorization(3, 7e6, 9);
        handler.pay(4, 1, 1);
        assertEq(handler.nPaid(), 5, "paid");

        handler.markFulfilled(1, keccak256("r1")); // pending pick
        handler.markFulfilled(6, keccak256("r2"));
        assertEq(handler.nFulfilled(), 2, "fulfilled");
        handler.refund(1);
        assertEq(handler.nRefunded(), 1, "refunded");
        handler.claimRefund(1, 1); // too early
        handler.claimRefund(1, 0); // a third party triggers after the deadline; funds go to the payer
        assertEq(handler.nClaimNotPayer(), 1);
        assertEq(handler.nClaimTooEarly(), 1);
        assertEq(handler.nClaimed(), 1);
        handler.markFulfilled(0, bytes32(0)); // seed % 5 == 0 -> any order; may be terminal
        handler.refund(5);
        handler.claimRefund(10, 3);

        handler.setCashbackRouterEnabled(false);
        handler.pay(0, 4e6, 7);
        handler.markFulfilled(1, keccak256("r3")); // fulfilled while router off -> uncredited
        handler.setCashbackRouterEnabled(true);
        handler.retryCashback(0);

        handler.topUp(1_000);
        handler.distribute(1, 6, 0);
        handler.distribute(2, 6, 1);
        assertGt(handler.nCashbackPaid(), 0, "cashback paid");

        handler.togglePause(257); // pause by operator (257 % 4 == 1, (257 >> 8) odd)
        assertTrue(gateway.paused());
        handler.pay(1, 5e6, 1); // rejected while paused
        assertEq(handler.nPayRejectedPaused(), 1);
        handler.togglePause(0); // operator can't unpause
        handler.togglePause(3); // admin unpauses
        assertFalse(gateway.paused());

        handler.buyTransistors(2, 300, false);
        handler.buyTransistors(2, 300, true);
        assertEq(gateway.computeTier(actorList[2]), 2);
        handler.setTapeOutMode(3); // a failure mode
        handler.payWithPermit(2, 9e6, 2); // tier falls back to 0, still pays
        handler.setTapeOutMode(1); // normal
        handler.setRefundTimeout(5 hours);
        handler.warp(2 days);
        for (uint256 w; w < 7; ++w) {
            handler.unauthorized(w, w, w);
        }
        assertEq(handler.nUnauthorized(), 7);

        invariant_gatewaySolvent();
        invariant_totalPendingIsSumOfPaidOrders();
        invariant_terminalStatesAreFinal();
        invariant_usdt0Conserved();
        invariant_routerReserveAccounting();
        invariant_routerReserveBounds();
        invariant_routerPendingUnitsMatchGhost();
        invariant_creditedOrdersAreFulfilled();
        invariant_dailyVolumeTrackedAndCapped();
        afterInvariant();
    }

    /// @notice The daily cap path of the handler is reachable (cap 150 USD₮0, orders up to 30).
    function test_handler_hitsDailyCap() public {
        for (uint256 i; i < 7; ++i) {
            handler.pay(i, type(uint256).max, 0); // max base each time
        }
        assertGt(handler.nPayRejectedCap(), 0, "cap reached");
        invariant_dailyVolumeTrackedAndCapped();
        handler.warp(1 days);
        handler.pay(0, type(uint256).max, 0);
        invariant_gatewaySolvent();
    }
}
