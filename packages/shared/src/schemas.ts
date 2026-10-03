import { z } from "zod";
import { SERVICE_IDS } from "./discos";

export const addressSchema = z.string().regex(/^0x[0-9a-fA-F]{40}$/, "invalid address");
export const bytes32Schema = z.string().regex(/^0x[0-9a-fA-F]{64}$/, "invalid bytes32");
export const meterNumberSchema = z.string().trim().regex(/^\d{6,15}$/, "meter number must be 6–15 digits");
export const phoneSchema = z.string().trim().regex(/^(\+?234|0)[789][01]\d{8}$/, "invalid Nigerian phone number");

export const meterVerifyRequest = z.object({
  serviceID: z.enum(SERVICE_IDS),
  meterNumber: meterNumberSchema,
  meterType: z.literal("prepaid").default("prepaid"),
  payer: addressSchema,
});
export type MeterVerifyRequest = z.infer<typeof meterVerifyRequest>;

export const quoteRequest = z.object({
  serviceID: z.enum(SERVICE_IDS),
  meterNumber: meterNumberSchema,
  meterType: z.literal("prepaid").default("prepaid"),
  amountNgn: z.coerce.number().int().min(500).max(1_000_000),
  phone: phoneSchema.optional(),
  payer: addressSchema,
});
export type QuoteRequest = z.infer<typeof quoteRequest>;

/** Wire format of a signed quote (bigints as decimal strings). */
export const quoteResponse = z.object({
  orderId: bytes32Schema,
  payer: addressSchema,
  baseAmount: z.string(),
  fee: z.string(),
  tier: z.number().int().min(0).max(2),
  cashbackUnits: z.number().int().min(0).max(50),
  expiry: z.string(),
  signature: z.string(),
  amountNgn: z.number(),
  rateKoboPerUsdt0: z.string(),
  totalUsdt0: z.string(),
  customerName: z.string(),
  gateway: addressSchema,
  chainId: z.number(),
});
export type QuoteResponse = z.infer<typeof quoteResponse>;

export const ORDER_STATUSES = [
  "QUOTED",
  "EXPIRED",
  "PAID",
  "MISMATCH",
  "PROVIDER_PENDING",
  "DELIVERED",
  "SETTLED",
  "PROVIDER_FAILED",
  "REFUNDING",
  "REFUNDED",
  "NEEDS_REVIEW",
] as const;
export type OrderStatus = (typeof ORDER_STATUSES)[number];
