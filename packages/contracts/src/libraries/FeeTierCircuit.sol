// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FeeTierCircuit
/// @notice The netlist of "PayLight FeeTier v1", taped out on the PayLight TapeOut processor.
/// @dev Inputs (bit-packed, LSB first): bit0 = h1 (holds >= tier1Holding transistors), bit1 = h2 (holds >= tier2Holding),
///      bit2 = r (>= repeatOrders settled orders). Outputs (LSB first): bit0 = lo, bit1 = hi; tier = lo + 2*hi.
///      tier = h2 ? 2 : ((h1 OR r) ? 1 : 0).
///      Signals: 0 = const 0, 1 = const 1, 2 = h1, 3 = h2, 4 = r, then one signal per gate:
///        g5  = NAND(2,2)  = !h1
///        g6  = NAND(4,4)  = !r
///        g7  = NAND(5,6)  = h1 | r
///        g8  = NAND(3,3)  = !h2
///        g9  = NAND(7,8)  = !((h1|r) & !h2)
///        g10 = NAND(9,9)  = (h1|r) & !h2   -> lo
///        g11 = NAND(8,8)  = h2             -> hi
///      Encoding per TapeOut: NAND = 0x00 ++ uint24 a ++ uint24 b. Verified on an X Layer mainnet fork on 2026-10-03:
///      circuitInfo = [3,2,0,7] and all 8 input combinations evaluate to the expected tier (docs/RESEARCH.md Q6).
library FeeTierCircuit {
    bytes internal constant NETLIST =
        hex"00000002000002000000040000040000000500000600000003000003000000070000080000000900000900000008000008";
    uint32 internal constant N_INPUTS = 3;
    uint32 internal constant N_OUTPUTS = 2;
    /// @notice NAND transistors burned by tape-out.
    uint256 internal constant NAND_COUNT = 7;

    /// @notice Reference implementation, for tests and off-chain parity.
    function expectedTier(uint8 input) internal pure returns (uint8) {
        bool h1 = input & 1 != 0;
        bool h2 = input & 2 != 0;
        bool r = input & 4 != 0;
        if (h2) return 2;
        if (h1 || r) return 1;
        return 0;
    }
}
