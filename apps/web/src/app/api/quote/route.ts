import { quoteRequest } from "@paylight/shared";
import { createQuote, QuoteError, rateLimit } from "@paylight/core";
import { clientIp, quoteDeps } from "@/lib/server";
import { fail, handler, json, parseBody } from "@/lib/http";

export const dynamic = "force-dynamic";

/** Re-verifies the meter, checks float, caps and the on-chain fee tier, then returns an EIP-712 signed quote. */
export const POST = handler(async (req: Request) => {
  const body = await parseBody(req, quoteRequest);
  if (!(await rateLimit(`quote:w:${body.payer.toLowerCase()}`, 20, 600)) || !(await rateLimit(`quote:ip:${clientIp(req)}`, 60, 600))) {
    return fail("Too many quotes. Please wait a few minutes.", 429, "RATE_LIMIT");
  }
  try {
    return json(await createQuote(body, await quoteDeps()));
  } catch (e) {
    if (e instanceof QuoteError) return fail(e.message, e.code === "METER" || e.code === "AMOUNT" || e.code === "CAP" ? 422 : 503, e.code);
    throw e;
  }
});
