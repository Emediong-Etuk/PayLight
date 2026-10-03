import { prisma } from "@paylight/db";
import { audit, requireAdmin } from "@/lib/admin";
import { fail, handler, json } from "@/lib/http";

/** Ask the worker to requery the provider now (PROVIDER_PENDING / NEEDS_REVIEW). Never re-pays. */
export const POST = handler(async (_req: Request, { params }: { params: Promise<{ id: string }> }) => {
  const admin = await requireAdmin();
  if (!admin) return fail("Admin wallet required", 403);
  const { id } = await params;
  const r = await prisma.order.updateMany({ where: { orderId: id.toLowerCase(), status: { in: ["PROVIDER_PENDING", "NEEDS_REVIEW"] } }, data: { nextActionAt: new Date() } });
  await audit(admin, "order:requery", { orderId: id, matched: r.count });
  return json({ scheduled: r.count === 1 });
});
