import { DISCOS } from "@paylight/shared";
import { getProvider } from "@paylight/core";
import { handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";
let cache: { at: number; data: unknown } | undefined;

/** Supported discos with live min/max amounts from the provider (cached 10 min; falls back to the static list). */
export const GET = handler(async () => {
  if (cache && Date.now() - cache.at < 600_000) return json(cache.data);
  const live = await getProvider().listDiscos().catch(() => []);
  const data = DISCOS.map((d) => {
    const l = live.find((x) => x.serviceID === d.serviceID);
    return { ...d, minAmount: l?.minAmount ?? 500, maxAmount: l?.maxAmount ?? null };
  });
  cache = { at: Date.now(), data };
  return json(data);
});
