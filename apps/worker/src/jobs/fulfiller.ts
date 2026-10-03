import { prisma } from "@paylight/db";
import { alert, encryptToken, log, newRequestId, transition, type ProviderOutcome } from "@paylight/core";
import type { WorkerContext } from "../context";

/**
 * PAID → (store request_id) → PROVIDER_PENDING → one purchase() → DELIVERED | PROVIDER_FAILED | requery later.
 * The request_id is written in the SAME atomic transition that leaves PAID, before the provider is called. purchase()
 * is only ever invoked from the PAID state, so a crash or retry can never pay twice: it requeries instead.
 */
export async function runFulfiller(ctx: WorkerContext): Promise<void> {
  const paid = await prisma.order.findMany({ where: { status: "PAID" }, include: { quote: true }, orderBy: { paidAt: "asc" }, take: 10 });
  for (const o of paid) {
    const requestId = newRequestId(ctx.now());
    const moved = await transition(o.orderId, "PROVIDER_PENDING", "vending", { providerRequestId: requestId, requeryCount: 0, nextActionAt: null });
    if (!moved) continue;
    log.info("purchase", { orderId: o.orderId, requestId, serviceID: o.quote.serviceID, amountNgn: o.quote.amountNgn });
    const outcome = await ctx.provider.purchase({
      requestId,
      serviceID: o.quote.serviceID,
      meterNumber: o.quote.meterNumber,
      amountNgn: o.quote.amountNgn,
      phone: o.quote.phone ?? ctx.defaultPhone,
    });
    await applyOutcome(ctx, o.orderId, outcome, 0);
  }

  // Requery loop for PROVIDER_PENDING orders whose backoff has elapsed (also recovers crashes mid-purchase).
  const due = await prisma.order.findMany({
    where: { status: "PROVIDER_PENDING", OR: [{ nextActionAt: null }, { nextActionAt: { lte: ctx.now() } }] },
    take: 20,
  });
  for (const o of due) {
    if (!o.providerRequestId) {
      await transition(o.orderId, "NEEDS_REVIEW", "PROVIDER_PENDING without request_id");
      await alert(`Order ${o.orderId} is pending without a request_id`);
      continue;
    }
    // A fresh pending order (nextActionAt null, 0 requeries) right after purchase() is handled above; here we requery.
    const outcome = await ctx.provider.requery(o.providerRequestId);
    await applyOutcome(ctx, o.orderId, outcome, o.requeryCount + 1);
  }
}

export async function applyOutcome(ctx: WorkerContext, orderId: string, outcome: ProviderOutcome, attempt: number): Promise<void> {
  const raw = (outcome.raw ?? null) as object | null;
  switch (outcome.kind) {
    case "delivered":
      await transition(orderId, "DELIVERED", "provider delivered token", {
        meterTokenEncrypted: encryptToken(outcome.token, ctx.encryptionKey),
        units: outcome.units,
        providerTxId: outcome.providerTxId,
        providerStatus: "delivered",
        providerCode: outcome.code,
        providerRaw: raw ?? undefined,
        nextActionAt: ctx.now(), // settle immediately
        requeryCount: 0, // reused by the settler as its attempt counter
      });
      return;
    case "failed":
      await transition(orderId, "PROVIDER_FAILED", `provider failed definitively: ${outcome.reason}`, {
        providerStatus: "failed",
        providerCode: outcome.code,
        providerRaw: raw ?? undefined,
        lastError: outcome.reason,
      });
      return;
    case "pending":
    case "unknown": {
      const delay = ctx.requeryBackoffSec[attempt];
      if (delay === undefined) {
        await transition(orderId, "NEEDS_REVIEW", `status still ${outcome.kind} after ${attempt} requeries`, {
          providerStatus: outcome.kind,
          providerCode: outcome.code,
          lastError: outcome.kind === "unknown" ? outcome.reason : null,
          nextActionAt: new Date(ctx.now().getTime() + 600_000),
        });
        await alert(`Order ${orderId} NEEDS_REVIEW: provider status ${outcome.kind} after ${attempt} requeries. Not refunded automatically.`);
        return;
      }
      await prisma.order.update({
        where: { orderId },
        data: {
          requeryCount: attempt,
          providerStatus: outcome.kind,
          providerCode: outcome.code,
          lastError: outcome.kind === "unknown" ? outcome.reason : null,
          nextActionAt: new Date(ctx.now().getTime() + delay * 1000),
        },
      });
      return;
    }
  }
}

/** NEEDS_REVIEW orders keep being requeried every 10 minutes and auto-resolve on a definitive answer. */
export async function runReviewRequery(ctx: WorkerContext): Promise<void> {
  const due = await prisma.order.findMany({
    where: { status: "NEEDS_REVIEW", providerRequestId: { not: null }, nextActionAt: { lte: ctx.now() }, txHashSettled: null, txHashRefund: null },
    take: 20,
  });
  for (const o of due) {
    const outcome = await ctx.provider.requery(o.providerRequestId!);
    if (outcome.kind === "delivered" || outcome.kind === "failed") {
      await applyOutcome(ctx, o.orderId, outcome, 0);
      await alert(`Order ${o.orderId} auto-resolved from NEEDS_REVIEW: ${outcome.kind}`);
    } else {
      await prisma.order.update({ where: { orderId: o.orderId }, data: { nextActionAt: new Date(ctx.now().getTime() + 600_000) } });
    }
  }
}
