import { env } from "@paylight/core";
import { USDT0, XLAYER } from "@paylight/shared";
import { handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";

/** Public, non-secret deployment config for the browser. */
export const GET = handler(async () => {
  const e = env();
  return json({
    chainId: e.CHAIN_ID,
    rpcUrl: e.CHAIN_ID === XLAYER.chainId ? XLAYER.rpcUrls[0] : e.RPC_URL,
    gateway: e.GATEWAY_ADDRESS ?? null,
    router: e.CASHBACK_ROUTER_ADDRESS ?? null,
    processor: e.PROCESSOR_ADDRESS ?? null,
    usdt0: e.USDT0_ADDRESS ?? USDT0.address,
    explorer: XLAYER.explorer,
    gaslessEnabled: Boolean(process.env.OPERATOR_PRIVATE_KEY),
  });
});
