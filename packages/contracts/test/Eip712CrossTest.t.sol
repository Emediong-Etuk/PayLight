// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Fixture} from "./utils/Fixture.sol";
import {PayLightGateway} from "../src/PayLightGateway.sol";

/// @notice Cross-test (brief §6.4): a quote signed in TypeScript with viem (packages/shared/test/eip712-vector.test.ts)
///         must hash identically here and be accepted by pay(). Regenerate by running the shared package tests (pnpm test in packages/shared).
contract Eip712CrossTest is Fixture {
    using stdJson for string;

    function test_typescriptSignedQuote_isAcceptedByGateway() public {
        string memory json = vm.readFile("../shared/test/fixtures/quote-vector.json");
        address gwAddr = json.readAddress(".gateway");
        address signer = json.readAddress(".signer");
        vm.chainId(json.readUint(".chainId"));

        PayLightGateway.InitParams memory p = _initParams();
        p.quoteSigner = signer;
        deployCodeTo("PayLightGateway.sol:PayLightGateway", abi.encode(p), gwAddr);
        PayLightGateway gw = PayLightGateway(gwAddr);

        PayLightGateway.Quote memory q = PayLightGateway.Quote({
            orderId: json.readBytes32(".orderId"),
            payer: json.readAddress(".payer"),
            baseAmount: uint128(json.readUint(".baseAmount")),
            fee: uint128(json.readUint(".fee")),
            tier: uint8(json.readUint(".tier")),
            cashbackUnits: uint32(json.readUint(".cashbackUnits")),
            expiry: uint64(json.readUint(".expiry"))
        });
        assertEq(gw.quoteDigest(q), json.readBytes32(".digest"), "TS and Solidity digests differ");
        assertEq(gw.previewFee(q.baseAmount, q.tier), q.fee, "TS fee math differs");

        usdt0.mint(q.payer, q.baseAmount + q.fee);
        vm.startPrank(q.payer);
        usdt0.approve(gwAddr, q.baseAmount + q.fee);
        gw.pay(q, json.readBytes(".signature"));
        vm.stopPrank();
        assertEq(uint8(gw.getOrder(q.orderId).status), uint8(PayLightGateway.Status.Paid));
    }
}
