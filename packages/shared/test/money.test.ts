import { describe, expect, it } from "vitest";
import { cashbackUnitsFor, ceilDiv, feeFor, formatUsdt0, ngnToUsdt0, parseRateToKobo } from "../src/money";
import { groupToken, maskMeter, maskName, maskAddress } from "../src/format";

describe("money", () => {
  it("ceilDiv", () => {
    expect(ceilDiv(0n, 3n)).toBe(0n);
    expect(ceilDiv(1n, 3n)).toBe(1n);
    expect(ceilDiv(3n, 3n)).toBe(1n);
    expect(ceilDiv(4n, 3n)).toBe(2n);
  });
  it("ngnToUsdt0 rounds up", () => {
    // ₦5,000 at ₦1,352.00/USD₮0 = 3.698224852... => 3.698225
    expect(ngnToUsdt0(5_000n, 135_200n)).toBe(3_698_225n);
    expect(ngnToUsdt0(1_352n, 135_200n)).toBe(1_000_000n);
  });
  it("feeFor mirrors the contract (ceil)", () => {
    expect(feeFor(3_300_000n, 100)).toBe(33_000n);
    expect(feeFor(1n, 100)).toBe(1n);
    expect(feeFor(10_000_000n, 25)).toBe(25_000n);
  });
  it("cashback units: 1 per ₦1,000, min 1, max 50, backed by 0.25 USD₮0 each", () => {
    expect(cashbackUnitsFor(5_000n, 3_698_225n)).toBe(5);
    expect(cashbackUnitsFor(500n, 369_823n)).toBe(1);
    expect(cashbackUnitsFor(500n, 200_000n)).toBe(0); // can't back even 1 unit
    expect(cashbackUnitsFor(100_000n, 73_964_497n)).toBe(50);
  });
  it("formatUsdt0 / parseRate", () => {
    expect(formatUsdt0(3_698_225n)).toBe("3.698225");
    expect(formatUsdt0(1_000_000n)).toBe("1.00");
    expect(parseRateToKobo("1352")).toBe(135_200n);
    expect(parseRateToKobo("1352.5")).toBe(135_250n);
    expect(() => parseRateToKobo("1.234")).toThrow();
  });
});

describe("format", () => {
  it("groups tokens and masks PII", () => {
    expect(groupToken("35419981304203731832")).toBe("3541 9981 3042 0373 1832");
    expect(maskMeter("45012345678")).toBe("*******5678");
    expect(maskName("JOHN DOE OKAFOR")).toBe("JOHN D*E O****R");
    expect(maskAddress("12 Foo Street, Rumuola, Port Harcourt")).toBe("Rumuola, Port Harcourt");
  });
});
