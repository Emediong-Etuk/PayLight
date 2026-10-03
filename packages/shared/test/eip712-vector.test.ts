/**
 * Cross-test, TS side: signs a fixed quote with viem and writes test/fixtures/quote-vector.json.
 * The Foundry test packages/contracts/test/Eip712CrossTest.t.sol deploys the gateway at the same address,
 * asserts quoteDigest == digest and that pay() accepts this exact signature.
 */
import { describe, expect, it } from "vitest";
import { writeFileSync, mkdirSync } from "node:fs";
import { hashTypedData, recoverTypedDataAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { QUOTE_TYPES, gatewayDomain } from "../src/eip712";

// Public test-only key (keccak256("paylight-cross-test-signer")); never used on a live network.
const SIGNER_PK = "0x6bb2a2c4f6f8a39a7b0cbe8d22b1f1f2c6a3f0f9f5f6a2b8c1d0e9f8a7b6c5d4" as const;
const GATEWAY = "0x00000000000000000000000000000000ca11ab1e" as const;

describe("EIP-712 quote vector", () => {
  it("signs and writes the fixture", async () => {
    const account = privateKeyToAccount(SIGNER_PK);
    const message = {
      orderId: "0x1111111111111111111111111111111111111111111111111111111111111111",
      payer: "0x000000000000000000000000000000000000beef",
      baseAmount: 3_698_225n,
      fee: 36_983n,
      tier: 0,
      cashbackUnits: 5,
      expiry: 1_760_000_120n,
    } as const;
    const domain = gatewayDomain(196, GATEWAY);
    const digest = hashTypedData({ domain, types: QUOTE_TYPES, primaryType: "Quote", message });
    const signature = await account.signTypedData({ domain, types: QUOTE_TYPES, primaryType: "Quote", message });
    expect(await recoverTypedDataAddress({ domain, types: QUOTE_TYPES, primaryType: "Quote", message, signature })).toBe(
      account.address,
    );
    mkdirSync("test/fixtures", { recursive: true });
    writeFileSync(
      "test/fixtures/quote-vector.json",
      JSON.stringify(
        {
          chainId: 196,
          gateway: GATEWAY,
          signer: account.address,
          orderId: message.orderId,
          payer: message.payer,
          baseAmount: Number(message.baseAmount),
          fee: Number(message.fee),
          tier: message.tier,
          cashbackUnits: message.cashbackUnits,
          expiry: Number(message.expiry),
          digest,
          signature,
        },
        null,
        2,
      ) + "\n",
    );
  });
});
