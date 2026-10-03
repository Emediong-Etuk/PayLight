import { createPublicClient, createWalletClient, defineChain, fallback, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { XLAYER } from "@paylight/shared";
import { env } from "./env";

export const xlayer = defineChain({
  id: XLAYER.chainId,
  name: XLAYER.name,
  nativeCurrency: XLAYER.nativeCurrency,
  rpcUrls: { default: { http: [...XLAYER.rpcUrls] } },
  blockExplorers: { default: { name: "OKX Explorer", url: XLAYER.explorer } },
});

const transport = () => {
  const e = env();
  return e.RPC_URL_FALLBACK ? fallback([http(e.RPC_URL), http(e.RPC_URL_FALLBACK)]) : http(e.RPC_URL);
};

let pub: ReturnType<typeof makePublic> | undefined;
const makePublic = () => createPublicClient({ chain: { ...xlayer, id: env().CHAIN_ID }, transport: transport() });
export const publicClient = () => (pub ??= makePublic());

/** Hot keys live only in the worker/backend env and are read lazily; they are never logged. */
export function walletFor(envVar: "OPERATOR_PRIVATE_KEY" | "KEEPER_PRIVATE_KEY") {
  const pk = process.env[envVar];
  if (!pk) throw new Error(`${envVar} is not set`);
  return createWalletClient({ account: privateKeyToAccount(pk as Hex), chain: { ...xlayer, id: env().CHAIN_ID }, transport: transport() });
}

export function quoteSignerAccount() {
  const pk = process.env.QUOTE_SIGNER_PRIVATE_KEY;
  if (!pk) throw new Error("QUOTE_SIGNER_PRIVATE_KEY is not set");
  return privateKeyToAccount(pk as Hex);
}

export function requireAddress(name: "GATEWAY_ADDRESS" | "CASHBACK_ROUTER_ADDRESS" | "PROCESSOR_ADDRESS"): Address {
  const v = env()[name];
  if (!v || !/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`${name} is not set`);
  return v as Address;
}
