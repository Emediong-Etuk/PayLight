import { prisma, type OrderStatus, type Prisma } from "@paylight/db";

/** Allowed order transitions (BUILD_BRIEF §6.1). Every transition writes an OrderEvent. */
const ALLOWED: Record<OrderStatus, OrderStatus[]> = {
  QUOTED: ["PAID", "EXPIRED", "MISMATCH"],
  EXPIRED: ["PAID", "MISMATCH"],
  PAID: ["PROVIDER_PENDING", "MISMATCH", "REFUNDED", "NEEDS_REVIEW"],
  MISMATCH: ["REFUNDING", "REFUNDED", "NEEDS_REVIEW"],
  PROVIDER_PENDING: ["DELIVERED", "PROVIDER_FAILED", "NEEDS_REVIEW", "REFUNDED"],
  NEEDS_REVIEW: ["DELIVERED", "PROVIDER_FAILED", "REFUNDING", "REFUNDED", "SETTLED"],
  DELIVERED: ["SETTLED", "REFUNDED", "NEEDS_REVIEW"],
  PROVIDER_FAILED: ["REFUNDING", "REFUNDED", "NEEDS_REVIEW"],
  REFUNDING: ["REFUNDED", "NEEDS_REVIEW"],
  SETTLED: [],
  REFUNDED: [],
};

export const canTransition = (from: OrderStatus, to: OrderStatus) => ALLOWED[from].includes(to);
export const allowedFrom = (to: OrderStatus) => (Object.keys(ALLOWED) as OrderStatus[]).filter((f) => ALLOWED[f].includes(to));

export class TransitionError extends Error {}

/**
 * Atomically moves an order to `to` if its current status allows it (compare-and-set, safe under concurrency and
 * re-processing). Returns false (no-op) when the order is already in `to`. Throws on an illegal transition.
 */
export async function transition(
  orderId: string,
  to: OrderStatus,
  reason: string,
  data: Omit<Prisma.OrderUpdateManyMutationInput, "status"> = {},
): Promise<boolean> {
  return prisma.$transaction(async (tx) => {
    const current = await tx.order.findUnique({ where: { orderId }, select: { status: true } });
    if (!current) throw new TransitionError(`order ${orderId} not found`);
    if (current.status === to) return false;
    if (!canTransition(current.status, to)) throw new TransitionError(`illegal transition ${current.status} -> ${to} (${orderId})`);
    const res = await tx.order.updateMany({ where: { orderId, status: current.status }, data: { ...data, status: to } });
    if (res.count !== 1) throw new TransitionError(`concurrent update on ${orderId}`);
    await tx.orderEvent.create({ data: { orderId, from: current.status, to, reason } });
    return true;
  });
}
