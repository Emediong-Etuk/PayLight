import type { ProviderOutcome } from "./types";

/**
 * VTpass response classification (docs/RESEARCH.md Q19; vtpass.com/documentation/response-codes).
 * VTpass: "Take any response that differs from the guidelines … as pending, and initiate a transaction requery."
 */

/** Codes where VTpass did NOT charge us (or reversed): the only codes that allow an automatic refund. */
const DEFINITIVE_FAILURE = new Set([
  "010", // variation code does not exist
  "011", // invalid arguments
  "012", // product does not exist
  "013", // below minimum amount
  "016", // transaction failed
  "017", // above maximum amount
  "018", // low wallet balance
  "021", // account locked
  "022", // account suspended
  "023", // API access not enabled
  "024", // account inactive
  "027", // IP not whitelisted
  "028", // product not whitelisted
  "030", // biller not reachable
  "031", // below minimum quantity
  "032", // above maximum quantity
  "034", // service suspended
  "035", // service inactive
  "040", // transaction reversal (refunded to our wallet)
  "085", // improper request id
  "087", // invalid credentials
  "091", // transaction not processed (not charged)
]);
/** Codes that say "keep waiting". */
const PENDING_CODES = new Set(["099", "089"]);
// Everything else (incl. 014 request id already exists, 019 likely duplicate, 083 system error, 015 on requery) → unknown.

type Json = Record<string, unknown>;
const obj = (v: unknown): Json | undefined => (v && typeof v === "object" ? (v as Json) : undefined);
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v.trim() : typeof v === "number" ? String(v) : null);

/** Extracts digits from "Token: 3541 9981 …", "Token : 26362054405982757802" or a bare token. */
export function extractToken(...candidates: unknown[]): string | null {
  for (const c of candidates) {
    const s = str(c);
    if (!s || /^n\/?a$/i.test(s)) continue;
    const digits = s.replace(/^\s*token\s*:?\s*/i, "").replace(/[\s-]/g, "");
    const m = /\d{16,24}/.exec(digits);
    if (m) return m[0];
  }
  return null;
}

export function classifyVtpass(raw: unknown): ProviderOutcome {
  const r = obj(raw);
  if (!r) return { kind: "unknown", reason: "empty or non-JSON response", code: null, raw };
  const code = str(r.code);
  const tx = obj(obj(r.content)?.transactions);
  const providerTxId = str(tx?.transactionId);

  if (code === "000") {
    const status = (str(tx?.status) ?? "").toLowerCase();
    if (status === "delivered") {
      const token = extractToken(r.token, r.purchased_code, r.Token, tx?.extras);
      if (!token) return { kind: "pending", providerTxId, code, raw }; // delivered but no token yet → requery
      return { kind: "delivered", token, units: str(r.units), providerTxId, code, raw };
    }
    if (status === "initiated" || status === "pending" || status === "processing") return { kind: "pending", providerTxId, code, raw };
    if (status === "failed" || status === "reversed") return { kind: "failed", reason: `status ${status}`, code, raw };
    return { kind: "unknown", reason: `unexpected status "${status}"`, code, raw };
  }
  if (code && PENDING_CODES.has(code)) return { kind: "pending", providerTxId, code, raw };
  if (code && DEFINITIVE_FAILURE.has(code)) {
    return { kind: "failed", reason: str(r.response_description) ?? `code ${code}`, code, raw };
  }
  return { kind: "unknown", reason: `unexpected code ${code ?? "none"}: ${str(r.response_description) ?? ""}`.trim(), code, raw };
}
