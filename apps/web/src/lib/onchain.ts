import "server-only";
import type { Address } from "viem";
import { cashbackRouterAbi, payLightGatewayAbi, tapeoutTransistorsAbi } from "@paylight/shared";
import { env, publicClient } from "@paylight/core";

const addr = (v?: string) => (v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined);

/** Live on-chain facts for /light and /transparency. Returns nulls when contracts aren't configured yet. */
export async function onchainFacts() {
  const e = env();
  const gateway = addr(e.GATEWAY_ADDRESS);
  const router = addr(e.CASHBACK_ROUTER_ADDRESS);
  const processor = addr(e.PROCESSOR_ADDRESS);
  const pub = publicClient();
  const safe = async <T,>(f: () => Promise<T>): Promise<T | null> => f().catch(() => null);

  const transistors = gateway ? await safe(() => pub.readContract({ address: gateway, abi: payLightGatewayAbi, functionName: "transistors" }) as Promise<Address>) : null;
  const [supplyCap, mintPrice, minted, creator] = transistors
    ? await Promise.all([
        safe(() => pub.readContract({ address: transistors, abi: tapeoutTransistorsAbi, functionName: "supplyCap" }) as Promise<bigint>),
        safe(() => pub.readContract({ address: transistors, abi: tapeoutTransistorsAbi, functionName: "mintPrice" }) as Promise<bigint>),
        safe(() => pub.readContract({ address: transistors, abi: tapeoutTransistorsAbi, functionName: "minted" }) as Promise<bigint>),
        safe(() => pub.readContract({ address: transistors, abi: tapeoutTransistorsAbi, functionName: "creator" }) as Promise<Address>),
      ])
    : [null, null, null, null];
  const tierFees = gateway
    ? await Promise.all([0, 1, 2].map((t) => safe(() => pub.readContract({ address: gateway, abi: payLightGatewayAbi, functionName: "tierFeeBps", args: [t] }) as Promise<number>)))
    : [null, null, null];
  const [t1, t2, r, circuitId] = gateway
    ? await Promise.all([
        safe(() => pub.readContract({ address: gateway, abi: payLightGatewayAbi, functionName: "tier1Holding" }) as Promise<bigint>),
        safe(() => pub.readContract({ address: gateway, abi: payLightGatewayAbi, functionName: "tier2Holding" }) as Promise<bigint>),
        safe(() => pub.readContract({ address: gateway, abi: payLightGatewayAbi, functionName: "repeatOrders" }) as Promise<number>),
        safe(() => pub.readContract({ address: gateway, abi: payLightGatewayAbi, functionName: "feeCircuitId" }) as Promise<bigint>),
      ])
    : [null, null, null, null];
  const [reserveMinted, distributed, maxReserve] = router
    ? await Promise.all(
        (["reserveMinted", "distributedUnits", "maxReserveMint"] as const).map((fn) => safe(() => pub.readContract({ address: router, abi: cashbackRouterAbi, functionName: fn }) as Promise<bigint>)),
      )
    : [null, null, null];
  return { gateway, router, processor, transistors, supplyCap, mintPrice, minted, creator, tierFees, t1, t2, r, circuitId, reserveMinted, distributed, maxReserve };
}

/** Public team/protocol wallets (set in env so the page never hard-codes them). */
export const teamWallets = () =>
  [
    ["Deployment wallet (processor creator, admin)", process.env.PUBLIC_DEPLOYER_ADDRESS],
    ["Treasury (receives settled USD₮0)", process.env.PUBLIC_TREASURY_ADDRESS],
    ["Operator (settles & refunds; gas only)", process.env.PUBLIC_OPERATOR_ADDRESS],
    ["Keeper (tops up cashback reserve)", process.env.PUBLIC_KEEPER_ADDRESS],
    ["Quote signer (signs prices; holds nothing)", process.env.PUBLIC_QUOTE_SIGNER_ADDRESS],
  ].filter((w): w is [string, string] => !!w[1]);
