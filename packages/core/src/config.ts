import { prisma } from "@paylight/db";

/** Audited runtime config, editable from /admin. Every write records who changed it. */
export const CONFIG_KEYS = {
  rateKobo: "rate_kobo_per_usdt0", // e.g. "135200" = ₦1,352.00 per USD₮0
  spreadBps: "spread_bps", // e.g. "150" = 1.5%; user pays (1 + spread) worth of USD₮0
  quotesPaused: "quotes_paused", // "true" | "false"
  rateUpdatedAt: "rate_updated_at",
  autoPausedReason: "quotes_auto_paused_reason", // set by the worker's float/gas monitor; empty = not paused
} as const;

export async function getConfig(key: string): Promise<string | null> {
  return (await prisma.config.findUnique({ where: { key } }))?.value ?? null;
}

export async function setConfig(key: string, value: string, actor: string): Promise<void> {
  await prisma.$transaction([
    prisma.config.upsert({ where: { key }, create: { key, value, updatedBy: actor }, update: { value, updatedBy: actor } }),
    prisma.adminAudit.create({ data: { actor, action: `config:${key}`, payload: { value } } }),
  ]);
}

export interface PricingConfig {
  rateKobo: bigint;
  spreadBps: number;
  quotesPaused: boolean;
  rateUpdatedAt: Date | null;
}

export async function getPricing(): Promise<PricingConfig> {
  const rows = await prisma.config.findMany({ where: { key: { in: Object.values(CONFIG_KEYS) } } });
  const m = new Map(rows.map((r) => [r.key, r.value]));
  return {
    rateKobo: BigInt(m.get(CONFIG_KEYS.rateKobo) ?? "0"),
    spreadBps: Number(m.get(CONFIG_KEYS.spreadBps) ?? "0"),
    quotesPaused: (m.get(CONFIG_KEYS.quotesPaused) ?? "false") === "true" || (m.get(CONFIG_KEYS.autoPausedReason) ?? "") !== "",
    rateUpdatedAt: m.get(CONFIG_KEYS.rateUpdatedAt) ? new Date(m.get(CONFIG_KEYS.rateUpdatedAt)!) : null,
  };
}

/** NGN-per-USD₮0 rate after spread: a lower rate means the user pays slightly more USD₮0. */
export const effectiveRateKobo = (p: Pick<PricingConfig, "rateKobo" | "spreadBps">) =>
  (p.rateKobo * BigInt(10_000 - p.spreadBps)) / 10_000n;
