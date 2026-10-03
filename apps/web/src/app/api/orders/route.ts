import { prisma } from "@paylight/db";
import { maskMeter, discoByServiceId } from "@paylight/shared";
import { getSession } from "@/lib/session";
import { fail, handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";

/** The signed-in wallet's purchase history (most recent first). */
export const GET = handler(async () => {
  const me = await getSession();
  if (!me) return fail("Sign in with your wallet to see your history.", 401);
  const orders = await prisma.order.findMany({
    where: { payer: me, status: { notIn: ["QUOTED", "EXPIRED"] } },
    include: { quote: true },
    orderBy: { createdAt: "desc" },
    take: 50,
  });
  return json(
    orders.map((o) => ({
      orderId: o.orderId,
      status: o.status,
      disco: discoByServiceId(o.quote.serviceID)?.name ?? o.quote.serviceID,
      serviceID: o.quote.serviceID,
      meterNumber: o.quote.meterNumber, // owner-only endpoint: needed for "Buy again"
      meterMasked: maskMeter(o.quote.meterNumber),
      amountNgn: o.quote.amountNgn,
      createdAt: o.createdAt,
    })),
  );
});
