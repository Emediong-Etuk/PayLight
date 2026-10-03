import { meterVerifyRequest, maskAddress } from "@paylight/shared";
import { getProvider, MeterVerificationError, rateLimit } from "@paylight/core";
import { clientIp } from "@/lib/server";
import { fail, handler, json, parseBody } from "@/lib/http";

export const dynamic = "force-dynamic";

/** Meter-owner lookup. Requires a wallet address and is rate-limited per wallet and per IP (stops lookups at scale). */
export const POST = handler(async (req: Request) => {
  const body = await parseBody(req, meterVerifyRequest);
  const ip = clientIp(req);
  const okWallet = await rateLimit(`verify:w:${body.payer.toLowerCase()}`, 10, 600);
  const okIp = await rateLimit(`verify:ip:${ip}`, 30, 600);
  if (!okWallet || !okIp) return fail("Too many meter lookups. Please wait a few minutes.", 429, "RATE_LIMIT");
  try {
    const m = await getProvider().verifyMeter(body.serviceID, body.meterNumber, "prepaid");
    return json({ customerName: m.customerName, addressMasked: m.address ? maskAddress(m.address) : null, minPurchase: m.minPurchase, maxPurchase: m.maxPurchase });
  } catch (e) {
    if (e instanceof MeterVerificationError) return fail(e.message, e.retryable ? 503 : 422, "METER");
    throw e;
  }
});
