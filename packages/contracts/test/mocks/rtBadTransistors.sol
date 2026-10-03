// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

interface IRtRouter {
    function distribute(bytes32[] calldata orderIds) external returns (uint256);
    function topUp(uint256 units) external payable;
}

/// @dev Sends its whole balance to `to` via SELFDESTRUCT in the constructor (works on cancun because the contract is
///      created and destroyed in the same transaction). Forces native OKB into contracts without a receive function.
contract RtForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @notice A misbehaving (e.g. maliciously upgraded) TapeOut transistor contract, used to exercise CashbackRouter's
///         post-mint checks in `topUp`. Same external surface as the real/mock transistors.
contract RtBadTransistors is ERC1155 {
    enum Mode {
        Normal,
        MintLess, // mints amount - 1
        MintMore, // mints amount + 1
        MintToOther, // mints to a third party
        ForceRefund, // mints correctly but pushes 1 wei of OKB back to the caller
        WrongId, // mints LATCH (id 1) instead of NAND
        TransferInstead, // transfers pre-minted stock (from != 0) instead of minting
        ReenterDistribute, // re-enters router.distribute during mint
        ReenterTopUp // re-enters router.topUp during mint
    }

    uint256 public immutable supplyCap;
    uint256 public immutable mintPrice;
    uint256 public immutable protocolFee;
    address public immutable creator;
    uint256 public minted;
    Mode public mode;
    address public router;
    address public constant OTHER = address(0xBEEF);

    error Insufficient();

    constructor(uint256 supplyCap_, uint256 mintPrice_, uint256 protocolFee_, address creator_) ERC1155("") {
        supplyCap = supplyCap_;
        mintPrice = mintPrice_;
        protocolFee = protocolFee_;
        creator = creator_;
        _mint(address(this), 0, 1_000_000, ""); // stock for TransferInstead (address(this) is not a contract yet)
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setRouter(address r) external {
        router = r;
    }

    function mint(uint256 id, uint256 amount) external payable {
        if (msg.value < mintPrice * amount + protocolFee) revert Insufficient();
        minted += amount;
        Mode m = mode;
        if (m == Mode.MintLess) {
            _mint(msg.sender, id, amount - 1, "");
        } else if (m == Mode.MintMore) {
            _mint(msg.sender, id, amount + 1, "");
        } else if (m == Mode.MintToOther) {
            _mint(OTHER, id, amount, "");
        } else if (m == Mode.ForceRefund) {
            _mint(msg.sender, id, amount, "");
            new RtForceSend{value: 1}(payable(msg.sender));
        } else if (m == Mode.WrongId) {
            _mint(msg.sender, 1, amount, "");
        } else if (m == Mode.TransferInstead) {
            _safeTransferFrom(address(this), msg.sender, id, amount, "");
        } else if (m == Mode.ReenterDistribute) {
            IRtRouter(router).distribute(new bytes32[](0));
            _mint(msg.sender, id, amount, "");
        } else if (m == Mode.ReenterTopUp) {
            IRtRouter(router).topUp{value: 0}(0);
            _mint(msg.sender, id, amount, "");
        } else {
            _mint(msg.sender, id, amount, "");
        }
    }
}
