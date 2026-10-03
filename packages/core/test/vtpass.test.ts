import { describe, expect, it } from "vitest";
import { classifyVtpass, extractToken } from "../src/provider/vtpassParse";
import { VtpassProvider } from "../src/provider/vtpass";
import { lagosTimestamp, newRequestId } from "../src/provider/requestId";

// Verbatim (trimmed) samples from vtpass.com/documentation/phed-api/
const PHED_PAY_OK = {
  code: "000",
  content: { transactions: { status: "delivered", product_name: "PHED - Port Harcourt Electric", transactionId: "17416103081581109640542228" } },
  response_description: "TRANSACTION SUCCESSFUL",
  requestId: "2025031013382649722",
  purchased_code: "Token: 35419981304203731832",
  token: "35419981304203731832",
  units: "8.2",
};
const IKEDC_REQUERY_OK = {
  response_description: "TRANSACTION SUCCESSFUL",
  code: "000",
  content: { transactions: { status: "delivered", extras: "Token : 26362054405982757802", transactionId: "17416034528553907930106528" } },
  purchased_code: "Token : 26362054405982757802",
  token: "Token : 26362054405982757802",
  units: "79.9 kWh",
};

describe("classifyVtpass", () => {
  it("delivered with token (both documented formats)", () => {
    const a = classifyVtpass(PHED_PAY_OK);
    expect(a).toMatchObject({ kind: "delivered", token: "35419981304203731832", units: "8.2", providerTxId: "17416103081581109640542228" });
    const b = classifyVtpass(IKEDC_REQUERY_OK);
    expect(b).toMatchObject({ kind: "delivered", token: "26362054405982757802", units: "79.9 kWh" });
  });
  it("delivered WITHOUT a token is pending (requery), never a success", () => {
    expect(classifyVtpass({ ...PHED_PAY_OK, purchased_code: "", token: null }).kind).toBe("pending");
  });
  it("pending states", () => {
    for (const status of ["initiated", "pending"]) {
      expect(classifyVtpass({ code: "000", content: { transactions: { status } } }).kind).toBe("pending");
    }
    expect(classifyVtpass({ code: "099" }).kind).toBe("pending");
    expect(classifyVtpass({ code: "089" }).kind).toBe("pending");
  });
  it("definitive failures (not charged / reversed) allow refunds", () => {
    for (const code of ["016", "091", "018", "040", "013", "017", "027", "028"]) {
      expect(classifyVtpass({ code, response_description: "x" }).kind).toBe("failed");
    }
    expect(classifyVtpass({ code: "000", content: { transactions: { status: "reversed" } } }).kind).toBe("failed");
  });
  it("ambiguous codes are UNKNOWN (requery, never refund)", () => {
    for (const code of ["014", "019", "083", "015", "999"]) expect(classifyVtpass({ code }).kind).toBe("unknown");
    expect(classifyVtpass(null).kind).toBe("unknown");
    expect(classifyVtpass({ code: "000", content: { transactions: { status: "weird" } } }).kind).toBe("unknown");
  });
  it("extractToken", () => {
    expect(extractToken("Token: 3541 9981 3042 0373 1832")).toBe("35419981304203731832");
    expect(extractToken("N/A", null, "Token : 26362054405982757802")).toBe("26362054405982757802");
    expect(extractToken("")).toBeNull();
  });
});

describe("request_id", () => {
  it("starts with Africa/Lagos YYYYMMDDHHmm (UTC+1, no DST)", () => {
    expect(lagosTimestamp(new Date("2026-10-03T23:30:00Z"))).toBe("202610040030");
    expect(lagosTimestamp(new Date("2026-10-04T08:05:00Z"))).toBe("202610040905");
    const id = newRequestId(new Date("2026-10-04T08:05:00Z"));
    expect(id).toMatch(/^202610040905[0-9a-f]{16}$/);
  });
});

describe("VtpassProvider (fake fetch)", () => {
  const cfg = { baseUrl: "https://sandbox.vtpass.com/api/", apiKey: "k", publicKey: "PK_x", secretKey: "SK_y" };
  it("uses public-key on GET and secret-key on POST", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = (async (url: URL, init: RequestInit) => {
      calls.push({ url: String(url), init });
      return new Response(JSON.stringify(String(url).includes("balance") ? { code: 1, contents: { balance: 1234.5 } } : PHED_PAY_OK));
    }) as unknown as typeof fetch;
    const p = new VtpassProvider({ ...cfg, fetchImpl });
    expect(await p.getWalletBalance()).toBe(1234.5);
    const out = await p.purchase({ requestId: "202610040905abcd", serviceID: "portharcourt-electric", meterNumber: "1111111111111", amountNgn: 1000, phone: "08011111111" });
    expect(out.kind).toBe("delivered");
    const [get, post] = calls;
    expect((get!.init.headers as Record<string, string>)["public-key"]).toBe("PK_x");
    expect((get!.init.headers as Record<string, string>)["secret-key"]).toBeUndefined();
    expect((post!.init.headers as Record<string, string>)["secret-key"]).toBe("SK_y");
    expect(post!.url).toBe("https://sandbox.vtpass.com/api/pay");
    expect(JSON.parse(post!.init.body as string)).toMatchObject({ request_id: "202610040905abcd", variation_code: "prepaid", billersCode: "1111111111111" });
  });
  it("timeout on pay => unknown (requery), and pay is attempted exactly once", async () => {
    let n = 0;
    const fetchImpl = ((_u: URL, init: RequestInit) =>
      new Promise((_res, rej) => {
        n++;
        init.signal?.addEventListener("abort", () => rej(Object.assign(new Error("aborted"), { name: "AbortError" })));
      })) as unknown as typeof fetch;
    const p = new VtpassProvider({ ...cfg, fetchImpl, timeoutMs: 50 });
    const out = await p.purchase({ requestId: "r", serviceID: "ikeja-electric", meterNumber: "1", amountNgn: 1000, phone: "0" });
    expect(out.kind).toBe("unknown");
    expect(n).toBe(1);
  });
  it("verifyMeter rejects unknown meters", async () => {
    const fetchImpl = (async () => new Response(JSON.stringify({ code: "000", content: { error: "Meter not found", WrongBillersCode: true } }))) as unknown as typeof fetch;
    await expect(new VtpassProvider({ ...cfg, fetchImpl }).verifyMeter("ikeja-electric", "123", "prepaid")).rejects.toThrow("Meter not found");
  });
});
