import type { BillProvider, DiscoInfo, MeterInfo, ProviderOutcome, PurchaseRequest } from "./types";
import { MeterVerificationError } from "./types";
import { classifyVtpass } from "./vtpassParse";

export interface VtpassConfig {
  baseUrl: string; // https://sandbox.vtpass.com/api/ or https://vtpass.com/api/
  apiKey: string;
  publicKey: string;
  secretKey: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

/**
 * VTpass REST client (docs/RESEARCH.md Q16–Q20). GET: api-key + public-key; POST: api-key + secret-key.
 * `purchase` is called at most once per order by the worker and never throws on transport errors.
 */
export class VtpassProvider implements BillProvider {
  readonly name = "vtpass";
  private readonly base: string;
  private readonly timeoutMs: number;
  private readonly f: typeof fetch;

  constructor(private readonly cfg: VtpassConfig) {
    this.base = cfg.baseUrl.endsWith("/") ? cfg.baseUrl : `${cfg.baseUrl}/`;
    this.timeoutMs = cfg.timeoutMs ?? 45_000;
    this.f = cfg.fetchImpl ?? fetch;
  }

  private async request(method: "GET" | "POST", path: string, body?: unknown, timeoutMs = this.timeoutMs): Promise<unknown> {
    const headers: Record<string, string> = { "api-key": this.cfg.apiKey, accept: "application/json" };
    if (method === "GET") headers["public-key"] = this.cfg.publicKey;
    else {
      headers["secret-key"] = this.cfg.secretKey;
      headers["content-type"] = "application/json";
    }
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await this.f(new URL(path, this.base), {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: ctrl.signal,
      });
      const text = await res.text();
      try {
        return JSON.parse(text);
      } catch {
        return { __nonJson: true, status: res.status, body: text.slice(0, 500) };
      }
    } finally {
      clearTimeout(t);
    }
  }

  async listDiscos(): Promise<DiscoInfo[]> {
    const r = (await this.request("GET", "services?identifier=electricity-bill", undefined, 20_000)) as {
      content?: Array<{ serviceID: string; name: string; minimium_amount?: string; maximum_amount?: string }>;
    };
    return (r.content ?? []).map((d) => ({
      serviceID: d.serviceID,
      name: d.name,
      minAmount: d.minimium_amount ? Number(d.minimium_amount) || null : null,
      maxAmount: d.maximum_amount ? Number(d.maximum_amount) || null : null,
    }));
  }

  async verifyMeter(serviceID: string, meterNumber: string, meterType: "prepaid"): Promise<MeterInfo> {
    let r: Record<string, unknown>;
    try {
      r = (await this.request("POST", "merchant-verify", { billersCode: meterNumber, serviceID, type: meterType }, 20_000)) as Record<string, unknown>;
    } catch (e) {
      throw new MeterVerificationError(`provider unreachable: ${(e as Error).message}`, true);
    }
    const c = (r.content ?? {}) as Record<string, unknown>;
    const name = typeof c.Customer_Name === "string" ? c.Customer_Name.trim() : "";
    if (r.code !== "000" || !name || c.WrongBillersCode === true || c.error) {
      const retryable = r.code === "030" || r.code === "083";
      throw new MeterVerificationError(typeof c.error === "string" ? c.error : "We couldn't find that meter. Check the number and the electricity company.", retryable);
    }
    const num = (v: unknown) => (v === "" || v == null || Number.isNaN(Number(v)) ? null : Number(v));
    return {
      customerName: name,
      address: typeof c.Address === "string" ? c.Address : null,
      meterType: typeof c.Meter_Type === "string" ? c.Meter_Type : null,
      minPurchase: num(c.Min_Purchase_Amount ?? c.Minimum_Amount),
      maxPurchase: num(c.MAX_Purchase_Amount),
    };
  }

  async purchase(req: PurchaseRequest): Promise<ProviderOutcome> {
    try {
      const raw = await this.request("POST", "pay", {
        request_id: req.requestId,
        serviceID: req.serviceID,
        billersCode: req.meterNumber,
        variation_code: "prepaid",
        amount: req.amountNgn,
        phone: req.phone,
      });
      return classifyVtpass(raw);
    } catch (e) {
      // Timeout / network error: the request may or may not have reached VTpass. NEVER re-pay; requery.
      return { kind: "unknown", reason: `transport: ${(e as Error).name}: ${(e as Error).message}`, code: null, raw: null };
    }
  }

  async requery(requestId: string): Promise<ProviderOutcome> {
    try {
      return classifyVtpass(await this.request("POST", "requery", { request_id: requestId }, 20_000));
    } catch (e) {
      return { kind: "unknown", reason: `transport: ${(e as Error).message}`, code: null, raw: null };
    }
  }

  async getWalletBalance(): Promise<number> {
    const r = (await this.request("GET", "balance", undefined, 15_000)) as { contents?: { balance?: number | string } };
    const b = Number(r.contents?.balance);
    if (!Number.isFinite(b)) throw new Error("could not read VTpass balance");
    return b;
  }
}
