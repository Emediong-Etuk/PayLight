// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {PayLightGateway} from "../src/PayLightGateway.sol";
import {CashbackRouter} from "../src/CashbackRouter.sol";
import {FeeTierCircuit} from "../src/libraries/FeeTierCircuit.sol";
import {MockUSDT0} from "../test/mocks/MockUSDT0.sol";
import {MockTransistors, MockProcessor} from "../test/mocks/MockTapeOut.sol";

/// @notice LOCAL ANVIL ONLY: deploys mock USD₮0 + mock TapeOut + the real gateway/router with the approved params,
///         funds two test users and the cashback reserve, and writes addresses to $LOCAL_OUT (JSON).
///         anvil --chain-id 196 & forge script script/LocalDev.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
///         Uses anvil's public default keys via env (DEPLOYER_PK etc.). Never point this at a real network.
contract LocalDev is Script {
    function run() external {
        require(block.chainid == 196 || block.chainid == 31337, "local only");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);
        address operator = vm.envAddress("OPERATOR");
        address keeper = vm.envAddress("KEEPER");
        address signer = vm.envAddress("QUOTE_SIGNER");
        address treasury = vm.envAddress("TREASURY");
        address user1 = vm.envAddress("USER1");
        address user2 = vm.envAddress("USER2");

        vm.startBroadcast(deployerPk);
        MockUSDT0 usdt0 = new MockUSDT0();
        MockTransistors t = new MockTransistors(1_000_000, 0.0001 ether, 0.00066 ether, deployer);
        MockProcessor p = new MockProcessor(t);
        t.setProcessor(address(p));
        t.mint{value: 0.0001 ether * FeeTierCircuit.NAND_COUNT + 0.00066 ether}(0, FeeTierCircuit.NAND_COUNT);
        p.tapeout{value: p.TAPEOUT_FEE()}(FeeTierCircuit.NETLIST, FeeTierCircuit.N_INPUTS, FeeTierCircuit.N_OUTPUTS);

        PayLightGateway.InitParams memory ip;
        ip.usdt0 = address(usdt0);
        ip.processor = address(p);
        ip.admin = deployer;
        ip.operator = operator;
        ip.treasury = treasury;
        ip.quoteSigner = signer;
        ip.feeCircuitId = p.nextId();
        ip.tierFeeBps = [uint16(100), 50, 25];
        ip.tier1Holding = 50;
        ip.tier2Holding = 500;
        ip.repeatOrders = 3;
        ip.maxOrderAmount = 30e6;
        ip.dailyVolumeCap = 1_000e6;
        ip.refundTimeout = 24 hours;
        PayLightGateway gw = new PayLightGateway(ip);
        CashbackRouter router = new CashbackRouter(address(gw), address(t), deployer, keeper, 200_000);
        gw.setCashbackRouter(address(router));
        usdt0.mint(user1, 10_000e6);
        usdt0.mint(user2, 10_000e6);
        vm.stopBroadcast();

        string memory o = "local";
        vm.serializeAddress(o, "usdt0", address(usdt0));
        vm.serializeAddress(o, "transistors", address(t));
        vm.serializeAddress(o, "processor", address(p));
        vm.serializeAddress(o, "gateway", address(gw));
        vm.serializeUint(o, "block", block.number);
        string memory json = vm.serializeAddress(o, "router", address(router));
        vm.writeJson(json, vm.envString("LOCAL_OUT"));
    }
}
