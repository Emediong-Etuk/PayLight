import { randomBytes } from "node:crypto";
import type { Address, Hex, LocalAccount } from "viem";
import { prisma } from "@paylight/db";
import {
  QUOTE_TYPES,
  cashbackUnitsFor,
  gatewayDomain,
  ngnToUsdt0,
  payLightGatewayAbi,
  type Quote,
  type QuoteRequest,
  type QuoteResponse,
} from "@paylight/shared";
import type { BillProvider } from "./provider/types";
import { effectiveRateKobo, type PricingConfig } from "./config";

export class QuoteError extends Error {
  constructor(message: string, readonly code: "PAUSED" | "NO_RATE" | "FLOAT" | "CAP" | "AMOUNT" | "METER" | "UNAVAILABLE") {
    super(message);
  }
}

/** On-chain reads the quote needs. Implemented with viem in production, faked in unit tests. */
export interface GatewayReader {
  computeTier(payer: Address): Promise<number>;
  previewFee(baseAmount: bigint, tier: number): Promise<bigint>;
  maxOrderAmount(): Promise<bigint>;
}

export interface QuoteDeps {
  provider: BillProvider;
  gateway: GatewayReader;
  gatewayAddress: Address;
  chainId: number;
  signer: LocalAccount;
  pricing: PricingConfig;
  limits: { maxOrderNgn: number; dailyWalletCapNgn: number; floatMinNgn: number; ttlSeconds: number; maxRateAgeHours?: number };
  now?: () => Date;
  /** Cached provider float (NGN). */
  floatNgn: () => Promise<number>;
}

export function viemGatewayReader(client: { readContract: (args: any) => Promise<unknown> }, address: Address): GatewayReader {
  return {
    computeTier: async (payer) => Number(await client.readContract({ address, abi: payLightGatewayAbi, functionName: "computeTier", args: [payer] })),
    previewFee: async (base, tier) => (await client.readContract({ address, abi: payLightGatewayAbi, functionName: "previewFee", args: [base, tier] })) as bigint,
    maxOrderAmount: async () => (await client.readContract({ address, abi: payLightGatewayAbi, functionName: "maxOrderAmount" })) as bigint,
  };
}

/** Sum of naira paid today (Lagos day ≈ UTC day for caps) by this wallet, counting orders that reached PAID. */
async function walletNgnToday(payer: string, now: Date): Promise<number> {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const rows = await prisma.order.findMany({
    where: { payer: payer.toLowerCase(), paidAt: { gte: start }, status: { notIn: ["QUOTED", "EXPIRED", "REFUNDED"] } },
    select: { quote: { select: { amountNgn: true } } },
  });
  return rows.reduce((s, r) => s + r.quote.amountNgn, 0);
}

export async function createQuote(req: QuoteRequest, deps: QuoteDeps): Promise<QuoteResponse> {
  const now = deps.now?.() ?? new Date();
  const payer = req.payer.toLowerCase() as Address;
  const { pricing, limits } = deps;

  if (pricing.quotesPaused) throw new QuoteError("PayLight is paused for a moment. Please try again shortly.", "PAUSED");
  if (pricing.rateKobo <= 0n) throw new QuoteError("Exchange rate not set yet.", "NO_RATE");
  const maxAgeMs = (limits.maxRateAgeHours ?? 24) * 3_600_000;
  if (pricing.rateUpdatedAt && now.getTime() - pricing.rateUpdatedAt.getTime() > maxAgeMs) {
    throw new QuoteError("Our exchange rate is being updated. Please try again shortly.", "NO_RATE");
  }
  if (req.amountNgn > limits.maxOrderNgn) throw new QuoteError(`During the pilot the maximum is ₦${limits.maxOrderNgn.toLocaleString("en-NG")} per purchase.`, "CAP");

  // Don't take money we can't fulfil (brief §6.2 rule 4).
  const float = await deps.floatNgn().catch(() => -1);
  if (float < req.amountNgn + limits.floatMinNgn) throw new QuoteError("Electricity purchases are temporarily unavailable. Please try again later.", "FLOAT");

  const today = await walletNgnToday(payer, now);
  if (today + req.amountNgn > limits.dailyWalletCapNgn) throw new QuoteError(`Daily limit reached for this wallet (₦${limits.dailyWalletCapNgn.toLocaleString("en-NG")}).`, "CAP");

  // Re-verify the meter (never trust the client's earlier verification).
  let meter;
  try {
    meter = await deps.provider.verifyMeter(req.serviceID, req.meterNumber, "prepaid");
  } catch (e) {
    throw new QuoteError((e as Error).message, "METER");
  }
  if (meter.minPurchase && req.amountNgn < meter.minPurchase) throw new QuoteError(`Minimum for this meter is ₦${meter.minPurchase.toLocaleString("en-NG")}.`, "AMOUNT");
  if (meter.maxPurchase && req.amountNgn > meter.maxPurchase) throw new QuoteError(`Maximum for this meter is ₦${meter.maxPurchase.toLocaleString("en-NG")}.`, "AMOUNT");

  const rate = effectiveRateKobo(pricing);
  const baseAmount = ngnToUsdt0(BigInt(req.amountNgn), rate);
  const tier = await deps.gateway.computeTier(payer);
  const fee = await deps.gateway.previewFee(baseAmount, tier);
  if (baseAmount + fee > (await deps.gateway.maxOrderAmount())) throw new QuoteError("That amount is above the current per-purchase limit.", "CAP");
  const cashbackUnits = cashbackUnitsFor(BigInt(req.amountNgn), baseAmount);

  const quote: Quote = {
    orderId: `0x${randomBytes(32).toString("hex")}` as Hex,
    payer,
    baseAmount,
    fee,
    tier,
    cashbackUnits,
    expiry: BigInt(Math.floor(now.getTime() / 1000) + limits.ttlSeconds),
  };
  const signature = await deps.signer.signTypedData({
    domain: gatewayDomain(deps.chainId, deps.gatewayAddress),
    types: QUOTE_TYPES,
    primaryType: "Quote",
    message: quote,
  });

  await prisma.quote.create({
    data: {
      orderId: quote.orderId,
      payer,
      serviceID: req.serviceID,
      meterNumber: req.meterNumber,
      meterType: "prepaid",
      customerName: meter.customerName,
      customerAddress: meter.address,
      phone: req.phone ?? null,
      amountNgn: req.amountNgn,
      rateKobo: rate,
      baseAmount,
      fee,
      tier,
      cashbackUnits,
      expiry: new Date(Number(quote.expiry) * 1000),
      signature,
      gateway: deps.gatewayAddress.toLowerCase(),
      chainId: deps.chainId,
      order: { create: { status: "QUOTED", payer, amount: baseAmount + fee, fee, tier, cashbackUnits } },
    },
  });

  return {
    orderId: quote.orderId,
    payer,
    baseAmount: baseAmount.toString(),
    fee: fee.toString(),
    tier,
    cashbackUnits,
    expiry: quote.expiry.toString(),
    signature,
    amountNgn: req.amountNgn,
    rateKoboPerUsdt0: rate.toString(),
    totalUsdt0: (baseAmount + fee).toString(),
    customerName: meter.customerName,
    gateway: deps.gatewayAddress,
    chainId: deps.chainId,
  };
}
