import { prisma, type OrderStatus } from "@paylight/db";
import { ORDER_STATUSES, maskMeter } from "@paylight/shared";
import { requireAdmin } from "@/lib/admin";
import { fail, handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";
export const GET = handler(async (req: Request) => {
  if (!(await requireAdmin())) return fail("Admin wallet required", 403);
  const s = new URL(req.url).searchParams.get("status");
  const where = s && (ORDER_STATUSES as readonly string[]).includes(s) ? { status: s as OrderStatus } : { status: { notIn: ["QUOTED", "EXPIRED"] as OrderStatus[] } };
  const orders = await prisma.order.findMany({ where, include: { quote: true }, orderBy: { createdAt: "desc" }, take: 200 });
  return json(orders.map((o) => ({ orderId: o.orderId, status: o.status, payer: o.payer, amountNgn: o.quote.amountNgn, serviceID: o.quote.serviceID, meter: maskMeter(o.quote.meterNumber), providerStatus: o.providerStatus, lastError: o.lastError, createdAt: o.createdAt, updatedAt: o.updatedAt })));
});
