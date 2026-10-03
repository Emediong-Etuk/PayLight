import { beforeEach, describe, expect, it } from "vitest";
import { recoverTypedDataAddress, type Address } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { prisma } from "@paylight/db";
import { QUOTE_TYPES, feeFor, gatewayDomain } from "@paylight/shared";
import { MockProvider } from "../src/provider/mock";
import { createQuote, QuoteError, type QuoteDeps } from "../src/quote";
import { transition, TransitionError } from "../src/orders";
import { rateLimit } from "../src/ratelimit";

const GATEWAY = "0x00000000000000000000000000000000ca11ab1e" as Address;
const PAYER = "0x000000000000000000000000000000000000BEEF" as Address;

async function reset() {
  await prisma.orderEvent.deleteMany();
  await prisma.order.deleteMany();
  await prisma.quote.deleteMany();
  await prisma.rateLimit.deleteMany();
}

function deps(over: Partial<QuoteDeps> = {}): QuoteDeps {
  return {
    provider: new MockProvider(),
    gateway: { computeTier: async () => 0, previewFee: async (b, t) => feeFor(b, [100, 50, 25][t]!), maxOrderAmount: async () => 30_000_000n },
    gatewayAddress: GATEWAY,
    chainId: 196,
    signer: privateKeyToAccount(generatePrivateKey()),
    pricing: { rateKobo: 135_200n, spreadBps: 150, quotesPaused: false, rateUpdatedAt: new Date() },
    limits: { maxOrderNgn: 40_000, dailyWalletCapNgn: 80_000, floatMinNgn: 5_000, ttlSeconds: 120 },
    floatNgn: async () => 500_000,
    ...over,
  };
}
const req = { serviceID: "portharcourt-electric" as const, meterNumber: MockProvider.METERS.success, meterType: "prepaid" as const, amountNgn: 5_000, payer: PAYER };

describe("quote engine", () => {
  beforeEach(reset);

  it("creates a signed quote that recovers to the signer and persists Quote + Order(QUOTED)", async () => {
    const d = deps();
    const q = await createQuote(req, d);
    // effective rate = 1352 * (1 - 1.5%) = 1331.72 -> 5000/1331.72 = 3.75454239... USD₮0, rounded UP to 3.754543
    expect(q.rateKoboPerUsdt0).toBe("133172");
    expect(q.baseAmount).toBe("3754543");
    expect(BigInt(q.fee)).toBe(feeFor(3_754_543n, 100));
    expect(q.cashbackUnits).toBe(5);
    expect(q.customerName).toBe("TESTMETER ONE");
    const signer = await recoverTypedDataAddress({
      domain: gatewayDomain(196, GATEWAY),
      types: QUOTE_TYPES,
      primaryType: "Quote",
      message: { orderId: q.orderId as `0x${string}`, payer: q.payer as Address, baseAmount: BigInt(q.baseAmount), fee: BigInt(q.fee), tier: q.tier, cashbackUnits: q.cashbackUnits, expiry: BigInt(q.expiry) },
      signature: q.signature as `0x${string}`,
    });
    expect(signer).toBe(d.signer.address);
    const order = await prisma.order.findUniqueOrThrow({ where: { orderId: q.orderId } });
    expect(order.status).toBe("QUOTED");
    expect(order.payer).toBe(PAYER.toLowerCase());
    expect(order.amount).toBe(BigInt(q.totalUsdt0));
  });

  it("refuses when paused, rate missing/stale, float low, over caps, or meter invalid", async () => {
    await expect(createQuote(req, deps({ pricing: { rateKobo: 135_200n, spreadBps: 0, quotesPaused: true, rateUpdatedAt: null } }))).rejects.toMatchObject({ code: "PAUSED" });
    await expect(createQuote(req, deps({ pricing: { rateKobo: 0n, spreadBps: 0, quotesPaused: false, rateUpdatedAt: null } }))).rejects.toMatchObject({ code: "NO_RATE" });
    await expect(createQuote(req, deps({ pricing: { rateKobo: 135_200n, spreadBps: 0, quotesPaused: false, rateUpdatedAt: new Date(Date.now() - 48 * 3600_000) } }))).rejects.toMatchObject({ code: "NO_RATE" });
    await expect(createQuote(req, deps({ floatNgn: async () => 8_000 }))).rejects.toMatchObject({ code: "FLOAT" });
    await expect(createQuote({ ...req, amountNgn: 50_000 }, deps())).rejects.toMatchObject({ code: "CAP" });
    await expect(createQuote({ ...req, meterNumber: "999999999" }, deps())).rejects.toBeInstanceOf(QuoteError);
    await expect(createQuote(req, deps({ gateway: { computeTier: async () => 0, previewFee: async () => 0n, maxOrderAmount: async () => 1_000_000n } }))).rejects.toMatchObject({ code: "CAP" });
  });

  it("enforces the per-wallet daily naira cap over PAID orders", async () => {
    const d = deps();
    for (let i = 0; i < 2; i++) {
      const q = await createQuote({ ...req, amountNgn: 30_000 }, d);
      await prisma.order.update({ where: { orderId: q.orderId }, data: { status: "PAID", paidAt: new Date() } });
    }
    await expect(createQuote({ ...req, amountNgn: 25_000 }, d)).rejects.toMatchObject({ code: "CAP" }); // 60k + 25k > 80k
    await expect(createQuote({ ...req, amountNgn: 20_000 }, d)).resolves.toBeTruthy(); // 60k + 20k == 80k is fine
  });
});

describe("order state machine", () => {
  beforeEach(reset);

  it("allows legal transitions, logs events, is idempotent, rejects illegal ones", async () => {
    const q = await createQuote(req, deps());
    expect(await transition(q.orderId, "PAID", "OrderPaid seen")).toBe(true);
    expect(await transition(q.orderId, "PAID", "replayed event")).toBe(false); // idempotent re-processing
    await expect(transition(q.orderId, "SETTLED", "skip")).rejects.toBeInstanceOf(TransitionError);
    await transition(q.orderId, "PROVIDER_PENDING", "vend");
    await transition(q.orderId, "DELIVERED", "token");
    await transition(q.orderId, "SETTLED", "markFulfilled mined");
    await expect(transition(q.orderId, "REFUNDED", "after settle")).rejects.toBeInstanceOf(TransitionError);
    const events = await prisma.orderEvent.findMany({ where: { orderId: q.orderId }, orderBy: { id: "asc" } });
    expect(events.map((e) => e.to)).toEqual(["PAID", "PROVIDER_PENDING", "DELIVERED", "SETTLED"]);
  });

  it("concurrent identical transitions apply exactly once", async () => {
    const q = await createQuote(req, deps());
    await transition(q.orderId, "PAID", "x");
    const results = await Promise.allSettled(Array.from({ length: 5 }, () => transition(q.orderId, "PROVIDER_PENDING", "race")));
    const applied = results.filter((r) => r.status === "fulfilled" && r.value === true).length;
    expect(applied).toBe(1);
    expect(await prisma.orderEvent.count({ where: { orderId: q.orderId, to: "PROVIDER_PENDING" } })).toBe(1);
  });
});

describe("rate limit", () => {
  beforeEach(reset);
  it("fixed window", async () => {
    const now = new Date();
    for (let i = 0; i < 3; i++) expect(await rateLimit("k", 3, 60, now)).toBe(true);
    expect(await rateLimit("k", 3, 60, now)).toBe(false);
    expect(await rateLimit("k", 3, 60, new Date(now.getTime() + 61_000))).toBe(true);
  });
});
