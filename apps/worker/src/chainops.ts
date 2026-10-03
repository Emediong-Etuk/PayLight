import { keccak256, parseEventLogs, toHex, type Address, type Hex, type Log } from "viem";
import { cashbackRouterAbi, payLightGatewayAbi } from "@paylight/shared";
import { publicClient, walletFor } from "@paylight/core";

export type OnchainStatus = "None" | "Paid" | "Fulfilled" | "Refunded";
const STATUS: OnchainStatus[] = ["None", "Paid", "Fulfilled", "Refunded"];

export interface OnchainOrder {
  payer: Address;
  status: OnchainStatus;
  amount: bigint;
  fee: bigint;
  tier: number;
  cashbackUnits: number;
  paidAt: bigint;
  refundableAt: bigint;
  cashbackCredited: boolean;
}

/** Everything the worker does on-chain, behind an interface so job logic is unit-testable. */
export interface ChainOps {
  latestBlock(): Promise<bigint>;
  safeBlock(): Promise<bigint>;
  getLogs(fromBlock: bigint, toBlock: bigint): Promise<Log[]>;
  getOrder(orderId: Hex, blockNumber?: bigint): Promise<OnchainOrder>;
  markFulfilled(orderId: Hex, receiptHash: Hex): Promise<Hex>;
  refund(orderId: Hex): Promise<Hex>;
  distribute(orderIds: Hex[]): Promise<Hex>;
  /** Waits for the tx; returns true if it succeeded. */
  waitSuccess(hash: Hex): Promise<boolean>;
  operatorGasWei(): Promise<bigint>;
  routerFreeReserve(): Promise<bigint>;
}

export const receiptHashFor = (providerTxId: string) => keccak256(toHex(providerTxId));

export function viemChainOps(gateway: Address, router: Address | undefined): ChainOps {
  const pub = publicClient();
  let operator: ReturnType<typeof walletFor> | undefined;
  let keeper: ReturnType<typeof walletFor> | undefined;
  const op = () => (operator ??= walletFor("OPERATOR_PRIVATE_KEY"));
  const kp = () => (keeper ??= process.env.KEEPER_PRIVATE_KEY ? walletFor("KEEPER_PRIVATE_KEY") : op());

  return {
    latestBlock: () => pub.getBlockNumber({ cacheTime: 0 }),
    safeBlock: async () => (await pub.getBlock({ blockTag: "safe" })).number!,
    async getLogs(fromBlock, toBlock) {
      const addresses = router ? [gateway, router] : [gateway];
      return pub.getLogs({ address: addresses, fromBlock, toBlock });
    },
    async getOrder(orderId, blockNumber) {
      const o = (await pub.readContract({ address: gateway, abi: payLightGatewayAbi, functionName: "getOrder", args: [orderId], blockNumber })) as {
        payer: Address; paidAt: bigint; status: number; tier: number; cashbackCredited: boolean; amount: bigint; fee: bigint; refundableAt: bigint; cashbackUnits: number;
      };
      return { ...o, status: STATUS[o.status] ?? "None" };
    },
    markFulfilled: (orderId, receiptHash) =>
      op().writeContract({ address: gateway, abi: payLightGatewayAbi, functionName: "markFulfilled", args: [orderId, receiptHash], chain: undefined }),
    refund: (orderId) => op().writeContract({ address: gateway, abi: payLightGatewayAbi, functionName: "refund", args: [orderId], chain: undefined }),
    distribute: (orderIds) => {
      if (!router) throw new Error("CASHBACK_ROUTER_ADDRESS not set");
      return kp().writeContract({ address: router, abi: cashbackRouterAbi, functionName: "distribute", args: [orderIds], chain: undefined });
    },
    async waitSuccess(hash) {
      const r = await pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
      return r.status === "success";
    },
    operatorGasWei: () => pub.getBalance({ address: op().account.address }),
    routerFreeReserve: async () =>
      router ? ((await pub.readContract({ address: router, abi: cashbackRouterAbi, functionName: "freeReserve" })) as bigint) : 0n,
  };
}

export const decodeLogs = (logs: Log[]) =>
  parseEventLogs({ abi: [...payLightGatewayAbi, ...cashbackRouterAbi], logs, strict: false });
