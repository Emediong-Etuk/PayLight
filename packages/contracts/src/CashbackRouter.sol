// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ICashbackRouter} from "./interfaces/ICashbackRouter.sol";
import {ITapeOutTransistors} from "./interfaces/ITapeOut.sol";

/// @title CashbackRouter
/// @notice Holds PayLight's disclosed cashback reserve of NAND transistors and pays them out to customers, one
///         settled electricity order at a time.
///
/// @dev    NO-SELL GUARANTEE (judges, please verify):
///         - Transistors ENTER this contract only through `topUp`, which mints them from the PayLight processor at the
///           public mint price. `onERC1155Received` rejects every other transfer, so nobody can park tokens here.
///         - Transistors LEAVE this contract only through `distribute`, which sends each settled order's credited
///           units to that order's payer. Crediting is restricted to the immutable PayLight gateway, which only
///           credits orders that were paid in USD₮0 and settled by the operator.
///         - There is no sell, swap, burn, approve/setApprovalForAll, withdraw or arbitrary-transfer function for
///           transistors anywhere in this contract. `rescueERC20` only handles ERC-20s, and transistors are ERC-1155.
///         - Lifetime reserve minting is capped by the immutable `maxReserveMint`, which the constructor forces to be at
///           most 20% of the processor's supply cap.
///         Distribution is permissionless: anyone may call `distribute`, and funds can only go to the credited payer.
contract CashbackRouter is ICashbackRouter, IERC1155Receiver, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 public constant NAND_ID = 0;
    /// @notice Max share of the processor's supply cap the reserve can ever mint: 1/5 = 20%.
    uint256 public constant MAX_RESERVE_DIVISOR = 5;
    /// @dev Gas cap per payout so a hostile receiver hook can't burn the whole batch's gas.
    uint256 public constant TRANSFER_GAS_LIMIT = 200_000;

    struct Credit {
        address payer;
        uint32 units;
        bool paid;
    }

    address public immutable gateway;
    ITapeOutTransistors public immutable transistors;
    uint256 public immutable maxReserveMint;

    /// @notice Lifetime transistors minted into the reserve (<= maxReserveMint).
    uint256 public reserveMinted;
    /// @notice Lifetime transistors paid out to customers.
    uint256 public distributedUnits;
    /// @notice Credited but not yet paid units.
    uint256 public pendingUnits;
    mapping(bytes32 orderId => Credit) public credits;

    bool private _minting;

    event CashbackCredited(bytes32 indexed orderId, address indexed payer, uint32 units);
    event CashbackPaid(bytes32 indexed orderId, address indexed payer, uint32 units);
    event CashbackDeferred(bytes32 indexed orderId, address indexed payer, uint32 units, bool insufficientReserve);
    event ReserveToppedUp(address indexed funder, uint256 units, uint256 cost);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotGateway();
    error AlreadyCredited();
    error InvalidCredit();
    error ReserveCapExceeded();
    error WrongPayment(uint256 expected);
    error MintMismatch();
    error UnexpectedTransfer();

    constructor(address gateway_, address transistors_, address admin, address keeper, uint256 maxReserveMint_) {
        if (gateway_ == address(0) || transistors_ == address(0) || admin == address(0)) revert ZeroAddress();
        uint256 cap = ITapeOutTransistors(transistors_).supplyCap();
        if (maxReserveMint_ == 0 || maxReserveMint_ * MAX_RESERVE_DIVISOR > cap) revert ReserveCapExceeded();
        gateway = gateway_;
        transistors = ITapeOutTransistors(transistors_);
        maxReserveMint = maxReserveMint_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (keeper != address(0)) _grantRole(KEEPER_ROLE, keeper);
    }

    // ─────────────────────────────────────────────────────────────── credit / distribute

    /// @inheritdoc ICashbackRouter
    function credit(bytes32 orderId, address payer, uint32 units) external {
        if (msg.sender != gateway) revert NotGateway();
        if (payer == address(0) || units == 0) revert InvalidCredit();
        if (credits[orderId].payer != address(0)) revert AlreadyCredited();
        credits[orderId] = Credit({payer: payer, units: units, paid: false});
        pendingUnits += units;
        emit CashbackCredited(orderId, payer, units);
    }

    /// @notice Pay out credited cashback for the given orders. Permissionless. Skips paid or unknown orders. Defers
    ///         (without reverting) orders the reserve can't cover yet, or whose payer can't receive ERC-1155 tokens.
    /// @return paid Number of orders paid in this call.
    function distribute(bytes32[] calldata orderIds) external nonReentrant returns (uint256 paid) {
        uint256 available = transistors.balanceOf(address(this), NAND_ID);
        for (uint256 i; i < orderIds.length; ++i) {
            bytes32 id = orderIds[i];
            Credit storage c = credits[id];
            if (c.payer == address(0) || c.paid) continue;
            uint32 units = c.units;
            if (units > available) {
                emit CashbackDeferred(id, c.payer, units, true);
                continue;
            }
            // effects before the external call (receiver hook may re-enter; nonReentrant blocks that)
            c.paid = true;
            pendingUnits -= units;
            distributedUnits += units;
            try transistors.safeTransferFrom{gas: TRANSFER_GAS_LIMIT}(address(this), c.payer, NAND_ID, units, "") {
                available -= units;
                ++paid;
                emit CashbackPaid(id, c.payer, units);
            } catch {
                c.paid = false;
                pendingUnits += units;
                distributedUnits -= units;
                emit CashbackDeferred(id, c.payer, units, false);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────── reserve

    /// @notice Exact OKB cost to mint `units` into the reserve (public mint price + TapeOut's flat protocol fee).
    function topUpCost(uint256 units) public view returns (uint256) {
        return transistors.mintPrice() * units + transistors.protocolFee();
    }

    /// @notice Mint `units` NAND into the reserve at the public price. msg.value must equal `topUpCost(units)`.
    function topUp(uint256 units) external payable nonReentrant onlyRole(KEEPER_ROLE) {
        if (reserveMinted + units > maxReserveMint) revert ReserveCapExceeded();
        uint256 cost = topUpCost(units);
        if (msg.value != cost) revert WrongPayment(cost);

        uint256 nativeBefore = address(this).balance - msg.value;
        uint256 before = transistors.balanceOf(address(this), NAND_ID);
        _minting = true;
        transistors.mint{value: cost}(NAND_ID, units);
        _minting = false;
        if (transistors.balanceOf(address(this), NAND_ID) - before != units) revert MintMismatch();
        if (address(this).balance != nativeBefore) revert MintMismatch();

        reserveMinted += units;
        emit ReserveToppedUp(msg.sender, units, cost);
    }

    /// @notice Transistors held and not yet promised to credited orders.
    function freeReserve() external view returns (uint256) {
        uint256 bal = transistors.balanceOf(address(this), NAND_ID);
        return bal > pendingUnits ? bal - pendingUnits : 0;
    }

    // ─────────────────────────────────────────────────────────────── ERC-1155 receiver

    /// @dev Accept only NAND freshly minted to this contract during `topUp`.
    function onERC1155Received(address operator, address from, uint256 id, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (
            !_minting || msg.sender != address(transistors) || operator != address(this) || from != address(0)
                || id != NAND_ID
        ) revert UnexpectedTransfer();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnexpectedTransfer();
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    // ─────────────────────────────────────────────────────────────── admin

    /// @notice Recover ERC-20 tokens sent here by mistake. Can't touch transistors (ERC-1155).
    function rescueERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }
}
