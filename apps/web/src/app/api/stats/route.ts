import { prisma } from "@paylight/db";
import { handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";
let cache: { at: number; data: unknown } | undefined;

/** Totals for the landing and transparency pages. Every figure is derived from indexed on-chain events. */
export const GET = handler(async () => {
  if (cache && Date.now() - cache.at < 30_000) return json(cache.data);
  const settled = await prisma.order.findMany({ where: { status: "SETTLED" }, select: { payer: true, amount: true, quote: { select: { amountNgn: true } } } });
  const payouts = await prisma.cashbackPayout.aggregate({ _count: true, _sum: { units: true } });
  const refunded = await prisma.order.count({ where: { status: "REFUNDED" } });
  const data = {
    billsPaid: settled.length,
    uniquePayers: new Set(settled.map((o) => o.payer)).size,
    ngnDelivered: settled.reduce((s, o) => s + o.quote.amountNgn, 0),
    usdt0Processed: settled.reduce((s, o) => s + o.amount, 0n).toString(),
    cashbackPayouts: payouts._count,
    cashbackUnits: payouts._sum.units ?? 0,
    refunds: refunded,
  };
  cache = { at: Date.now(), data };
  return json(data);
});
