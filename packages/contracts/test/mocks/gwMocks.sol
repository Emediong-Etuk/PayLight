// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ICashbackRouter} from "../../src/interfaces/ICashbackRouter.sol";
import {FeeTierCircuit} from "../../src/libraries/FeeTierCircuit.sol";

/// @notice Test helpers used only by test/PayLightGateway.t.sol.

/// @notice USD₮0-like token (permit + EIP-3009) that can burn a 1-unit fee on every transfer, to prove the gateway's
///         balance-delta check (TransferMismatch) fires.
contract GwFeeOnTransferToken is ERC20, ERC20Permit {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bool public feeOn;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    error CallerMustBePayee();
    error InvalidAuthorization();
    error AuthorizationUsed();

    constructor() ERC20("FeeToken", "FOT") ERC20Permit("FeeToken") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeOn(bool on) external {
        feeOn = on;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (to != msg.sender) revert CallerMustBePayee();
        if (authorizationState[from][nonce]) revert AuthorizationUsed();
        require(block.timestamp > validAfter && block.timestamp < validBefore, "window");
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        if (ECDSA.recover(_hashTypedDataV4(structHash), v, r, s) != from) revert InvalidAuthorization();
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOn && from != address(0) && to != address(0) && value > 0) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1); // burn the fee
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Configurable cashback router: records credits, or reverts / burns all gas on demand.
contract GwRouterMock is ICashbackRouter {
    enum Mode {
        Ok,
        Revert,
        GasBomb
    }

    Mode public mode;
    uint256 public calls;
    mapping(bytes32 => uint32) public creditedUnits;
    mapping(bytes32 => address) public creditedPayer;

    event Credited(bytes32 indexed orderId, address indexed payer, uint32 units);

    function setMode(Mode m) external {
        mode = m;
    }

    function credit(bytes32 orderId, address payer, uint32 units) external {
        Mode m = mode;
        if (m == Mode.Revert) revert("router down");
        if (m == Mode.GasBomb) {
            uint256 x;
            while (true) {
                x++;
            }
        }
        calls++;
        creditedUnits[orderId] = units;
        creditedPayer[orderId] = payer;
        emit Credited(orderId, payer, units);
    }
}

/// @notice Minimal processor stand-in: configurable `transistors()` address and an `eval` that burns `burnGas` gas
///         before returning the reference FeeTier output (bit-packed, ABI-encoded `bytes`).
contract GwProcessorStub {
    address internal immutable _transistors;
    uint256 public immutable burnGas;

    constructor(address transistors_, uint256 burnGas_) {
        _transistors = transistors_;
        burnGas = burnGas_;
    }

    function transistors() external view returns (address) {
        return _transistors;
    }

    function eval(uint256, bytes calldata input) external view returns (bytes memory) {
        uint256 start = gasleft();
        uint256 burn = burnGas;
        while (start - gasleft() < burn) {}
        uint8 x = input.length > 0 ? uint8(input[0]) : 0;
        return abi.encodePacked(FeeTierCircuit.expectedTier(x));
    }
}

/// @notice ERC-1155-ish balance source with failure modes, to exercise the gateway's capped balance staticcalls.
contract GwBadTransistors {
    enum Mode {
        Normal,
        Revert,
        GasBomb,
        ShortReturn,
        HugeReturn,
        MaxBalance
    }

    Mode public mode;
    mapping(address => mapping(uint256 => uint256)) public bal;

    function setMode(Mode m) external {
        mode = m;
    }

    function setBalance(address account, uint256 id, uint256 v) external {
        bal[account][id] = v;
    }

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        Mode m = mode;
        if (m == Mode.Revert) revert("down");
        if (m == Mode.GasBomb) {
            uint256 x;
            while (true) {
                x++;
            }
        }
        if (m == Mode.ShortReturn) {
            assembly {
                mstore(0, 0xffffffffffffffffffffffffffffffff)
                return(0x10, 0x10)
            }
        }
        if (m == Mode.HugeReturn) {
            uint256 v = bal[account][id];
            assembly {
                mstore(0, v)
                return(0, 100000)
            }
        }
        if (m == Mode.MaxBalance) return type(uint256).max;
        return bal[account][id];
    }
}
