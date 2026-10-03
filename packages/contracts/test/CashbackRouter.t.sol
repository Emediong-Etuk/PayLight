// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Fixture} from "./utils/Fixture.sol";
import {CashbackRouter} from "../src/CashbackRouter.sol";
import {ICashbackRouter} from "../src/interfaces/ICashbackRouter.sol";
import {PayLightGateway} from "../src/PayLightGateway.sol";
import {MockTransistors} from "./mocks/MockTapeOut.sol";
import {MockUSDT0} from "./mocks/MockUSDT0.sol";
import {
    RtNonReceiver,
    RtTogglePayer,
    RtGasBurner,
    RtWrongMagicPayer,
    RtReentrantPayer,
    RtBouncePayer,
    RtFalseERC20,
    RtRevertBombPayer,
    RtHeavyPayer
} from "./mocks/rtPayers.sol";
import {RtBadTransistors} from "./mocks/rtBadTransistors.sol";

/// @notice Unit + integration tests for CashbackRouter (D-05 no-sell reserve, D-09 TapeOut isolation).
contract CashbackRouterTest is Fixture {
    bytes32 internal constant DEFAULT_ADMIN = 0x00;
    bytes32 internal constant KEEPER = keccak256("KEEPER_ROLE");

    address internal carol = makeAddr("carol");
    address internal anyone = makeAddr("anyone");

    // ═════════════════════════════════════════════════════════════════════ helpers

    function _id(string memory tag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("rt-order", tag));
    }

    function _credit(bytes32 orderId, address payer, uint32 units) internal {
        vm.prank(address(gateway));
        router.credit(orderId, payer, units);
    }

    function _ids(bytes32 a) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = a;
    }

    function _ids(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](2);
        r[0] = a;
        r[1] = b;
    }

    function _ids(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _ids(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _paid(bytes32 orderId) internal view returns (bool isPaid) {
        (,, isPaid) = router.credits(orderId);
    }

    function _nand(address who) internal view returns (uint256) {
        return transistors.balanceOf(who, 0);
    }

    function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
    }

    function _countEmittedBy(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++n;
        }
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    /// @dev Deploy a router on top of a misbehaving transistor contract.
    function _badSetup(RtBadTransistors.Mode mode) internal returns (RtBadTransistors bad, CashbackRouter r) {
        bad = new RtBadTransistors(SUPPLY_CAP, MINT_PRICE, PROTOCOL_FEE, creator);
        r = new CashbackRouter(address(gateway), address(bad), admin, keeper, MAX_RESERVE);
        bad.setRouter(address(r));
        bad.setMode(mode);
    }

    // ═════════════════════════════════════════════════════════════════════ constructor

    function test_constructor_revertsOnZeroGateway() public {
        vm.expectRevert(CashbackRouter.ZeroAddress.selector);
        new CashbackRouter(address(0), address(transistors), admin, keeper, MAX_RESERVE);
    }

    function test_constructor_revertsOnZeroTransistors() public {
        vm.expectRevert(CashbackRouter.ZeroAddress.selector);
        new CashbackRouter(address(gateway), address(0), admin, keeper, MAX_RESERVE);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(CashbackRouter.ZeroAddress.selector);
        new CashbackRouter(address(gateway), address(transistors), address(0), keeper, MAX_RESERVE);
    }

    function test_constructor_revertsOnZeroMaxReserve() public {
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        new CashbackRouter(address(gateway), address(transistors), admin, keeper, 0);
    }

    function test_constructor_revertsAbove20PercentOfSupplyCap() public {
        uint256 over = SUPPLY_CAP / 5 + 1;
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        new CashbackRouter(address(gateway), address(transistors), admin, keeper, over);
    }

    function test_constructor_revertsFarAboveCap() public {
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        new CashbackRouter(address(gateway), address(transistors), admin, keeper, SUPPLY_CAP);
    }

    function test_constructor_exactly20PercentOk() public {
        CashbackRouter r = new CashbackRouter(address(gateway), address(transistors), admin, keeper, SUPPLY_CAP / 5);
        assertEq(r.maxReserveMint(), 200_000);
        assertEq(r.maxReserveMint() * r.MAX_RESERVE_DIVISOR(), transistors.supplyCap());
    }

    function test_constructor_oneUnitOk() public {
        CashbackRouter r = new CashbackRouter(address(gateway), address(transistors), admin, keeper, 1);
        assertEq(r.maxReserveMint(), 1);
    }

    /// @dev 20% is floor(cap / 5) when the cap isn't a multiple of 5.
    function test_constructor_capNotMultipleOfFive_floors() public {
        MockTransistors t = new MockTransistors(1_000_004, MINT_PRICE, PROTOCOL_FEE, creator);
        new CashbackRouter(address(gateway), address(t), admin, keeper, 200_000);
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        new CashbackRouter(address(gateway), address(t), admin, keeper, 200_001);
    }

    function test_constructor_overflowingMaxReserveReverts() public {
        vm.expectRevert(stdError.arithmeticError);
        new CashbackRouter(address(gateway), address(transistors), admin, keeper, type(uint256).max);
    }

    function test_constructor_transistorsWithoutCodeReverts() public {
        address eoa = makeAddr("notAContract");
        try new CashbackRouter(address(gateway), eoa, admin, keeper, 1) returns (CashbackRouter) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0, "empty revert from call to codeless address");
        }
    }

    function testFuzz_constructor_reserveBound(uint256 m) public {
        m = bound(m, 0, SUPPLY_CAP + 10);
        if (m == 0 || m * 5 > SUPPLY_CAP) {
            vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
            new CashbackRouter(address(gateway), address(transistors), admin, keeper, m);
        } else {
            CashbackRouter r = new CashbackRouter(address(gateway), address(transistors), admin, keeper, m);
            assertEq(r.maxReserveMint(), m);
        }
    }

    function test_constructor_setsImmutablesAndRoles() public view {
        assertEq(router.gateway(), address(gateway));
        assertEq(address(router.transistors()), address(transistors));
        assertEq(router.maxReserveMint(), MAX_RESERVE);
        assertTrue(router.hasRole(DEFAULT_ADMIN, admin));
        assertTrue(router.hasRole(KEEPER, keeper));
        assertFalse(router.hasRole(KEEPER, admin), "admin is not automatically keeper");
        assertFalse(router.hasRole(DEFAULT_ADMIN, keeper));
        assertFalse(router.hasRole(DEFAULT_ADMIN, address(gateway)));
        assertEq(router.getRoleAdmin(KEEPER), DEFAULT_ADMIN);
        assertEq(router.reserveMinted(), 0);
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distributedUnits(), 0);
    }

    function test_constants() public view {
        assertEq(router.KEEPER_ROLE(), KEEPER);
        assertEq(router.DEFAULT_ADMIN_ROLE(), DEFAULT_ADMIN);
        assertEq(router.NAND_ID(), 0);
        assertEq(router.MAX_RESERVE_DIVISOR(), 5);
        assertEq(router.TRANSFER_GAS_LIMIT(), 200_000);
    }

    function test_constructor_zeroKeeperAllowed_noKeeperGranted() public {
        CashbackRouter r = new CashbackRouter(address(gateway), address(transistors), admin, address(0), MAX_RESERVE);
        assertFalse(r.hasRole(KEEPER, address(0)));
        assertTrue(r.hasRole(DEFAULT_ADMIN, admin));
        // nobody can top up until the admin grants KEEPER_ROLE
        uint256 cost = r.topUpCost(1);
        vm.prank(keeper);
        vm.expectRevert(_unauthorized(keeper, KEEPER));
        r.topUp{value: cost}(1);
        vm.prank(admin);
        r.grantRole(KEEPER, keeper);
        vm.prank(keeper);
        r.topUp{value: cost}(1);
        assertEq(r.reserveMinted(), 1);
    }

    // ═════════════════════════════════════════════════════════════════════ credit

    function test_credit_onlyGateway() public {
        bytes32 id = _id("a");
        address[4] memory callers = [alice, admin, keeper, operator];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(CashbackRouter.NotGateway.selector);
            router.credit(id, alice, 5);
        }
        vm.expectRevert(CashbackRouter.NotGateway.selector);
        router.credit(id, alice, 5); // the test contract itself
        assertEq(router.pendingUnits(), 0);
    }

    function testFuzz_credit_nonGatewayReverts(address caller) public {
        vm.assume(caller != address(gateway));
        vm.prank(caller);
        vm.expectRevert(CashbackRouter.NotGateway.selector);
        router.credit(_id("f"), alice, 5);
    }

    function test_credit_gatewayCheckBeforeValidation() public {
        vm.prank(alice);
        vm.expectRevert(CashbackRouter.NotGateway.selector);
        router.credit(_id("a"), address(0), 0);
    }

    function test_credit_zeroPayerReverts() public {
        vm.prank(address(gateway));
        vm.expectRevert(CashbackRouter.InvalidCredit.selector);
        router.credit(_id("a"), address(0), 5);
    }

    function test_credit_zeroUnitsReverts() public {
        vm.prank(address(gateway));
        vm.expectRevert(CashbackRouter.InvalidCredit.selector);
        router.credit(_id("a"), alice, 0);
    }

    function test_credit_duplicateOrderIdReverts() public {
        bytes32 id = _id("a");
        _credit(id, alice, 5);
        vm.prank(address(gateway));
        vm.expectRevert(CashbackRouter.AlreadyCredited.selector);
        router.credit(id, alice, 5);
        // different payer / units does not help either
        vm.prank(address(gateway));
        vm.expectRevert(CashbackRouter.AlreadyCredited.selector);
        router.credit(id, bob, 1);
        assertEq(router.pendingUnits(), 5);
        (address p, uint32 u,) = router.credits(id);
        assertEq(p, alice);
        assertEq(u, 5);
    }

    function test_credit_duplicateAfterPaidStillReverts() public {
        _topUp(10);
        bytes32 id = _id("a");
        _credit(id, alice, 5);
        router.distribute(_ids(id));
        assertTrue(_paid(id));
        vm.prank(address(gateway));
        vm.expectRevert(CashbackRouter.AlreadyCredited.selector);
        router.credit(id, alice, 5);
        assertEq(router.pendingUnits(), 0);
    }

    function test_credit_emitsEventAndStores() public {
        bytes32 id = _id("a");
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackCredited(id, alice, 7);
        _credit(id, alice, 7);
        (address p, uint32 u, bool isPaid) = router.credits(id);
        assertEq(p, alice);
        assertEq(u, 7);
        assertFalse(isPaid);
    }

    function test_credit_pendingUnitsAccounting() public {
        _credit(_id("a"), alice, 5);
        assertEq(router.pendingUnits(), 5);
        _credit(_id("b"), bob, 50);
        assertEq(router.pendingUnits(), 55);
        _credit(_id("c"), alice, type(uint32).max);
        assertEq(router.pendingUnits(), 55 + uint256(type(uint32).max));
        assertEq(router.distributedUnits(), 0, "credit never moves tokens");
        assertEq(router.reserveMinted(), 0);
    }

    function test_credit_doesNotRequireReserve() public {
        assertEq(_nand(address(router)), 0);
        _credit(_id("a"), alice, 5);
        assertEq(router.pendingUnits(), 5);
        assertEq(router.freeReserve(), 0);
    }

    function test_credit_viaInterface() public {
        vm.prank(address(gateway));
        ICashbackRouter(address(router)).credit(_id("i"), alice, 3);
        assertEq(router.pendingUnits(), 3);
    }

    // ═════════════════════════════════════════════════════════════════════ distribute: happy paths

    function test_distribute_paysCreditedOrderToPayer() public {
        _topUp(100);
        bytes32 id = _id("a");
        _credit(id, alice, 5);

        vm.expectEmit(true, true, true, true, address(transistors));
        emit IERC1155.TransferSingle(address(router), address(router), alice, 0, 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(id, alice, 5);
        uint256 paid = router.distribute(_ids(id));

        assertEq(paid, 1);
        assertEq(_nand(alice), 5);
        assertEq(_nand(address(router)), 95);
        assertTrue(_paid(id));
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distributedUnits(), 5);
        assertEq(router.freeReserve(), 95);
        assertEq(router.reserveMinted(), 100, "distribution does not touch the mint counter");
    }

    function test_distribute_eachOrderGoesToItsOwnPayer() public {
        _topUp(100);
        bytes32 a = _id("a");
        bytes32 b = _id("b");
        bytes32 c = _id("c");
        _credit(a, alice, 3);
        _credit(b, bob, 7);
        _credit(c, carol, 11);

        vm.prank(anyone);
        assertEq(router.distribute(_ids(c, a, b)), 3);

        assertEq(_nand(alice), 3);
        assertEq(_nand(bob), 7);
        assertEq(_nand(carol), 11);
        assertEq(_nand(anyone), 0);
        assertEq(router.distributedUnits(), 21);
        assertEq(router.pendingUnits(), 0);
        assertEq(_nand(address(router)), 79);
    }

    function test_distribute_samePayerMultipleOrders() public {
        _topUp(100);
        _credit(_id("a"), alice, 3);
        _credit(_id("b"), alice, 4);
        assertEq(router.distribute(_ids(_id("a"), _id("b"))), 2);
        assertEq(_nand(alice), 7);
    }

    function test_distribute_exactReserve() public {
        _topUp(5);
        bytes32 id = _id("a");
        _credit(id, alice, 5);
        assertEq(router.distribute(_ids(id)), 1);
        assertEq(_nand(address(router)), 0);
        assertEq(router.freeReserve(), 0);
    }

    function test_distribute_emptyArrayReturnsZero() public {
        _topUp(10);
        vm.recordLogs();
        assertEq(router.distribute(new bytes32[](0)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_distribute_permissionless_anyCaller() public {
        _topUp(10);
        bytes32 id = _id("a");
        _credit(id, alice, 4);
        address[4] memory callers = [anyone, bob, keeper, address(0xdead)];
        vm.prank(callers[0]);
        assertEq(router.distribute(_ids(id)), 1);
        // other callers can call too (nothing left to pay)
        for (uint256 i = 1; i < callers.length; ++i) {
            vm.prank(callers[i]);
            assertEq(router.distribute(_ids(id)), 0);
        }
        assertEq(_nand(alice), 4, "funds only ever go to the credited payer");
        for (uint256 i; i < callers.length; ++i) {
            assertEq(_nand(callers[i]), 0);
        }
    }

    function test_distribute_callerCannotRedirect() public {
        _topUp(10);
        bytes32 id = _id("a");
        _credit(id, alice, 4);
        vm.prank(bob);
        router.distribute(_ids(id));
        assertEq(_nand(bob), 0);
        assertEq(_nand(alice), 4);
    }

    // ═════════════════════════════════════════════════════════════════════ distribute: skipping

    function test_distribute_skipsUnknownIds() public {
        _topUp(10);
        vm.recordLogs();
        uint256 paid = router.distribute(_ids(_id("nope"), bytes32(0), bytes32(type(uint256).max)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(paid, 0);
        assertEq(logs.length, 0, "no events for unknown ids");
        assertEq(_nand(address(router)), 10);
        assertEq(router.distributedUnits(), 0);
    }

    function test_distribute_skipsAlreadyPaid() public {
        _topUp(10);
        bytes32 id = _id("a");
        _credit(id, alice, 4);
        assertEq(router.distribute(_ids(id)), 1);

        vm.recordLogs();
        assertEq(router.distribute(_ids(id)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no transfer, no paid/deferred event");
        assertEq(_nand(alice), 4);
        assertEq(router.distributedUnits(), 4);
        assertEq(_nand(address(router)), 6);
    }

    function test_distribute_sameIdTwiceInOneCall_paysOnce() public {
        _topUp(100);
        bytes32 id = _id("a");
        _credit(id, alice, 5);

        vm.recordLogs();
        uint256 paid = router.distribute(_ids(id, id, id));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(paid, 1);
        assertEq(_nand(alice), 5);
        assertEq(_countLogs(logs, address(router), CashbackRouter.CashbackPaid.selector), 1);
        assertEq(_countLogs(logs, address(transistors), IERC1155.TransferSingle.selector), 1);
        assertEq(router.distributedUnits(), 5);
        assertEq(router.pendingUnits(), 0);
    }

    function test_distribute_duplicateIdInterleaved_paysOnce() public {
        _topUp(100);
        bytes32 a = _id("a");
        bytes32 b = _id("b");
        _credit(a, alice, 5);
        _credit(b, bob, 6);
        assertEq(router.distribute(_ids(a, b, a, b)), 2);
        assertEq(_nand(alice), 5);
        assertEq(_nand(bob), 6);
        assertEq(router.distributedUnits(), 11);
    }

    function test_distribute_mixOfUnknownPaidAndNew() public {
        _topUp(100);
        bytes32 a = _id("a");
        bytes32 b = _id("b");
        _credit(a, alice, 5);
        router.distribute(_ids(a));
        _credit(b, bob, 6);
        assertEq(router.distribute(_ids(_id("unknown"), a, b, _id("unknown2"))), 1);
        assertEq(_nand(alice), 5);
        assertEq(_nand(bob), 6);
    }

    // ═════════════════════════════════════════════════════════════════════ distribute: insufficient reserve

    function test_distribute_noReserve_defers() public {
        bytes32 id = _id("a");
        _credit(id, alice, 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, alice, 5, true);
        assertEq(router.distribute(_ids(id)), 0);
        assertFalse(_paid(id));
        assertEq(router.pendingUnits(), 5);
    }

    function test_distribute_insufficientReserve_defersThenSucceedsAfterTopUp() public {
        _topUp(5);
        bytes32 id = _id("a");
        _credit(id, alice, 10);

        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, alice, 10, true);
        assertEq(router.distribute(_ids(id)), 0);

        assertFalse(_paid(id));
        assertEq(router.pendingUnits(), 10);
        assertEq(router.distributedUnits(), 0);
        assertEq(_nand(address(router)), 5);
        assertEq(_nand(alice), 0);
        assertEq(router.freeReserve(), 0);

        _topUp(5);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(id, alice, 10);
        assertEq(router.distribute(_ids(id)), 1);
        assertTrue(_paid(id));
        assertEq(_nand(alice), 10);
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distributedUnits(), 10);
        assertEq(_nand(address(router)), 0);
    }

    /// @dev `available` is tracked across the batch: a big order that doesn't fit is deferred, smaller later ones still pay.
    function test_distribute_runningAvailableAcrossBatch() public {
        _topUp(10);
        bytes32 a = _id("a");
        bytes32 b = _id("b");
        bytes32 c = _id("c");
        bytes32 d = _id("d");
        _credit(a, alice, 6);
        _credit(b, bob, 6);
        _credit(c, carol, 3);
        _credit(d, anyone, 1);

        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(a, alice, 6);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(b, bob, 6, true);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(c, carol, 3);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(d, anyone, 1);
        assertEq(router.distribute(_ids(a, b, c, d)), 3);

        assertEq(_nand(address(router)), 0);
        assertEq(router.pendingUnits(), 6);
        assertEq(router.distributedUnits(), 10);
        assertFalse(_paid(b));

        _topUp(6);
        assertEq(router.distribute(_ids(a, b, c, d)), 1);
        assertEq(_nand(bob), 6);
        assertEq(router.pendingUnits(), 0);
    }

    function test_distribute_partialBatches() public {
        _topUp(1_000);
        bytes32[] memory all = new bytes32[](6);
        for (uint256 i; i < all.length; ++i) {
            all[i] = _id(vm.toString(i));
            _credit(all[i], i % 2 == 0 ? alice : bob, uint32(i + 1)); // 1..6
        }
        assertEq(router.pendingUnits(), 21);

        assertEq(router.distribute(_ids(all[0], all[1])), 2);
        assertEq(router.pendingUnits(), 18);
        assertEq(router.distributedUnits(), 3);

        assertEq(router.distribute(_ids(all[1], all[2], all[3])), 2); // all[1] already paid
        assertEq(router.pendingUnits(), 11);

        assertEq(router.distribute(all), 2); // only 4 and 5 left
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distributedUnits(), 21);
        assertEq(_nand(alice), 1 + 3 + 5);
        assertEq(_nand(bob), 2 + 4 + 6);
        assertEq(router.distribute(all), 0);
    }

    // ═════════════════════════════════════════════════════════════════════ distribute: hostile payers

    function test_distribute_nonReceiverContract_defersAndRestoresState() public {
        _topUp(100);
        RtNonReceiver nr = new RtNonReceiver();
        bytes32 idNr = _id("nr");
        bytes32 idA = _id("a");
        _credit(idNr, address(nr), 7);
        _credit(idA, alice, 5);
        uint256 pendingBefore = router.pendingUnits();
        uint256 distributedBefore = router.distributedUnits();
        assertEq(pendingBefore, 12);

        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(idNr, address(nr), 7, false);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(idA, alice, 5);
        assertEq(router.distribute(_ids(idNr, idA)), 1);

        (address p, uint32 u, bool isPaid) = router.credits(idNr);
        assertEq(p, address(nr));
        assertEq(u, 7);
        assertFalse(isPaid, "paid flag restored");
        assertEq(router.pendingUnits(), pendingBefore - 5, "only alice's units left pending");
        assertEq(router.distributedUnits(), distributedBefore + 5, "only alice's units distributed");
        assertEq(_nand(address(nr)), 0);
        assertEq(_nand(address(router)), 95);

        // a retry defers again and changes nothing
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(idNr, address(nr), 7, false);
        assertEq(router.distribute(_ids(idNr)), 0);
        assertEq(router.pendingUnits(), 7);
        assertEq(router.distributedUnits(), 5);
        assertEq(router.freeReserve(), 95 - 7);
    }

    function test_distribute_nonReceiverAlone_stateUnchanged() public {
        _topUp(100);
        RtNonReceiver nr = new RtNonReceiver();
        bytes32 id = _id("nr");
        _credit(id, address(nr), 7);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, address(nr), 7, false);
        assertEq(router.distribute(_ids(id)), 0);
        assertFalse(_paid(id));
        assertEq(router.pendingUnits(), 7);
        assertEq(router.distributedUnits(), 0);
        assertEq(_nand(address(router)), 100);
    }

    /// @dev A failed transfer must not consume `available`: with reserve exactly = alice + bob, both still get paid.
    function test_distribute_failedTransferDoesNotConsumeAvailable() public {
        _topUp(12);
        RtNonReceiver nr = new RtNonReceiver();
        _credit(_id("nr"), address(nr), 7);
        _credit(_id("a"), alice, 5);
        _credit(_id("b"), bob, 7);
        assertEq(router.distribute(_ids(_id("nr"), _id("a"), _id("b"))), 2);
        assertEq(_nand(alice), 5);
        assertEq(_nand(bob), 7);
        assertEq(_nand(address(router)), 0);
        assertEq(router.pendingUnits(), 7);
    }

    function test_distribute_gasBurningHook_defersAndRestOfBatchPays() public {
        _topUp(100);
        RtGasBurner gb = new RtGasBurner();
        bytes32 a = _id("a");
        bytes32 g = _id("g");
        bytes32 b = _id("b");
        _credit(a, alice, 3);
        _credit(g, address(gb), 4);
        _credit(b, bob, 5);

        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(a, alice, 3);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(g, address(gb), 4, false);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(b, bob, 5);
        uint256 gasBefore = gasleft();
        uint256 paid = router.distribute(_ids(a, g, b));
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(paid, 2);
        assertEq(_nand(alice), 3);
        assertEq(_nand(bob), 5);
        assertEq(_nand(address(gb)), 0);
        assertFalse(_paid(g));
        assertEq(router.pendingUnits(), 4);
        assertEq(router.distributedUnits(), 8);
        // the hook can only burn the per-transfer cap, not the whole call's gas
        assertLt(gasUsed, router.TRANSFER_GAS_LIMIT() + 300_000, "gas burn bounded by TRANSFER_GAS_LIMIT");
    }

    function test_distribute_twoGasBurners_boundedGas() public {
        _topUp(100);
        RtGasBurner g1 = new RtGasBurner();
        RtGasBurner g2 = new RtGasBurner();
        _credit(_id("g1"), address(g1), 1);
        _credit(_id("g2"), address(g2), 1);
        _credit(_id("a"), alice, 1);
        uint256 gasBefore = gasleft();
        assertEq(router.distribute(_ids(_id("g1"), _id("g2"), _id("a"))), 1);
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(_nand(alice), 1);
        assertLt(gasUsed, 2 * router.TRANSFER_GAS_LIMIT() + 300_000);
    }

    function test_distribute_wrongMagicValue_defers() public {
        _topUp(100);
        RtWrongMagicPayer w = new RtWrongMagicPayer();
        bytes32 id = _id("w");
        _credit(id, address(w), 4);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, address(w), 4, false);
        assertEq(router.distribute(_ids(id)), 0);
        assertFalse(_paid(id));
        assertEq(router.pendingUnits(), 4);
        assertEq(_nand(address(router)), 100);
    }

    function test_distribute_rejectingPayer_paidOnceItAccepts() public {
        _topUp(100);
        RtTogglePayer t = new RtTogglePayer();
        bytes32 id = _id("t");
        _credit(id, address(t), 9);

        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, address(t), 9, false);
        assertEq(router.distribute(_ids(id)), 0);
        assertEq(router.pendingUnits(), 9);

        t.setAccepting(true);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(id, address(t), 9);
        assertEq(router.distribute(_ids(id)), 1);
        assertEq(_nand(address(t)), 9);
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distributedUnits(), 9);
    }

    /// @dev Hook re-enters distribute and lets the revert bubble: the transfer fails, the order is deferred, state restored.
    function test_distribute_reentrantHook_bubbling_isDeferred() public {
        _topUp(100);
        RtReentrantPayer rp = new RtReentrantPayer(address(router));
        bytes32 id = _id("r");
        bytes32 a = _id("a");
        _credit(id, address(rp), 6);
        _credit(a, alice, 2);
        rp.configure(_ids(id, a), true);

        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, address(rp), 6, false);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(a, alice, 2);
        assertEq(router.distribute(_ids(id, a)), 1);

        assertFalse(_paid(id));
        assertEq(_nand(address(rp)), 0);
        assertEq(_nand(alice), 2, "alice paid exactly once");
        assertEq(router.pendingUnits(), 6);
        assertEq(router.distributedUnits(), 2);
        assertEq(_nand(address(router)), 98);
    }

    /// @dev Hook re-enters distribute but swallows the error: the inner call reverts with ReentrancyGuardReentrantCall,
    ///      the outer transfer succeeds, and nobody is paid twice.
    function test_distribute_reentrantHook_swallowing_innerFailsOuterPaysOnce() public {
        _topUp(100);
        RtReentrantPayer rp = new RtReentrantPayer(address(router));
        bytes32 id = _id("r");
        bytes32 a = _id("a");
        _credit(id, address(rp), 6);
        _credit(a, alice, 2);
        rp.configure(_ids(id, a), false);

        vm.recordLogs();
        assertEq(router.distribute(_ids(id, a)), 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(rp.attempts(), 1);
        assertFalse(rp.innerSucceeded());
        assertEq(rp.lastError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(_nand(address(rp)), 6);
        assertEq(_nand(alice), 2);
        assertEq(_countLogs(logs, address(router), CashbackRouter.CashbackPaid.selector), 2);
        assertEq(router.distributedUnits(), 8);
        assertEq(router.pendingUnits(), 0);
    }

    /// @dev A hook that reverts with ~100 KB of data can't grief the batch (the router's `catch {}` copies nothing).
    function test_distribute_revertDataBomb_defersAndRestOfBatchPays() public {
        _topUp(100);
        RtRevertBombPayer rb = new RtRevertBombPayer();
        bytes32 id = _id("bomb");
        _credit(id, address(rb), 4);
        _credit(_id("a"), alice, 6);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, address(rb), 4, false);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(_id("a"), alice, 6);
        uint256 gasBefore = gasleft();
        assertEq(router.distribute(_ids(id, _id("a"))), 1);
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(_nand(alice), 6);
        assertEq(_nand(address(rb)), 0);
        assertEq(router.pendingUnits(), 4);
        assertLt(gasUsed, router.TRANSFER_GAS_LIMIT() + 300_000);
    }

    /// @dev The per-transfer cap is not so tight that a legitimately heavier receiver hook (~100k gas) fails.
    function test_distribute_heavyButHonestHook_isPaid() public {
        _topUp(100);
        RtHeavyPayer hp = new RtHeavyPayer();
        bytes32 id = _id("heavy");
        _credit(id, address(hp), 8);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(id, address(hp), 8);
        assertEq(router.distribute(_ids(id)), 1);
        assertEq(_nand(address(hp)), 8);
        assertEq(hp.receipts(), 1);
        assertEq(hp.book(3), 12);
    }

    /// @dev A payer can't push its cashback back into the reserve; the bounce makes its own receipt fail.
    function test_distribute_payerBouncingTokensBack_isDeferred() public {
        _topUp(100);
        RtBouncePayer bp = new RtBouncePayer(address(router));
        bytes32 id = _id("bounce");
        _credit(id, address(bp), 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, address(bp), 5, false);
        assertEq(router.distribute(_ids(id)), 0);
        assertEq(_nand(address(bp)), 0);
        assertEq(_nand(address(router)), 100);
        assertEq(router.pendingUnits(), 5);
        assertEq(router.distributedUnits(), 0);
    }

    /// @dev The router can never pay itself (its receiver rejects the inbound transfer).
    function test_distribute_payerIsRouterItself_neverPays() public {
        _topUp(100);
        bytes32 id = _id("self");
        _credit(id, address(router), 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(id, address(router), 5, false);
        assertEq(router.distribute(_ids(id)), 0);
        assertEq(_nand(address(router)), 100);
        assertEq(router.distributedUnits(), 0);
    }

    function test_distribute_returnValueCountsOnlyPaid() public {
        _topUp(20);
        RtNonReceiver nr = new RtNonReceiver();
        bytes32 paidBefore = _id("paidBefore");
        _credit(paidBefore, carol, 1);
        router.distribute(_ids(paidBefore)); // reserve 19

        bytes32[] memory ids = new bytes32[](7);
        ids[0] = _id("unknown");
        ids[1] = paidBefore;
        ids[2] = _id("ok1");
        ids[3] = _id("tooBig");
        ids[4] = _id("nonReceiver");
        ids[5] = _id("ok2");
        ids[6] = _id("ok1"); // duplicate
        _credit(ids[2], alice, 4);
        _credit(ids[3], bob, 50);
        _credit(ids[4], address(nr), 2);
        _credit(ids[5], bob, 3);

        assertEq(router.distribute(ids), 2);
        assertEq(_nand(alice), 4);
        assertEq(_nand(bob), 3);
        assertEq(router.distributedUnits(), 1 + 4 + 3);
        assertEq(router.pendingUnits(), 50 + 2);
    }

    // ═════════════════════════════════════════════════════════════════════ topUp

    function test_topUpCost() public view {
        assertEq(router.topUpCost(0), PROTOCOL_FEE);
        assertEq(router.topUpCost(1), MINT_PRICE + PROTOCOL_FEE);
        assertEq(router.topUpCost(1_000), MINT_PRICE * 1_000 + PROTOCOL_FEE);
    }

    function test_topUp_onlyKeeper() public {
        uint256 cost = router.topUpCost(10);
        address[5] memory callers = [alice, admin, operator, address(gateway), anyone];
        for (uint256 i; i < callers.length; ++i) {
            vm.deal(callers[i], cost);
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], KEEPER));
            router.topUp{value: cost}(10);
        }
        assertEq(router.reserveMinted(), 0);
    }

    function test_topUp_adminCanGrantAndRevokeKeeper() public {
        uint256 cost = router.topUpCost(10);
        vm.deal(alice, 2 * cost);
        vm.prank(admin);
        router.grantRole(KEEPER, alice);
        vm.prank(alice);
        router.topUp{value: cost}(10);
        assertEq(router.reserveMinted(), 10);

        vm.prank(admin);
        router.revokeRole(KEEPER, alice);
        vm.prank(alice);
        vm.expectRevert(_unauthorized(alice, KEEPER));
        router.topUp{value: cost}(10);
    }

    function test_topUp_keeperCannotGrantRoles() public {
        vm.prank(keeper);
        vm.expectRevert(_unauthorized(keeper, DEFAULT_ADMIN));
        router.grantRole(KEEPER, alice);
    }

    function test_topUp_wrongPayment_plusOneWei() public {
        uint256 cost = router.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashbackRouter.WrongPayment.selector, cost));
        router.topUp{value: cost + 1}(10);
    }

    function test_topUp_wrongPayment_minusOneWei() public {
        uint256 cost = router.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashbackRouter.WrongPayment.selector, cost));
        router.topUp{value: cost - 1}(10);
    }

    function test_topUp_wrongPayment_zero() public {
        uint256 cost = router.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashbackRouter.WrongPayment.selector, cost));
        router.topUp(10);
    }

    function testFuzz_topUp_onlyExactPayment(uint256 units, uint256 value) public {
        units = bound(units, 1, 5_000);
        uint256 cost = router.topUpCost(units);
        value = bound(value, 0, cost * 2);
        vm.deal(keeper, value);
        vm.prank(keeper);
        if (value != cost) {
            vm.expectRevert(abi.encodeWithSelector(CashbackRouter.WrongPayment.selector, cost));
            router.topUp{value: value}(units);
        } else {
            router.topUp{value: value}(units);
            assertEq(router.reserveMinted(), units);
            assertEq(_nand(address(router)), units);
        }
    }

    function test_topUp_reserveCapBoundary() public {
        _topUp(MAX_RESERVE - 1);
        assertEq(router.reserveMinted(), MAX_RESERVE - 1);

        uint256 cost2 = router.topUpCost(2);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        router.topUp{value: cost2}(2);

        _topUp(1); // exactly at the cap
        assertEq(router.reserveMinted(), MAX_RESERVE);
        assertEq(_nand(address(router)), MAX_RESERVE);

        uint256 cost1 = router.topUpCost(1);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        router.topUp{value: cost1}(1);
    }

    function test_topUp_fullCapInOneCall() public {
        _topUp(MAX_RESERVE);
        assertEq(router.reserveMinted(), MAX_RESERVE);
    }

    function test_topUp_overCapFromZero_checkedBeforePayment() public {
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        router.topUp{value: 0}(MAX_RESERVE + 1);
    }

    /// @dev The cap is lifetime: distributing tokens out does not free mint capacity.
    function test_topUp_capIsLifetime_notBalance() public {
        _topUp(MAX_RESERVE);
        _credit(_id("a"), alice, 50);
        router.distribute(_ids(_id("a")));
        assertEq(_nand(address(router)), MAX_RESERVE - 50);
        uint256 cost = router.topUpCost(1);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.ReserveCapExceeded.selector);
        router.topUp{value: cost}(1);
    }

    function test_topUp_accountingEventAndRealMint() public {
        uint256 units = 250;
        uint256 cost = router.topUpCost(units);
        assertEq(cost, MINT_PRICE * units + PROTOCOL_FEE);
        uint256 owedBefore = transistors.owed(creator);
        uint256 mintedBefore = transistors.minted();
        uint256 tBalBefore = address(transistors).balance;
        uint256 keeperBefore = keeper.balance;

        vm.expectEmit(true, true, true, true, address(transistors));
        emit IERC1155.TransferSingle(address(router), address(0), address(router), 0, units);
        vm.expectEmit(true, false, false, true, address(router));
        emit CashbackRouter.ReserveToppedUp(keeper, units, cost);
        vm.prank(keeper);
        router.topUp{value: cost}(units);

        assertEq(router.reserveMinted(), units);
        assertEq(_nand(address(router)), units);
        assertEq(transistors.balanceOf(address(router), 1), 0, "no LATCH");
        assertEq(transistors.owed(creator) - owedBefore, MINT_PRICE * units, "creator owed increases");
        assertEq(transistors.minted() - mintedBefore, units, "lifetime minted increases");
        assertEq(address(transistors).balance - tBalBefore, cost, "the whole payment went to the mint");
        assertEq(keeperBefore - keeper.balance, cost);
        assertEq(address(router).balance, 0, "router keeps no OKB");
        assertEq(router.freeReserve(), units);
    }

    function test_topUp_accumulates() public {
        _topUp(10);
        _topUp(20);
        _topUp(30);
        assertEq(router.reserveMinted(), 60);
        assertEq(_nand(address(router)), 60);
    }

    /// @dev Documents current behaviour: topUp(0) is accepted and costs just the flat protocol fee (keeper-only, no
    ///      effect on the reserve).
    function test_topUp_zeroUnits_onlyProtocolFee() public {
        uint256 cost = router.topUpCost(0);
        assertEq(cost, PROTOCOL_FEE);
        vm.expectEmit(true, false, false, true, address(router));
        emit CashbackRouter.ReserveToppedUp(keeper, 0, cost);
        vm.prank(keeper);
        router.topUp{value: cost}(0);
        assertEq(router.reserveMinted(), 0);
        assertEq(_nand(address(router)), 0);
    }

    /// @dev OKB force-sent to the router (selfdestruct) must not brick topUp's native-balance check.
    function test_topUp_preexistingNativeBalanceDoesNotBreakTopUp() public {
        vm.deal(address(router), 1 ether);
        _topUp(10);
        assertEq(router.reserveMinted(), 10);
        assertEq(address(router).balance, 1 ether);
    }

    function test_topUp_soldOutBubbles() public {
        uint256 left = SUPPLY_CAP - transistors.minted();
        _giveTransistors(bob, left - 10);
        uint256 cost = router.topUpCost(11);
        vm.prank(keeper);
        vm.expectRevert(MockTransistors.SoldOut.selector);
        router.topUp{value: cost}(11);
        _topUp(10);
        assertEq(transistors.minted(), SUPPLY_CAP);
        assertEq(router.reserveMinted(), 10);
    }

    function test_topUp_mintMismatch_mintsLess() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.MintLess);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.MintMismatch.selector);
        r.topUp{value: cost}(10);
    }

    function test_topUp_mintMismatch_mintsMore() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.MintMore);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.MintMismatch.selector);
        r.topUp{value: cost}(10);
    }

    function test_topUp_mintMismatch_mintsToSomeoneElse() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.MintToOther);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.MintMismatch.selector);
        r.topUp{value: cost}(10);
    }

    function test_topUp_mintMismatch_refundsOkb() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.ForceRefund);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.MintMismatch.selector);
        r.topUp{value: cost}(10);
        assertEq(address(r).balance, 0);
        assertEq(r.reserveMinted(), 0);
    }

    function test_topUp_misbehavingTransistors_wrongIdRejected() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.WrongId);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        r.topUp{value: cost}(10);
    }

    function test_topUp_misbehavingTransistors_transferInsteadOfMintRejected() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.TransferInstead);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        r.topUp{value: cost}(10);
    }

    function test_topUp_misbehavingTransistors_reenterDistributeBlocked() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.ReenterDistribute);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        r.topUp{value: cost}(10);
    }

    function test_topUp_misbehavingTransistors_reenterTopUpBlocked() public {
        (, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.ReenterTopUp);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        r.topUp{value: cost}(10);
    }

    /// @dev Positive control for the rt mock: in Normal mode the same router setup works.
    function test_topUp_badTransistorsNormalMode_works() public {
        (RtBadTransistors bad, CashbackRouter r) = _badSetup(RtBadTransistors.Mode.Normal);
        uint256 cost = r.topUpCost(10);
        vm.prank(keeper);
        r.topUp{value: cost}(10);
        assertEq(r.reserveMinted(), 10);
        assertEq(bad.balanceOf(address(r), 0), 10);
    }

    // ═════════════════════════════════════════════════════════════════════ inbound transfer rejection

    function test_inbound_safeTransferFromHolderReverts() public {
        _giveTransistors(bob, 10);
        vm.prank(bob);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeTransferFrom(bob, address(router), 0, 10, "");
        assertEq(_nand(bob), 10);
        assertEq(_nand(address(router)), 0);
    }

    function test_inbound_zeroAmountTransferReverts() public {
        vm.prank(bob);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeTransferFrom(bob, address(router), 0, 0, "");
    }

    function test_inbound_latchTransferReverts() public {
        uint256 cost = MINT_PRICE * 3 + PROTOCOL_FEE;
        vm.deal(bob, cost);
        vm.prank(bob);
        transistors.mint{value: cost}(1, 3);
        vm.prank(bob);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeTransferFrom(bob, address(router), 1, 3, "");
    }

    function test_inbound_batchTransferReverts() public {
        _giveTransistors(bob, 10);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5;
        vm.prank(bob);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeBatchTransferFrom(bob, address(router), ids, amounts, "");
    }

    function test_inbound_emptyBatchTransferReverts() public {
        vm.prank(bob);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeBatchTransferFrom(bob, address(router), new uint256[](0), new uint256[](0), "");
    }

    function test_inbound_operatorTransferReverts() public {
        _giveTransistors(bob, 10);
        vm.prank(bob);
        transistors.setApprovalForAll(carol, true);
        vm.prank(carol);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeTransferFrom(bob, address(router), 0, 10, "");
    }

    function test_inbound_keeperAndAdminCannotDonate() public {
        _giveTransistors(keeper, 5);
        _giveTransistors(admin, 5);
        vm.prank(keeper);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeTransferFrom(keeper, address(router), 0, 5, "");
        vm.prank(admin);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeTransferFrom(admin, address(router), 0, 5, "");
    }

    function test_inbound_rejectedEvenWhileReserveExists() public {
        _topUp(10);
        _giveTransistors(bob, 1);
        vm.prank(bob);
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        transistors.safeTransferFrom(bob, address(router), 0, 1, "");
        assertEq(_nand(address(router)), 10);
    }

    function test_onERC1155Received_directCallReverts() public {
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        router.onERC1155Received(address(this), address(this), 0, 1, "");
    }

    /// @dev Even with every argument looking like a genuine mint (sender = transistors, operator = router, from = 0,
    ///      id = NAND), it's rejected outside of topUp.
    function test_onERC1155Received_spoofedMintOutsideTopUpReverts() public {
        vm.prank(address(transistors));
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        router.onERC1155Received(address(router), address(0), 0, 5, "");
    }

    function test_onERC1155BatchReceived_directCallReverts() public {
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        router.onERC1155BatchReceived(address(this), address(this), new uint256[](0), new uint256[](0), "");
        vm.prank(address(transistors));
        vm.expectRevert(CashbackRouter.UnexpectedTransfer.selector);
        router.onERC1155BatchReceived(address(router), address(0), new uint256[](1), new uint256[](1), "");
    }

    // ═════════════════════════════════════════════════════════════════════ freeReserve / supportsInterface

    function test_freeReserve_tracksBalanceMinusPending() public {
        assertEq(router.freeReserve(), 0);
        _topUp(100);
        assertEq(router.freeReserve(), 100);
        _credit(_id("a"), alice, 30);
        assertEq(router.freeReserve(), 70);
        router.distribute(_ids(_id("a")));
        assertEq(router.freeReserve(), 70, "paying a credited order doesn't change free reserve");
        _credit(_id("b"), bob, 70);
        assertEq(router.freeReserve(), 0);
    }

    function test_freeReserve_zeroWhenPendingExceedsBalance() public {
        _topUp(10);
        _credit(_id("a"), alice, 25);
        assertEq(router.pendingUnits(), 25);
        assertEq(router.freeReserve(), 0);
        _topUp(20);
        assertEq(router.freeReserve(), 5);
    }

    function test_supportsInterface() public view {
        assertTrue(router.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(router.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(router.supportsInterface(type(IERC165).interfaceId));
        assertEq(type(IERC1155Receiver).interfaceId, bytes4(0x4e2312e0));
        assertEq(type(IAccessControl).interfaceId, bytes4(0x7965db0b));
        assertEq(type(IERC165).interfaceId, bytes4(0x01ffc9a7));
        assertFalse(router.supportsInterface(0xffffffff));
        assertFalse(router.supportsInterface(type(IERC1155).interfaceId), "router is not a token");
        assertFalse(router.supportsInterface(type(IERC20).interfaceId));
        assertFalse(router.supportsInterface(bytes4(0)));
    }

    // ═════════════════════════════════════════════════════════════════════ rescueERC20

    function test_rescueERC20_adminMovesToken() public {
        usdt0.mint(address(router), 123e6);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.ERC20Rescued(address(usdt0), treasury, 100e6);
        vm.prank(admin);
        router.rescueERC20(address(usdt0), treasury, 100e6);
        assertEq(usdt0.balanceOf(treasury), 100e6);
        assertEq(usdt0.balanceOf(address(router)), 23e6);
    }

    function test_rescueERC20_onlyAdmin() public {
        usdt0.mint(address(router), 1e6);
        address[5] memory callers = [alice, keeper, operator, address(gateway), anyone];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], DEFAULT_ADMIN));
            router.rescueERC20(address(usdt0), callers[i], 1e6);
        }
        assertEq(usdt0.balanceOf(address(router)), 1e6);
    }

    function test_rescueERC20_zeroToReverts() public {
        usdt0.mint(address(router), 1e6);
        vm.prank(admin);
        vm.expectRevert(CashbackRouter.ZeroAddress.selector);
        router.rescueERC20(address(usdt0), address(0), 1e6);
    }

    function test_rescueERC20_moreThanBalanceReverts() public {
        usdt0.mint(address(router), 1e6);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(router), 1e6, 1e6 + 1)
        );
        router.rescueERC20(address(usdt0), treasury, 1e6 + 1);
    }

    function test_rescueERC20_bubblesTokenError() public {
        usdt0.mint(address(router), 1e6);
        usdt0.setBlocked(treasury, true);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MockUSDT0.Blocked.selector, treasury));
        router.rescueERC20(address(usdt0), treasury, 1e6);
    }

    function test_rescueERC20_falseReturningTokenReverts() public {
        RtFalseERC20 t = new RtFalseERC20();
        t.mint(address(router), 10);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        router.rescueERC20(address(t), treasury, 10);
    }

    function test_rescueERC20_codelessTokenReverts() public {
        address eoa = makeAddr("eoaToken");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, eoa));
        router.rescueERC20(eoa, treasury, 1);
    }

    /// @dev Pointing rescueERC20 at the ERC-1155 transistor contract can't move transistors: ERC-1155 has no
    ///      transfer(address,uint256), so the call reverts (empty revert data) and the reserve is untouched.
    function test_rescueERC20_cannotMoveTransistors() public {
        _topUp(100);
        vm.prank(admin);
        (bool ok, bytes memory ret) =
            address(router).call(abi.encodeCall(CashbackRouter.rescueERC20, (address(transistors), admin, 1)));
        assertFalse(ok);
        assertEq(bytes4(ret), CashbackRouter.CannotRescueTransistors.selector);
        assertEq(_nand(address(router)), 100);
        assertEq(_nand(admin), 0);
    }

    // ═════════════════════════════════════════════════════════════════════ surface ("no-sell" guarantee)

    /// @dev The complete external ABI of CashbackRouter, from src/CashbackRouter.sol + OZ AccessControl.
    function _expectedSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](26);
        // own
        s[0] = bytes4(keccak256("KEEPER_ROLE()"));
        s[1] = bytes4(keccak256("NAND_ID()"));
        s[2] = bytes4(keccak256("MAX_RESERVE_DIVISOR()"));
        s[3] = bytes4(keccak256("TRANSFER_GAS_LIMIT()"));
        s[4] = bytes4(keccak256("gateway()"));
        s[5] = bytes4(keccak256("transistors()"));
        s[6] = bytes4(keccak256("maxReserveMint()"));
        s[7] = bytes4(keccak256("reserveMinted()"));
        s[8] = bytes4(keccak256("distributedUnits()"));
        s[9] = bytes4(keccak256("pendingUnits()"));
        s[10] = bytes4(keccak256("credits(bytes32)"));
        s[11] = CashbackRouter.credit.selector; // gateway-only, moves nothing
        s[12] = CashbackRouter.distribute.selector; // THE only outbound path for transistors
        s[13] = CashbackRouter.topUpCost.selector;
        s[14] = CashbackRouter.topUp.selector; // inbound only (mint)
        s[15] = CashbackRouter.freeReserve.selector;
        s[16] = CashbackRouter.onERC1155Received.selector; // rejects all but topUp mints
        s[17] = CashbackRouter.onERC1155BatchReceived.selector; // always reverts
        s[18] = CashbackRouter.supportsInterface.selector;
        s[19] = CashbackRouter.rescueERC20.selector; // ERC-20 only
        // AccessControl
        s[20] = IAccessControl.hasRole.selector;
        s[21] = IAccessControl.getRoleAdmin.selector;
        s[22] = IAccessControl.grantRole.selector;
        s[23] = IAccessControl.revokeRole.selector;
        s[24] = IAccessControl.renounceRole.selector;
        s[25] = bytes4(keccak256("DEFAULT_ADMIN_ROLE()"));
    }

    /// @dev Selectors that would let tokens leave other than via distribute (or that a "sell" path would need).
    function _bannedSelectors() internal pure returns (bytes4[] memory b) {
        b = new bytes4[](18);
        b[0] = IERC1155.setApprovalForAll.selector; // 0xa22cb465
        b[1] = IERC1155.safeTransferFrom.selector; // 0xf242432a (as a router *entry point*)
        b[2] = IERC1155.safeBatchTransferFrom.selector; // 0x2eb2c2d6
        b[3] = IERC20.transfer.selector;
        b[4] = IERC20.transferFrom.selector;
        b[5] = IERC20.approve.selector;
        b[6] = bytes4(keccak256("withdraw()"));
        b[7] = bytes4(keccak256("withdraw(uint256)"));
        b[8] = bytes4(keccak256("withdraw(address,uint256)"));
        b[9] = bytes4(keccak256("sell(uint256)"));
        b[10] = bytes4(keccak256("swap(uint256,uint256)"));
        b[11] = bytes4(keccak256("burn(address,uint256,uint256)"));
        b[12] = bytes4(keccak256("execute(address,uint256,bytes)"));
        b[13] = bytes4(keccak256("multicall(bytes[])"));
        b[14] = bytes4(keccak256("sweep(address)"));
        b[15] = bytes4(keccak256("rescueERC1155(address,address,uint256,uint256)"));
        b[16] = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
        b[17] = bytes4(keccak256("tapeout(bytes,uint32,uint32)"));
    }

    function _readUint(bytes memory code, uint256 at, uint256 size) internal pure returns (uint256 v) {
        for (uint256 k; k < size; ++k) {
            v = (v << 8) | uint8(code[at + k]);
        }
    }

    /// @dev Extract function selectors from the solc dispatcher: DUP1 PUSH{1..4} sel EQ PUSH{1..3} dest JUMPI.
    function _dispatcherSelectors(bytes memory code) internal pure returns (bytes4[] memory out) {
        bytes4[] memory tmp = new bytes4[](128);
        uint256 n;
        uint256 len = code.length;
        uint256 i;
        while (i < len) {
            uint8 op = uint8(code[i]);
            if (op == 0x80 && i + 1 < len) {
                uint8 p = uint8(code[i + 1]);
                if (p >= 0x60 && p <= 0x63) {
                    uint256 sz = uint256(p) - 0x5f;
                    uint256 k = i + 2 + sz;
                    if (k + 1 < len && uint8(code[k]) == 0x14) {
                        uint8 p2 = uint8(code[k + 1]);
                        if (p2 >= 0x60 && p2 <= 0x62) {
                            uint256 j = k + 2 + (uint256(p2) - 0x5f);
                            if (j < len && uint8(code[j]) == 0x57 && n < tmp.length) {
                                tmp[n++] = bytes4(uint32(_readUint(code, i + 2, sz)));
                            }
                        }
                    }
                }
            }
            if (op >= 0x60 && op <= 0x7f) i += 1 + (uint256(op) - 0x5f);
            else ++i;
        }
        out = new bytes4[](n);
        for (uint256 k; k < n; ++k) {
            out[k] = tmp[k];
        }
    }

    /// @dev True if `sel` appears anywhere in the code as a PUSH4 constant or a left-aligned PUSH32 constant
    ///      (the two ways solc materialises a selector for an outgoing call).
    function _referencesSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        uint256 len = code.length;
        uint256 i;
        while (i < len) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                uint256 sz = uint256(op) - 0x5f;
                if (i + sz < len) {
                    if (sz == 4 && bytes4(uint32(_readUint(code, i + 1, 4))) == sel) return true;
                    if (sz == 32) {
                        uint256 v = _readUint(code, i + 1, 32);
                        if (bytes4(bytes32(v)) == sel && (v << 32) == 0) return true;
                    }
                }
                i += 1 + sz;
            } else {
                ++i;
            }
        }
        return false;
    }

    function _contains(bytes4[] memory arr, bytes4 x) internal pure returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == x) return true;
        }
        return false;
    }

    /// @notice The router's external surface is EXACTLY the 26 functions above; there is no fallback/receive.
    function test_surface_dispatcherHasExactlyTheKnownSelectors() public view {
        bytes4[] memory found = _dispatcherSelectors(address(router).code);
        bytes4[] memory expected = _expectedSelectors();
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(_contains(found, expected[i]), string.concat("missing ", vm.toString(abi.encode(expected[i]))));
        }
        for (uint256 i; i < found.length; ++i) {
            assertTrue(
                _contains(expected, found[i]), string.concat("unexpected selector ", vm.toString(abi.encode(found[i])))
            );
        }
        assertEq(found.length, expected.length, "no duplicates / extras");
        bytes4[] memory banned = _bannedSelectors();
        for (uint256 i; i < banned.length; ++i) {
            assertFalse(_contains(found, banned[i]), "banned entry point present");
        }
    }

    /// @notice The router's bytecode never even encodes a call to setApprovalForAll, safeBatchTransferFrom, burn or
    ///         tapeout, so no code path can approve an operator or move/burn transistors except distribute's
    ///         safeTransferFrom (and topUp's mint, which only brings tokens in).
    function test_surface_bytecodeNeverEncodesApprovalOrOtherMoves() public view {
        bytes memory code = address(router).code;
        // positive controls (prove the scanner works on this bytecode)
        assertTrue(_referencesSelector(code, IERC1155.safeTransferFrom.selector), "distribute's transfer");
        assertTrue(_referencesSelector(code, bytes4(keccak256("mint(uint256,uint256)"))), "topUp's mint");
        assertTrue(_referencesSelector(code, IERC20.transfer.selector), "rescueERC20's ERC-20 transfer");
        // negatives
        assertFalse(_referencesSelector(code, IERC1155.setApprovalForAll.selector), "setApprovalForAll");
        assertFalse(_referencesSelector(code, IERC1155.safeBatchTransferFrom.selector), "safeBatchTransferFrom");
        assertFalse(_referencesSelector(code, bytes4(keccak256("burn(address,uint256,uint256)"))), "burn");
        assertFalse(_referencesSelector(code, bytes4(keccak256("burnFrom(address,uint256,uint256)"))), "burnFrom");
        assertFalse(_referencesSelector(code, bytes4(keccak256("tapeout(bytes,uint32,uint32)"))), "tapeout");
        assertFalse(_referencesSelector(code, IERC20.approve.selector), "approve");
        assertFalse(_referencesSelector(code, IERC20.transferFrom.selector), "transferFrom");
    }

    /// @notice Calling token-moving selectors on the router reverts with no data: the functions don't exist and there
    ///         is no fallback. Done as admin and keeper (the most privileged accounts), with a funded reserve.
    function test_surface_bannedSelectorsRevertBecauseTheyDontExist() public {
        _topUp(100);
        _credit(_id("a"), alice, 5);
        bytes[] memory calls = new bytes[](16);
        calls[0] = abi.encodeCall(IERC1155.setApprovalForAll, (admin, true));
        calls[1] = abi.encodeCall(IERC1155.safeTransferFrom, (address(router), admin, 0, 100, ""));
        calls[2] = abi.encodeCall(
            IERC1155.safeBatchTransferFrom, (address(router), admin, new uint256[](1), new uint256[](1), "")
        );
        calls[3] = abi.encodeCall(IERC20.transfer, (admin, 100));
        calls[4] = abi.encodeCall(IERC20.transferFrom, (address(router), admin, 100));
        calls[5] = abi.encodeCall(IERC20.approve, (admin, 100));
        calls[6] = abi.encodeWithSignature("withdraw()");
        calls[7] = abi.encodeWithSignature("withdraw(uint256)", 100);
        calls[8] = abi.encodeWithSignature("withdraw(address,uint256)", admin, 100);
        calls[9] = abi.encodeWithSignature("sell(uint256)", 100);
        calls[10] = abi.encodeWithSignature("swap(uint256,uint256)", 100, 0);
        calls[11] = abi.encodeWithSignature("burn(address,uint256,uint256)", address(router), 0, 100);
        calls[12] = abi.encodeWithSignature("execute(address,uint256,bytes)", address(transistors), 0, "");
        calls[13] = abi.encodeWithSignature("sweep(address)", address(transistors));
        calls[14] = abi.encodeWithSignature(
            "rescueERC1155(address,address,uint256,uint256)", address(transistors), admin, 0, 100
        );
        calls[15] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0xdead), "");

        address[2] memory callers = [admin, keeper];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok, bytes memory ret) = address(router).call(calls[i]);
                assertFalse(ok, "call must fail");
                assertEq(ret.length, 0, "no such function: empty revert");
            }
        }
        assertEq(_nand(address(router)), 100);
        assertEq(_nand(admin), 0);
        assertEq(_nand(keeper), 0);
        assertFalse(transistors.isApprovedForAll(address(router), admin));
        assertFalse(transistors.isApprovedForAll(address(router), keeper));
    }

    function test_surface_noReceiveOrFallback() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(router).call{value: 1}("");
        assertFalse(ok);
        assertEq(ret.length, 0);
        vm.prank(alice);
        (ok, ret) = address(router).call(hex"deadbeef");
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    /// @notice The router never grants any operator approval over its transistors during a full lifecycle.
    function test_surface_lifecycleNeverApprovesOperators() public {
        _topUp(100);
        _credit(_id("a"), alice, 5);
        router.distribute(_ids(_id("a")));
        usdt0.mint(address(router), 1);
        vm.prank(admin);
        router.rescueERC20(address(usdt0), admin, 1);
        address[7] memory who = [admin, keeper, operator, address(gateway), alice, address(processor), creator];
        for (uint256 i; i < who.length; ++i) {
            assertFalse(transistors.isApprovedForAll(address(router), who[i]));
        }
        // only distribute moved tokens out: minted - distributed == held
        assertEq(router.reserveMinted() - router.distributedUnits(), _nand(address(router)));
    }

    // ═════════════════════════════════════════════════════════════════════ integration with the gateway

    function test_integration_markFulfilled_credit_distribute() public {
        _topUp(1_000);
        PayLightGateway.Quote memory q = _quote(alice, 3_300_000, 5);
        _pay(q);
        assertEq(router.pendingUnits(), 0, "nothing credited at payment time");

        bytes32 receipt = keccak256("vtpass-tx");
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackCredited(q.orderId, alice, 5);
        vm.expectEmit(true, false, false, true, address(gateway));
        emit PayLightGateway.OrderFulfilled(q.orderId, receipt, 5, true);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, receipt);

        assertTrue(gateway.getOrder(q.orderId).cashbackCredited);
        (address p, uint32 u, bool isPaid) = router.credits(q.orderId);
        assertEq(p, alice);
        assertEq(u, 5);
        assertFalse(isPaid);
        assertEq(router.pendingUnits(), 5);

        vm.prank(anyone);
        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackPaid(q.orderId, alice, 5);
        assertEq(router.distribute(_ids(q.orderId)), 1);
        assertEq(_nand(alice), 5);
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distributedUnits(), 5);
    }

    function test_integration_gatewayPauseDoesNotStopDistribute() public {
        _topUp(1_000);
        PayLightGateway.Quote memory q = _quote(alice, 5e6, 7);
        _pay(q);

        vm.prank(admin);
        gateway.pause();
        assertTrue(gateway.paused());

        // new payments are blocked ...
        PayLightGateway.Quote memory q2 = _quote(bob, 5e6, 1);
        bytes memory sig2 = _sign(q2);
        vm.startPrank(bob);
        usdt0.approve(address(gateway), _total(q2));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.pay(q2, sig2);
        vm.stopPrank();

        // ... but settlement credits cashback and distribution still pays out
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, keccak256("r"));
        assertEq(router.pendingUnits(), 7);
        assertEq(router.distribute(_ids(q.orderId)), 1);
        assertEq(_nand(alice), 7);

        // and the keeper can still top up while the gateway is paused
        _topUp(10);
        assertEq(router.reserveMinted(), 1_010);
    }

    function test_integration_refundedOrderIsNeverCredited() public {
        _topUp(100);
        PayLightGateway.Quote memory q = _quote(alice, 5e6, 7);
        _pay(q);
        vm.prank(operator);
        gateway.refund(q.orderId);
        (address p,,) = router.credits(q.orderId);
        assertEq(p, address(0));
        assertEq(router.distribute(_ids(q.orderId)), 0);
        assertEq(_nand(alice), 0);
    }

    function test_integration_selfRefundedOrderIsNeverCredited() public {
        _topUp(100);
        PayLightGateway.Quote memory q = _quote(alice, 5e6, 7);
        _pay(q);
        vm.warp(block.timestamp + REFUND_TIMEOUT + 1);
        vm.prank(alice);
        gateway.claimRefund(q.orderId);
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distribute(_ids(q.orderId)), 0);
    }

    function test_integration_zeroCashbackOrderNotCredited() public {
        _topUp(100);
        PayLightGateway.Quote memory q = _quote(alice, 5e6, 0);
        _pay(q);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, keccak256("r"));
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);
        (address p,,) = router.credits(q.orderId);
        assertEq(p, address(0));
        assertEq(router.pendingUnits(), 0);
    }

    function test_integration_settleBeforeReserve_thenTopUpAndDistribute() public {
        PayLightGateway.Quote memory q = _quote(alice, 5e6, 9);
        _pay(q);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, keccak256("r"));
        assertEq(usdt0.balanceOf(treasury), _total(q), "settlement not blocked by empty reserve");

        vm.expectEmit(true, true, false, true, address(router));
        emit CashbackRouter.CashbackDeferred(q.orderId, alice, 9, true);
        assertEq(router.distribute(_ids(q.orderId)), 0);

        _topUp(9);
        assertEq(router.distribute(_ids(q.orderId)), 1);
        assertEq(_nand(alice), 9);
    }

    /// @dev Cashback feeds the FeeTier circuit: 50 NAND of cashback lifts alice to tier 1.
    function test_integration_cashbackLiftsFeeTier() public {
        _topUp(1_000);
        assertEq(gateway.computeTier(alice), 0);
        PayLightGateway.Quote memory q = _quote(alice, 20e6, 50);
        _pay(q);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, keccak256("r"));
        router.distribute(_ids(q.orderId));
        assertEq(_nand(alice), TIER1_HOLDING);
        assertEq(gateway.computeTier(alice), 1);
    }

    function test_integration_batchAcrossPayers() public {
        _topUp(1_000);
        PayLightGateway.Quote memory qa = _quote(alice, 4e6, 4);
        _pay(qa);
        PayLightGateway.Quote memory qb = _quote(bob, 6e6, 6);
        _pay(qb);
        vm.startPrank(operator);
        gateway.markFulfilled(qa.orderId, keccak256("a"));
        gateway.markFulfilled(qb.orderId, keccak256("b"));
        vm.stopPrank();
        assertEq(router.pendingUnits(), 10);
        assertEq(router.distribute(_ids(qa.orderId, qb.orderId)), 2);
        assertEq(_nand(alice), 4);
        assertEq(_nand(bob), 6);
    }

    /// @dev A router that rejects credits (wrong gateway) never blocks settlement; the operator can retry the credit
    ///      once the right router is set, and the router then pays.
    function test_integration_creditFailureDoesNotBlockSettlement_retryWorks() public {
        CashbackRouter wrong =
            new CashbackRouter(makeAddr("otherGateway"), address(transistors), admin, keeper, MAX_RESERVE);
        vm.prank(admin);
        gateway.setCashbackRouter(address(wrong));

        PayLightGateway.Quote memory q = _quote(alice, 5e6, 3);
        _pay(q);
        vm.prank(operator);
        gateway.markFulfilled(q.orderId, keccak256("r"));
        assertEq(uint8(gateway.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Fulfilled));
        assertFalse(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(wrong.pendingUnits(), 0);

        vm.prank(admin);
        gateway.setCashbackRouter(address(router));
        vm.prank(operator);
        gateway.retryCashbackCredit(q.orderId);
        assertTrue(gateway.getOrder(q.orderId).cashbackCredited);
        assertEq(router.pendingUnits(), 3);

        _topUp(3);
        assertEq(router.distribute(_ids(q.orderId)), 1);
        assertEq(_nand(alice), 3);
    }

    // ═════════════════════════════════════════════════════════════════════ fuzz: conservation + greedy model

    function testFuzz_distribute_matchesGreedyModel(uint32[8] memory rawUnits, uint256 reserve, uint8 order) public {
        reserve = bound(reserve, 0, 400);
        if (reserve > 0) _topUp(reserve);

        bytes32[] memory ids = new bytes32[](8);
        address[] memory payers = new address[](8);
        uint32[] memory units = new uint32[](8);
        uint256 totalCredited;
        for (uint256 i; i < 8; ++i) {
            units[i] = uint32(bound(rawUnits[i], 1, 50));
            payers[i] = address(uint160(uint256(keccak256(abi.encode("payer", i)))));
            ids[i] = _id(string.concat("fz", vm.toString(i)));
            _credit(ids[i], payers[i], units[i]);
            totalCredited += units[i];
        }
        // rotate the batch order
        uint256 rot = order % 8;
        bytes32[] memory batch = new bytes32[](8);
        for (uint256 i; i < 8; ++i) {
            batch[i] = ids[(i + rot) % 8];
        }

        // model
        uint256 available = reserve;
        uint256 expectedPaid;
        uint256 expectedUnits;
        bool[] memory shouldPay = new bool[](8);
        for (uint256 i; i < 8; ++i) {
            uint256 k = (i + rot) % 8;
            if (units[k] <= available) {
                available -= units[k];
                shouldPay[k] = true;
                ++expectedPaid;
                expectedUnits += units[k];
            }
        }

        vm.prank(anyone);
        assertEq(router.distribute(batch), expectedPaid);
        for (uint256 k; k < 8; ++k) {
            assertEq(_nand(payers[k]), shouldPay[k] ? units[k] : 0);
            assertEq(_paid(ids[k]), shouldPay[k]);
        }
        assertEq(router.distributedUnits(), expectedUnits);
        assertEq(router.pendingUnits() + router.distributedUnits(), totalCredited);
        assertEq(_nand(address(router)) + router.distributedUnits(), router.reserveMinted());
        assertEq(router.reserveMinted(), reserve);

        // second pass after topping up everything: all remaining get paid, totals conserve
        _topUp(totalCredited);
        router.distribute(batch);
        assertEq(router.pendingUnits(), 0);
        assertEq(router.distributedUnits(), totalCredited);
        assertEq(_nand(address(router)) + router.distributedUnits(), router.reserveMinted());
    }
}
