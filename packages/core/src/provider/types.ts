export interface DiscoInfo {
  serviceID: string;
  name: string;
  minAmount: number | null;
  maxAmount: number | null;
}

export interface MeterInfo {
  customerName: string;
  address: string | null;
  meterType: string | null;
  minPurchase: number | null;
  maxPurchase: number | null;
}

export interface PurchaseRequest {
  requestId: string;
  serviceID: string;
  meterNumber: string;
  amountNgn: number;
  phone: string;
}

/**
 * The only four things a purchase/requery can tell us.
 * - delivered: provider confirmed delivery AND returned a meter token.
 * - pending:   still processing (or delivered without a token yet) → requery later.
 * - failed:    DEFINITIVE failure, provider says we were not charged / it was reversed → safe to refund.
 * - unknown:   anything else (timeouts, network errors, unexpected codes) → requery; never refund on this.
 */
export type ProviderOutcome =
  | { kind: "delivered"; token: string; units: string | null; providerTxId: string | null; code: string; raw: unknown }
  | { kind: "pending"; providerTxId: string | null; code: string | null; raw: unknown }
  | { kind: "failed"; reason: string; code: string | null; raw: unknown }
  | { kind: "unknown"; reason: string; code: string | null; raw: unknown };

export interface BillProvider {
  readonly name: string;
  listDiscos(): Promise<DiscoInfo[]>;
  verifyMeter(serviceID: string, meterNumber: string, meterType: "prepaid"): Promise<MeterInfo>;
  /** Called at most ONCE per order. Never throws for transport errors: returns { kind: "unknown" }. */
  purchase(req: PurchaseRequest): Promise<ProviderOutcome>;
  requery(requestId: string): Promise<ProviderOutcome>;
  /** NGN wallet float. */
  getWalletBalance(): Promise<number>;
}

export class MeterVerificationError extends Error {
  constructor(message: string, readonly retryable = false) {
    super(message);
  }
}
