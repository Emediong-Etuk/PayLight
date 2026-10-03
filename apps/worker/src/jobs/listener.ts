import type { Hex } from "viem";
import { prisma } from "@paylight/db";
import { alert, log, transition } from "@paylight/core";
import { decodeLogs } from "../chainops";
import type { WorkerContext } from "../context";

const CURSOR = "chain-listener";

/**
 * Processes confirmed gateway/router events in pages of <= maxLogRange blocks. Idempotent: every log is recorded in
 * ChainLog by (txHash, logIndex) and state changes go through compare-and-set transitions, so replays are no-ops.
 */
export async function runListener(ctx: WorkerContext): Promise<number> {
  const head = await ctx.chain.latestBlock();
  const confirmed = head - BigInt(ctx.confirmations);
  const cursor = await prisma.chainCursor.findUnique({ where: { name: CURSOR } });
  let from = cursor ? cursor.lastBlock + 1n : ctx.startBlock;
  let processed = 0;
  while (from <= confirmed) {
    const to = from + ctx.maxLogRange - 1n < confirmed ? from + ctx.maxLogRange - 1n : confirmed;
    const logs = decodeLogs(await ctx.chain.getLogs(from, to));
    for (const l of logs) {
      const id = `${l.transactionHash}:${l.logIndex}`;
      if (await prisma.chainLog.findUnique({ where: { id } })) continue;
      await handleEvent(ctx, l as unknown as DecodedLog);
      await prisma.chainLog.create({ data: { id, block: l.blockNumber!, event: l.eventName } });
      processed++;
    }
    await prisma.chainCursor.upsert({ where: { name: CURSOR }, create: { name: CURSOR, lastBlock: to }, update: { lastBlock: to } });
    from = to + 1n;
  }
  return processed;
}

interface DecodedLog {
  eventName: string;
  args: Record<string, unknown>;
  transactionHash: Hex;
  blockNumber: bigint;
  logIndex: number;
}

async function blockTime(ctx: WorkerContext) {
  return ctx.now();
}

export async function handleEvent(ctx: WorkerContext, l: DecodedLog): Promise<void> {
  const a = l.args;
  switch (l.eventName) {
    case "OrderPaid": {
      const orderId = String(a.orderId).toLowerCase();
      const order = await prisma.order.findUnique({ where: { orderId }, include: { quote: true } });
      if (!order) {
        await alert(`OrderPaid for unknown order ${orderId} (tx ${l.transactionHash}). Needs a manual operator refund.`);
        return;
      }
      const matches =
        String(a.payer).toLowerCase() === order.payer &&
        BigInt(a.amount as bigint) === order.amount &&
        BigInt(a.fee as bigint) === order.fee &&
        Number(a.cashbackUnits) === order.cashbackUnits &&
        Number(a.tier) === order.tier;
      const data = {
        txHashPaid: l.transactionHash,
        blockPaid: l.blockNumber,
        paidAt: await blockTime(ctx),
        refundableAt: new Date(Number(a.refundableAt as bigint) * 1000),
      };
      if (matches) await transition(orderId, "PAID", "OrderPaid confirmed", data);
      else {
        await transition(orderId, "MISMATCH", "OrderPaid does not match the stored quote", data);
        await alert(`Order ${orderId} paid but does not match its quote → refunding.`);
      }
      return;
    }
    case "OrderFulfilled": {
      const orderId = String(a.orderId).toLowerCase();
      const o = await prisma.order.findUnique({ where: { orderId }, select: { status: true } });
      if (!o) return;
      if (o.status !== "SETTLED") await transition(orderId, "SETTLED", "OrderFulfilled confirmed", { txHashSettled: l.transactionHash });
      return;
    }
    case "OrderRefunded": {
      const orderId = String(a.orderId).toLowerCase();
      const o = await prisma.order.findUnique({ where: { orderId }, select: { status: true } });
      if (!o) return;
      if (o.status === "DELIVERED") await alert(`Order ${orderId} was self-refunded AFTER delivery (settlement missed the window).`);
      if (o.status !== "REFUNDED") {
        await transition(orderId, "REFUNDED", a.byOperator ? "operator refund confirmed" : "payer self-refund confirmed", {
          txHashRefund: l.transactionHash,
          refundedByOperator: Boolean(a.byOperator),
        });
      }
      return;
    }
    case "CashbackPaid": {
      const orderId = String(a.orderId).toLowerCase();
      await prisma.cashbackPayout.upsert({
        where: { orderId },
        create: { orderId, payer: String(a.payer).toLowerCase(), units: Number(a.units), txHash: l.transactionHash, block: l.blockNumber },
        update: {},
      });
      return;
    }
    default:
      log.info("event", { name: l.eventName, tx: l.transactionHash });
  }
}
