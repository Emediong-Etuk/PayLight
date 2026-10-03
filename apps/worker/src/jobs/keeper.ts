import type { Hex } from "viem";
import { prisma } from "@paylight/db";
import { alert, log } from "@paylight/core";
import type { WorkerContext } from "../context";

/**
 * Pays out transistor cashback for settled orders via the permissionless CashbackRouter.distribute.
 * Runs when >= minBatch orders are waiting, or the oldest has waited >= maxWaitSec. Alerts when the reserve is low.
 */
export async function runCashbackKeeper(ctx: WorkerContext, opts = { minBatch: 5, maxWaitSec: 1800, maxBatch: 40 }): Promise<void> {
  const paidIds = new Set((await prisma.cashbackPayout.findMany({ select: { orderId: true } })).map((r) => r.orderId));
  const settled = await prisma.order.findMany({
    where: { status: "SETTLED", cashbackUnits: { gt: 0 } },
    orderBy: { updatedAt: "asc" },
    select: { orderId: true, updatedAt: true, cashbackUnits: true },
    take: 500,
  });
  const waiting = settled.filter((o) => !paidIds.has(o.orderId));
  if (waiting.length === 0) return;
  const oldestAge = (ctx.now().getTime() - waiting[0]!.updatedAt.getTime()) / 1000;
  if (waiting.length < opts.minBatch && oldestAge < opts.maxWaitSec) return;

  const batch = waiting.slice(0, opts.maxBatch);
  const units = batch.reduce((s, o) => s + o.cashbackUnits, 0);
  const free = await ctx.chain.routerFreeReserve().catch(() => 0n);
  if (free < BigInt(units * 2)) await alert(`Cashback reserve is low (${free} free transistors, ${units} needed now). Top up the router.`);
  try {
    const hash = await ctx.chain.distribute(batch.map((o) => o.orderId as Hex));
    log.info("distribute sent", { hash, orders: batch.length, units });
    await ctx.chain.waitSuccess(hash);
  } catch (e) {
    log.error("distribute failed", { err: (e as Error).message });
  }
}
