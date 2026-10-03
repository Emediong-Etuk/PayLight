import type { Hex } from "viem";
import { prisma } from "@paylight/db";
import { alert, log, transition } from "@paylight/core";
import { receiptHashFor } from "../chainops";
import type { WorkerContext } from "../context";

const SETTLE_RETRY_SEC = [15, 30, 60, 120, 300, 600, 1800];

/** DELIVERED → markFulfilled on-chain → SETTLED. Deliver first, settle second (brief §6.2 rule 3). */
export async function runSettler(ctx: WorkerContext): Promise<void> {
  const due = await prisma.order.findMany({
    where: { status: "DELIVERED", OR: [{ nextActionAt: null }, { nextActionAt: { lte: ctx.now() } }] },
    take: 10,
  });
  for (const o of due) {
    if (o.refundableAt && ctx.now() > o.refundableAt) {
      await transition(o.orderId, "NEEDS_REVIEW", "delivered but the on-chain settlement window has closed");
      await alert(`Order ${o.orderId} was delivered but couldn't be settled before its refund deadline.`);
      continue;
    }
    const attempt = o.requeryCount;
    try {
      const onchain = await ctx.chain.getOrder(o.orderId as Hex);
      if (onchain.status === "Fulfilled") {
        await transition(o.orderId, "SETTLED", "already fulfilled on-chain");
        continue;
      }
      if (onchain.status !== "Paid") {
        await transition(o.orderId, "NEEDS_REVIEW", `on-chain status ${onchain.status} while DELIVERED`);
        await alert(`Order ${o.orderId}: delivered off-chain but on-chain status is ${onchain.status}.`);
        continue;
      }
      const hash = await ctx.chain.markFulfilled(o.orderId as Hex, receiptHashFor(o.providerTxId ?? o.providerRequestId ?? o.orderId));
      log.info("markFulfilled sent", { orderId: o.orderId, hash });
      if (await ctx.chain.waitSuccess(hash)) {
        await transition(o.orderId, "SETTLED", "markFulfilled mined", { txHashSettled: hash, requeryCount: 0 });
      } else throw new Error(`markFulfilled reverted (${hash})`);
    } catch (e) {
      const delay = SETTLE_RETRY_SEC[Math.min(attempt, SETTLE_RETRY_SEC.length - 1)]!;
      await prisma.order.update({
        where: { orderId: o.orderId },
        data: { requeryCount: attempt + 1, lastError: (e as Error).message.slice(0, 500), nextActionAt: new Date(ctx.now().getTime() + delay * 1000) },
      });
      if (attempt + 1 === 3 || attempt + 1 === SETTLE_RETRY_SEC.length) await alert(`Settling order ${o.orderId} failing (${attempt + 1}x): ${(e as Error).message.slice(0, 200)}`);
    }
  }
}

/** PROVIDER_FAILED / MISMATCH → REFUNDING → refund on-chain → REFUNDED. Only definitive failures get here. */
export async function runRefunder(ctx: WorkerContext): Promise<void> {
  const failed = await prisma.order.findMany({ where: { status: { in: ["PROVIDER_FAILED", "MISMATCH"] } }, take: 10 });
  for (const o of failed) await transition(o.orderId, "REFUNDING", "auto-refund after definitive failure", { requeryCount: 0, nextActionAt: null });

  const due = await prisma.order.findMany({
    where: { status: "REFUNDING", OR: [{ nextActionAt: null }, { nextActionAt: { lte: ctx.now() } }] },
    take: 10,
  });
  for (const o of due) {
    try {
      const onchain = await ctx.chain.getOrder(o.orderId as Hex);
      if (onchain.status === "Refunded") {
        await transition(o.orderId, "REFUNDED", "already refunded on-chain");
        continue;
      }
      if (onchain.status !== "Paid") {
        await transition(o.orderId, "NEEDS_REVIEW", `refund wanted but on-chain status ${onchain.status}`);
        await alert(`Order ${o.orderId}: refund wanted but on-chain status is ${onchain.status}.`);
        continue;
      }
      const hash = await ctx.chain.refund(o.orderId as Hex);
      if (await ctx.chain.waitSuccess(hash)) await transition(o.orderId, "REFUNDED", "operator refund mined", { txHashRefund: hash, refundedByOperator: true });
      else throw new Error(`refund reverted (${hash})`);
    } catch (e) {
      const attempt = o.requeryCount + 1;
      await prisma.order.update({
        where: { orderId: o.orderId },
        data: { requeryCount: attempt, lastError: (e as Error).message.slice(0, 500), nextActionAt: new Date(ctx.now().getTime() + Math.min(60 * attempt, 1800) * 1000) },
      });
      if (attempt === 3) await alert(`Refund for ${o.orderId} failing: ${(e as Error).message.slice(0, 200)}`);
    }
  }
}
