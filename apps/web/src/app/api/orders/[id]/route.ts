import { prisma } from "@paylight/db";
import { bytes32Schema, explorerTx, maskMeter, discoByServiceId } from "@paylight/shared";
import { decryptToken, env } from "@paylight/core";
import { getSession } from "@/lib/session";
import { fail, handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";

/** Public: status + tx links. The signed-in owner (SIWE) also gets the meter token and units. */
export const GET = handler(async (_req: Request, { params }: { params: Promise<{ id: string }> }) => {
  const { id } = await params;
  const orderId = bytes32Schema.parse(id).toLowerCase();
  const o = await prisma.order.findUnique({ where: { orderId }, include: { quote: true } });
  if (!o) return fail("Order not found", 404);
  const owner = (await getSession()) === o.payer;
  return json({
    orderId: o.orderId,
    status: o.status,
    payer: o.payer,
    disco: discoByServiceId(o.quote.serviceID)?.name ?? o.quote.serviceID,
    meterMasked: maskMeter(o.quote.meterNumber),
    amountNgn: o.quote.amountNgn,
    amountUsdt0: o.amount.toString(),
    feeUsdt0: o.fee.toString(),
    tier: o.tier,
    cashbackUnits: o.cashbackUnits,
    refundableAt: o.refundableAt,
    createdAt: o.createdAt,
    txPaid: o.txHashPaid ? explorerTx(o.txHashPaid) : null,
    txSettled: o.txHashSettled ? explorerTx(o.txHashSettled) : null,
    txRefund: o.txHashRefund ? explorerTx(o.txHashRefund) : null,
    isOwner: owner,
    token: owner && o.meterTokenEncrypted ? decryptToken(o.meterTokenEncrypted, env().TOKEN_ENCRYPTION_KEY) : null,
    units: owner ? o.units : null,
    customerName: owner ? o.quote.customerName : null,
  });
});
