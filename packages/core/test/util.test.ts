import { describe, expect, it } from "vitest";
import { decryptToken, encryptToken } from "../src/crypto";
import { mask } from "../src/log";

const KEY = "0".repeat(63) + "1";
describe("crypto", () => {
  it("round-trips and detects tampering", () => {
    const blob = encryptToken("35419981304203731832", KEY);
    expect(blob).not.toContain("35419981304203731832");
    expect(decryptToken(blob, KEY)).toBe("35419981304203731832");
    const parts = blob.split(":");
    parts[3] = Buffer.from("x" + Buffer.from(parts[3]!, "base64").toString("latin1").slice(1), "latin1").toString("base64");
    expect(() => decryptToken(parts.join(":"), KEY)).toThrow();
  });
});
describe("log masking", () => {
  it("masks meter numbers and tokens", () => {
    expect(mask('{"meter":"45012345678","token":"35419981304203731832"}')).toBe('{"meter":"*******5678","token":"****************1832"}');
  });
});
