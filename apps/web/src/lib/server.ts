import "server-only";
import type { Address } from "viem";
import {
  env,
  getPricing,
  getProvider,
  publicClient,
  quoteSignerAccount,
  requireAddress,
  viemGatewayReader,
  type QuoteDeps,
} from "@paylight/core";

let floatCache: { at: number; value: number } | undefined;
/** Provider NGN float, cached for 60s so quotes don't hammer VTpass. */
export async function cachedFloat(): Promise<number> {
  if (floatCache && Date.now() - floatCache.at < 60_000) return floatCache.value;
  const value = await getProvider().getWalletBalance();
  floatCache = { at: Date.now(), value };
  return value;
}

export async function quoteDeps(): Promise<QuoteDeps> {
  const e = env();
  const gatewayAddress = requireAddress("GATEWAY_ADDRESS");
  return {
    provider: getProvider(),
    gateway: viemGatewayReader(publicClient(), gatewayAddress),
    gatewayAddress,
    chainId: e.CHAIN_ID,
    signer: quoteSignerAccount(),
    pricing: await getPricing(),
    limits: { maxOrderNgn: e.MAX_ORDER_NGN, dailyWalletCapNgn: e.DAILY_WALLET_CAP_NGN, floatMinNgn: e.FLOAT_MIN_NGN, ttlSeconds: e.QUOTE_TTL_SECONDS },
    floatNgn: cachedFloat,
  };
}

export const gatewayAddress = (): Address => requireAddress("GATEWAY_ADDRESS");

/** Best-effort client IP behind Railway/Vercel proxies. */
export const clientIp = (req: Request) => req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || req.headers.get("x-real-ip") || "unknown";
