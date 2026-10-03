// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @notice Test double for a TapeOut transistor contract: ERC-1155 (NAND 0, LATCH 1) with a fixed native-price mint
///         to msg.sender, a lifetime `minted` counter against `supplyCap`, and a flat protocol fee per mint call.
contract MockTransistors is ERC1155 {
    uint256 public constant NAND = 0;
    uint256 public constant LATCH = 1;

    uint256 public immutable supplyCap;
    uint256 public immutable mintPrice;
    uint256 public immutable protocolFee;
    address public immutable creator;
    address public processor;
    uint256 public minted;
    mapping(address => uint256) public owed;

    error Insufficient();
    error SoldOut();
    error BadId();
    error OnlyProcessor();

    constructor(uint256 supplyCap_, uint256 mintPrice_, uint256 protocolFee_, address creator_) ERC1155("") {
        supplyCap = supplyCap_;
        mintPrice = mintPrice_;
        protocolFee = protocolFee_;
        creator = creator_;
    }

    function setProcessor(address p) external {
        require(processor == address(0), "set");
        processor = p;
    }

    function mint(uint256 id, uint256 amount) external payable {
        if (id > LATCH) revert BadId();
        if (msg.value < mintPrice * amount + protocolFee) revert Insufficient();
        if (minted + amount > supplyCap) revert SoldOut();
        minted += amount;
        owed[creator] += mintPrice * amount;
        _mint(msg.sender, id, amount, "");
    }

    function burnFrom(address from, uint256 id, uint256 amount) external {
        if (msg.sender != processor) revert OnlyProcessor();
        _burn(from, id, amount);
    }
}

/// @notice Test double for a TapeOut processor that really interprets NAND/LATCH netlists (combinational only),
///         using TapeOut's encoding: NAND = 0x00 ++ u24 a ++ u24 b; LATCH = 0x01 ++ u24 a (reads its held bit, 0).
///         Signals 0/1 are constants, then inputs, then one signal per element; outputs are the last nOutputs signals;
///         input/output bytes are bit-packed LSB first. `mode` lets tests simulate a misbehaving / upgraded TapeOut.
contract MockProcessor {
    enum Mode {
        Normal,
        Revert,
        Empty,
        BadOffset,
        Tier3,
        GasBomb,
        HugeReturn,
        ShortReturn
    }

    struct Circuit {
        bytes netlist;
        uint32 nInputs;
        uint32 nOutputs;
        address owner;
    }

    MockTransistors public immutable transistorsContract;
    uint256 public constant TAPEOUT_FEE = 1.3e15;
    uint256 public nextId;
    Mode public mode;
    mapping(uint256 => Circuit) internal _circuits;

    constructor(MockTransistors t) {
        transistorsContract = t;
    }

    function transistors() external view returns (address) {
        return address(transistorsContract);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function tapeout(bytes calldata netlist, uint32 nInputs, uint32 nOutputs) external payable {
        require(msg.value >= TAPEOUT_FEE, "fee");
        (uint256 nands, uint256 latches) = _count(netlist);
        if (nands > 0) transistorsContract.burnFrom(msg.sender, 0, nands);
        if (latches > 0) transistorsContract.burnFrom(msg.sender, 1, latches);
        nextId += 1;
        _circuits[nextId] = Circuit(netlist, nInputs, nOutputs, msg.sender);
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _circuits[id].owner;
    }

    function eval(uint256 id, bytes calldata input) external view returns (bytes memory out) {
        Mode m = mode;
        if (m == Mode.Revert) revert("no circuit");
        if (m == Mode.Empty) return "";
        if (m == Mode.Tier3) return hex"03";
        if (m == Mode.GasBomb) {
            uint256 x;
            while (true) {
                x++;
            }
        }
        if (m == Mode.HugeReturn) {
            assembly {
                return(0, 100000)
            }
        }
        if (m == Mode.BadOffset) {
            assembly {
                mstore(0, 0x40)
                mstore(0x20, 1)
                mstore(0x40, shl(248, 2))
                return(0, 0x60)
            }
        }
        if (m == Mode.ShortReturn) {
            assembly {
                mstore(0, 0x20)
                return(0, 0x20)
            }
        }
        Circuit storage c = _circuits[id];
        require(c.owner != address(0), "no circuit");
        out = _evaluate(c.netlist, c.nInputs, c.nOutputs, input);
    }

    function _count(bytes calldata netlist) internal pure returns (uint256 nands, uint256 latches) {
        uint256 i;
        while (i < netlist.length) {
            uint8 op = uint8(netlist[i]);
            if (op == 0) {
                nands++;
                i += 7;
            } else if (op == 1) {
                latches++;
                i += 4;
            } else {
                revert("op");
            }
        }
    }

    function _evaluate(bytes memory netlist, uint32 nInputs, uint32 nOutputs, bytes calldata input)
        internal
        pure
        returns (bytes memory out)
    {
        bool[] memory sig = new bool[](2 + nInputs + netlist.length); // upper bound on signal count
        sig[1] = true;
        for (uint256 k; k < nInputs; ++k) {
            uint256 byteIdx = k / 8;
            sig[2 + k] = byteIdx < input.length && (uint8(input[byteIdx]) >> (k % 8)) & 1 == 1;
        }
        uint256 n = 2 + nInputs;
        uint256 i;
        while (i < netlist.length) {
            uint8 op = uint8(netlist[i]);
            if (op == 0) {
                uint256 a = _u24(netlist, i + 1);
                uint256 b = _u24(netlist, i + 4);
                require(a < n && b < n, "operand");
                sig[n++] = !(sig[a] && sig[b]);
                i += 7;
            } else {
                // LATCH presents its held bit (always 0 in this stateless mock)
                sig[n++] = false;
                i += 4;
            }
        }
        out = new bytes((nOutputs + 7) / 8);
        for (uint256 k; k < nOutputs; ++k) {
            if (sig[n - nOutputs + k]) out[k / 8] = bytes1(uint8(out[k / 8]) | uint8(1 << (k % 8)));
        }
    }

    function _u24(bytes memory b, uint256 at) internal pure returns (uint256) {
        return (uint256(uint8(b[at])) << 16) | (uint256(uint8(b[at + 1])) << 8) | uint256(uint8(b[at + 2]));
    }
}
