import { DISCOS } from "@paylight/shared";
import type { BillProvider, DiscoInfo, MeterInfo, ProviderOutcome, PurchaseRequest } from "./types";
import { MeterVerificationError } from "./types";

/**
 * Deterministic in-memory provider for local dev and tests, keyed by meter number (mirrors VTpass sandbox meters):
 *  1111111111111 → delivered immediately
 *  201000000000  → pending, delivered on the 2nd requery
 *  202000000000  → pending, fails (reversed) on the 2nd requery
 *  300000000000  → purchase times out (unknown); requery then shows delivered
 *  400000000000  → purchase hard-fails (code 016)
 *  500000000000  → always unknown (→ NEEDS_REVIEW after max requeries)
 *  anything else → meter verification fails
 */
export class MockProvider implements BillProvider {
  readonly name = "mock";
  balance = 500_000;
  private readonly txs = new Map<string, { meter: string; requeries: number; amount: number }>();
  readonly purchases: PurchaseRequest[] = [];

  static readonly METERS = {
    success: "1111111111111",
    pendingThenSuccess: "201000000000",
    pendingThenFail: "202000000000",
    timeoutThenSuccess: "300000000000",
    hardFail: "400000000000",
    unknownForever: "500000000000",
  } as const;

  async listDiscos(): Promise<DiscoInfo[]> {
    return DISCOS.map((d) => ({ serviceID: d.serviceID, name: d.name, minAmount: 500, maxAmount: 500_000 }));
  }

  async verifyMeter(_serviceID: string, meterNumber: string): Promise<MeterInfo> {
    if (!(Object.values(MockProvider.METERS) as string[]).includes(meterNumber)) {
      throw new MeterVerificationError("We couldn't find that meter. Check the number and the electricity company.");
    }
    return { customerName: "TESTMETER ONE", address: "12 Aba Road, Rumuola, Port Harcourt", meterType: "PREPAID", minPurchase: 500, maxPurchase: null };
  }

  private token(requestId: string) {
    const digits = BigInt("0x" + Buffer.from(requestId).toString("hex").slice(-20)).toString().padStart(20, "7");
    return digits.slice(-20);
  }

  private delivered(requestId: string): ProviderOutcome {
    return { kind: "delivered", token: this.token(requestId), units: "8.2", providerTxId: `mock-${requestId}`, code: "000", raw: { mock: true } };
  }

  async purchase(req: PurchaseRequest): Promise<ProviderOutcome> {
    if (this.txs.has(req.requestId)) return { kind: "unknown", reason: "code 014 request id already exists", code: "014", raw: {} };
    this.purchases.push(req);
    this.txs.set(req.requestId, { meter: req.meterNumber, requeries: 0, amount: req.amountNgn });
    const M = MockProvider.METERS;
    switch (req.meterNumber) {
      case M.success:
        this.balance -= req.amountNgn;
        return this.delivered(req.requestId);
      case M.pendingThenSuccess:
      case M.pendingThenFail:
        return { kind: "pending", providerTxId: `mock-${req.requestId}`, code: "099", raw: {} };
      case M.timeoutThenSuccess:
        return { kind: "unknown", reason: "transport: AbortError", code: null, raw: null };
      case M.hardFail:
        return { kind: "failed", reason: "TRANSACTION FAILED", code: "016", raw: {} };
      default:
        return { kind: "unknown", reason: "unexpected response", code: "083", raw: {} };
    }
  }

  async requery(requestId: string): Promise<ProviderOutcome> {
    const tx = this.txs.get(requestId);
    if (!tx) return { kind: "unknown", reason: "code 015 invalid request id", code: "015", raw: {} };
    tx.requeries += 1;
    const M = MockProvider.METERS;
    switch (tx.meter) {
      case M.success:
      case M.timeoutThenSuccess:
        return this.delivered(requestId);
      case M.pendingThenSuccess:
        return tx.requeries >= 2 ? this.delivered(requestId) : { kind: "pending", providerTxId: `mock-${requestId}`, code: "000", raw: {} };
      case M.pendingThenFail:
        return tx.requeries >= 2 ? { kind: "failed", reason: "status reversed", code: "000", raw: {} } : { kind: "pending", providerTxId: null, code: "000", raw: {} };
      case M.hardFail:
        return { kind: "failed", reason: "TRANSACTION FAILED", code: "016", raw: {} };
      default:
        return { kind: "unknown", reason: "unexpected response", code: "083", raw: {} };
    }
  }

  async getWalletBalance(): Promise<number> {
    return this.balance;
  }
}
