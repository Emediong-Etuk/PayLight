import { prisma } from "@paylight/db";
import { maskMeter } from "@paylight/shared";
import { requireAdmin } from "@/lib/admin";
import { fail, handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";
export const GET = handler(async (_req: Request, { params }: { params: Promise<{ id: string }> }) => {
  if (!(await requireAdmin())) return fail("Admin wallet required", 403);
  const { id } = await params;
  const o = await prisma.order.findUnique({ where: { orderId: id.toLowerCase() }, include: { quote: true, events: { orderBy: { id: "asc" } } } });
  if (!o) return fail("Not found", 404);
  const { meterTokenEncrypted: _t, ...rest } = o;
  return json({ ...rest, quote: { ...o.quote, meterNumber: maskMeter(o.quote.meterNumber) }, hasToken: Boolean(o.meterTokenEncrypted) });
});
