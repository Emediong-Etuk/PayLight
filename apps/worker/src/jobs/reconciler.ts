import type { Hex } from "viem";
import { prisma, type OrderStatus } from "@paylight/db";
import { alert, transition } from "@paylight/core";
import type { WorkerContext } from "../context";

/** Which on-chain statuses are consistent with each DB status. */
const CONSISTENT: Partial<Record<OrderStatus, string[]>> = {
  PAID: ["Paid"],
  PROVIDER_PENDING: ["Paid"],
  DELIVERED: ["Paid", "Fulfilled"],
  PROVIDER_FAILED: ["Paid", "Refunded"],
  REFUNDING: ["Paid", "Refunded"],
  SETTLED: ["Fulfilled"],
  REFUNDED: ["Refunded"],
};

/**
 * Every 10 min: (1) expire stale quotes; (2) compare active/recent orders with the gateway at the `safe` head.
 * Anything inconsistent → NEEDS_REVIEW + alert. Orders newer than the safe head are skipped this round.
 */
export async function runReconciler(ctx: WorkerContext): Promise<{ checked: number; mismatches: number }> {
  const graceMs = 5 * 60_000;
  const stale = await prisma.order.findMany({ where: { status: "QUOTED", quote: { expiry: { lt: new Date(ctx.now().getTime() - graceMs) } } }, select: { orderId: true }, take: 200 });
  for (const s of stale) await transition(s.orderId, "EXPIRED", "quote expired without payment").catch(() => undefined);

  const safe = await ctx.chain.safeBlock();
  const since = new Date(ctx.now().getTime() - 3 * 24 * 3600_000);
  const orders = await prisma.order.findMany({
    where: { status: { in: Object.keys(CONSISTENT) as OrderStatus[] }, updatedAt: { gte: since }, blockPaid: { lte: safe } },
    take: 300,
  });
  let mismatches = 0;
  for (const o of orders) {
    const onchain = await ctx.chain.getOrder(o.orderId as Hex, safe);
    const ok = CONSISTENT[o.status]!.includes(onchain.status);
    const amountOk = onchain.status === "None" || onchain.amount === o.amount;
    if (ok && amountOk) continue;
    // DB may simply be ahead of `safe` for settle/refund txs mined after the safe head: tolerate that.
    const aheadOfSafe = (o.status === "SETTLED" || o.status === "REFUNDED") && onchain.status === "Paid";
    if (aheadOfSafe) continue;
    mismatches++;
    if (o.status !== "SETTLED" && o.status !== "REFUNDED") {
      await transition(o.orderId, "NEEDS_REVIEW", `reconciler: DB ${o.status} vs chain ${onchain.status}`).catch(() => undefined);
    }
    await alert(`Reconciler mismatch on ${o.orderId}: DB ${o.status}, chain ${onchain.status}${amountOk ? "" : " (amount differs)"}`);
  }
  return { checked: orders.length, mismatches };
}
