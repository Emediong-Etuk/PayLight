// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal interfaces for the TapeOut protocol on X Layer.
/// @dev TapeOut's contracts are not source-verified. These signatures were recovered from deployed bytecode
///      (factory impl 0x74956236…d17b, circuit impl 0x977f2178…f29B2, transistor impl 0x265bf10f…9a06b),
///      hash-checked with `cast sig`, and exercised on a mainnet fork (docs/RESEARCH.md §1).
///      TapeOut is upgradeable by its owner (3-of-5 Safe) until sealed, so PayLight never lets a TapeOut call
///      block payments, settlement or refunds.

/// @notice TapeOut factory (proxy 0x1f09daefa827f02cbb40967cc91b259763760761 on X Layer).
interface ITapeOutFactory {
    function createCPU(string calldata name, string calldata symbol, string calldata story, uint256 supplyCap, uint256 mintPrice)
        external
        payable;
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256 index) external view returns (address);
    function isCPU(address cpu) external view returns (bool);
    function deployFee() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

/// @notice A TapeOut processor: an ERC-721 collection of taped-out circuits.
interface ITapeOutProcessor {
    /// @return The processor's ERC-1155 transistor contract (NAND id 0, LATCH id 1).
    function transistors() external view returns (address);
    /// @notice Tape out a netlist; burns the NAND/LATCH it uses from msg.sender and mints a circuit NFT.
    function tapeout(bytes calldata netlist, uint32 nInputs, uint32 nOutputs) external payable;
    /// @notice Evaluate a combinational circuit. Inputs and outputs are bit-packed, LSB first.
    function eval(uint256 circuitId, bytes calldata input) external view returns (bytes memory);
    /// @return The latest circuit id (ids start at 1), i.e. the number of circuits.
    function nextId() external view returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
    function ownerOf(uint256 circuitId) external view returns (address);
}

/// @notice A processor's transistor contract (ERC-1155 with a fixed-price native-OKB mint).
interface ITapeOutTransistors {
    /// @notice Mints `amount` of `id` to msg.sender (ERC-1155 safe mint).
    ///         msg.value must be >= mintPrice() * amount + protocolFee() (protocol fee is flat per call).
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    /// @dev Lifetime counter; burning does not free supply.
    function minted() external view returns (uint256);
    function creator() external view returns (address);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
    function setApprovalForAll(address operator, bool approved) external;
}
