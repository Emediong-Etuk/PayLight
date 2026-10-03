import { z } from "zod";
import { prisma } from "@paylight/db";
import { bytes32Schema, payLightGatewayAbi } from "@paylight/shared";
import { publicClient, rateLimit, walletFor } from "@paylight/core";
import { clientIp, gatewayAddress } from "@/lib/server";
import { fail, handler, json, parseBody } from "@/lib/http";

export const dynamic = "force-dynamic";

const body = z.object({
  orderId: bytes32Schema,
  validAfter: z.coerce.bigint(),
  validBefore: z.coerce.bigint(),
  v: z.number().int().min(27).max(28),
  r: bytes32Schema,
  s: bytes32Schema,
});

/**
 * Gasless payments (D-04): the user signs an EIP-3009 ReceiveWithAuthorization (nonce = orderId, to = gateway) and we
 * submit payWithAuthorization with the operator key, paying the gas. The quote comes from OUR database, the call is
 * simulated first, and funds can only move into the gateway for this exact order.
 */
export const POST = handler(async (req: Request) => {
  const b = await parseBody(req, body);
  if (!(await rateLimit(`relay:ip:${clientIp(req)}`, 20, 600)) || !(await rateLimit(`relay:o:${b.orderId.toLowerCase()}`, 3, 600))) {
    return fail("Too many attempts.", 429, "RATE_LIMIT");
  }
  const q = await prisma.quote.findUnique({ where: { orderId: b.orderId.toLowerCase() }, include: { order: true } });
  if (!q || !q.order) return fail("Quote not found", 404);
  if (q.order.status !== "QUOTED") return fail("This order was already paid or expired.", 409);
  if (q.expiry.getTime() < Date.now()) return fail("Quote expired. Please get a new quote.", 410, "EXPIRED");

  const quote = {
    orderId: q.orderId as `0x${string}`,
    payer: q.payer as `0x${string}`,
    baseAmount: q.baseAmount,
    fee: q.fee,
    tier: q.tier,
    cashbackUnits: q.cashbackUnits,
    expiry: BigInt(Math.floor(q.expiry.getTime() / 1000)),
  };
  const auth = { validAfter: b.validAfter, validBefore: b.validBefore, v: b.v, r: b.r as `0x${string}`, s: b.s as `0x${string}` };
  const wallet = walletFor("OPERATOR_PRIVATE_KEY");
  try {
    const { request } = await publicClient().simulateContract({
      account: wallet.account,
      address: gatewayAddress(),
      abi: payLightGatewayAbi,
      functionName: "payWithAuthorization",
      args: [quote, q.signature as `0x${string}`, auth],
    });
    const hash = await wallet.writeContract(request);
    return json({ txHash: hash });
  } catch (e) {
    return fail(`Payment could not be submitted: ${(e as Error).message.split("\n")[0]}`, 422, "SIMULATION");
  }
});
