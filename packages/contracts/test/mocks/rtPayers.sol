// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @notice Hostile / unusual cashback payers used by test/CashbackRouter.t.sol.

interface IRtDistribute {
    function distribute(bytes32[] calldata orderIds) external returns (uint256);
}

/// @dev A contract that does not implement IERC1155Receiver at all (no fallback either).
contract RtNonReceiver {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Accepts ERC-1155 only if `accepting` is true; otherwise its hook reverts with a reason.
contract RtTogglePayer is IERC1155Receiver {
    bool public accepting;

    error NotAccepting();

    function setAccepting(bool a) external {
        accepting = a;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (!accepting) revert NotAccepting();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (!accepting) revert NotAccepting();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }
}

/// @dev Hook burns every unit of gas it is given.
contract RtGasBurner is IERC1155Receiver {
    uint256 public sink;

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        uint256 x;
        while (true) {
            unchecked {
                ++x;
            }
            sink = x;
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }
}

/// @dev Hook returns the wrong magic value.
contract RtWrongMagicPayer is IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xdeadbeef;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }
}

/// @dev Hook re-enters `router.distribute(ids)`.
///      bubble = true : the inner revert is propagated, so the outer transfer fails.
///      bubble = false: the inner revert is caught and recorded, and the transfer is accepted.
contract RtReentrantPayer is IERC1155Receiver {
    IRtDistribute public immutable router;
    bool public bubble;
    bytes32[] internal _ids;

    uint256 public attempts;
    bool public innerSucceeded;
    bytes public lastError;

    constructor(address router_) {
        router = IRtDistribute(router_);
    }

    function configure(bytes32[] calldata ids, bool bubble_) external {
        _ids = ids;
        bubble = bubble_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (bubble) {
            router.distribute(_ids); // reverts -> bubbles
        } else {
            attempts += 1;
            try router.distribute(_ids) {
                innerSucceeded = true;
            } catch (bytes memory err) {
                lastError = err;
            }
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }
}

/// @dev Hook immediately tries to send the received tokens back to the router (the reserve).
contract RtBouncePayer is IERC1155Receiver {
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    function onERC1155Received(address, address, uint256 id, uint256 value, bytes calldata)
        external
        returns (bytes4)
    {
        IERC1155(msg.sender).safeTransferFrom(address(this), router, id, value, "");
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }
}

/// @dev Simple ERC20 that returns false instead of reverting (for SafeERC20 paths in rescueERC20).
contract RtFalseERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
