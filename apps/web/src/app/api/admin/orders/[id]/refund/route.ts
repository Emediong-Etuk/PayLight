import { prisma } from "@paylight/db";
import { transition } from "@paylight/core";
import { audit, requireAdmin } from "@/lib/admin";
import { fail, handler, json } from "@/lib/http";

/** Operator refund for a reviewed order. The worker's refunder sends the on-chain refund(). */
export const POST = handler(async (_req: Request, { params }: { params: Promise<{ id: string }> }) => {
  const admin = await requireAdmin();
  if (!admin) return fail("Admin wallet required", 403);
  const { id } = await params;
  const o = await prisma.order.findUnique({ where: { orderId: id.toLowerCase() } });
  if (!o) return fail("Not found", 404);
  if (!["NEEDS_REVIEW", "PROVIDER_FAILED", "MISMATCH"].includes(o.status)) return fail(`Can't refund an order in ${o.status}`, 409);
  await transition(o.orderId, "REFUNDING", `admin refund by ${admin}`, { requeryCount: 0, nextActionAt: null });
  await audit(admin, "order:refund", { orderId: o.orderId, from: o.status });
  return json({ ok: true });
});
