import { z } from "zod";
import { CONFIG_KEYS, getConfig, getPricing, getProvider, setConfig, parseRate } from "./helpers";
import { audit, requireAdmin } from "@/lib/admin";
import { fail, handler, json, parseBody } from "@/lib/http";

export const dynamic = "force-dynamic";

export const GET = handler(async () => {
  if (!(await requireAdmin())) return fail("Admin wallet required", 403);
  const p = await getPricing();
  const float = await getProvider().getWalletBalance().catch(() => null);
  return json({ ...p, rateKobo: p.rateKobo.toString(), autoPausedReason: await getConfig(CONFIG_KEYS.autoPausedReason), providerFloatNgn: float });
});

const body = z.object({
  rate: z.string().optional(), // NGN per USD₮0, e.g. "1352.50"
  spreadBps: z.number().int().min(0).max(1000).optional(),
  quotesPaused: z.boolean().optional(),
});

export const POST = handler(async (req: Request) => {
  const admin = await requireAdmin();
  if (!admin) return fail("Admin wallet required", 403);
  const b = await parseBody(req, body);
  if (b.rate !== undefined) {
    const kobo = parseRate(b.rate);
    if (kobo < 50_000n || kobo > 1_000_000n) return fail("Rate must be between ₦500 and ₦10,000 per USD₮0", 400);
    await setConfig(CONFIG_KEYS.rateKobo, kobo.toString(), admin);
    await setConfig(CONFIG_KEYS.rateUpdatedAt, new Date().toISOString(), admin);
  }
  if (b.spreadBps !== undefined) await setConfig(CONFIG_KEYS.spreadBps, String(b.spreadBps), admin);
  if (b.quotesPaused !== undefined) await setConfig(CONFIG_KEYS.quotesPaused, String(b.quotesPaused), admin);
  await audit(admin, "config:update", b);
  return json({ ok: true });
});
