/**
 * End-to-end on a LOCAL Anvil chain (BUILD_BRIEF §11.1): real PayLightGateway + CashbackRouter, mock USD₮0/TapeOut,
 * MockProvider, real Postgres. A user pays on-chain; the worker jobs take it to SETTLED (+cashback) or REFUNDED, or
 * park it in NEEDS_REVIEW without refunding when the provider status stays unknown.
 */
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { readFileSync, mkdirSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseEther, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { prisma } from "@paylight/db";
import { cashbackRouterAbi, erc20Abi, payLightGatewayAbi } from "@paylight/shared";
import { MockProvider, createQuote, decryptToken, resetEnv, viemGatewayReader, xlayer } from "@paylight/core";
import { viemChainOps } from "../src/chainops";
import type { WorkerContext } from "../src/context";
import { runListener } from "../src/jobs/listener";
import { runFulfiller, runReviewRequery } from "../src/jobs/fulfiller";
import { runRefunder, runSettler } from "../src/jobs/settler";
import { runCashbackKeeper } from "../src/jobs/keeper";
import { runReconciler } from "../src/jobs/reconciler";

const PORT = 8651;
const RPC = `http://127.0.0.1:${PORT}`;
const ROOT = new URL("../../../", import.meta.url).pathname;
const FOUNDRY = `${process.env.HOME}/.foundry/bin`;
const keys = Object.fromEntries(["deployer", "operator", "keeper", "signer", "treasury", "user1", "user2"].map((k) => [k, generatePrivateKey()])) as Record<string, Hex>;
const addr = (k: string) => privateKeyToAccount(keys[k]!).address;

let anvil: ChildProcess;
let A: { usdt0: Address; transistors: Address; processor: Address; gateway: Address; router: Address; block: number };
const chain = { ...xlayer, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const provider = new MockProvider();
let clock = new Date();
let ctx: WorkerContext;

const rpc = (method: string, params: unknown[] = []) =>
  fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((r) => r.json());

beforeAll(async () => {
  anvil = spawn(`${FOUNDRY}/anvil`, ["--chain-id", "196", "--port", String(PORT), "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 50; i++) {
    try {
      await pub.getBlockNumber();
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  for (const k of Object.keys(keys)) await rpc("anvil_setBalance", [addr(k), "0x56BC75E2D63100000"]);
  mkdirSync(`${ROOT}.local`, { recursive: true });
  const out = `${ROOT}.local/e2e-addresses.json`;
  execFileSync(`${FOUNDRY}/forge`, ["script", "script/LocalDev.s.sol", "--rpc-url", RPC, "--broadcast", "--slow"], {
    cwd: `${ROOT}packages/contracts`,
    env: {
      ...process.env,
      DEPLOYER_PK: keys.deployer,
      OPERATOR: addr("operator"),
      KEEPER: addr("keeper"),
      QUOTE_SIGNER: addr("signer"),
      TREASURY: addr("treasury"),
      USER1: addr("user1"),
      USER2: addr("user2"),
      LOCAL_OUT: out,
    },
    stdio: "pipe",
  });
  A = JSON.parse(readFileSync(out, "utf8"));

  Object.assign(process.env, {
    RPC_URL: RPC,
    CHAIN_ID: "196",
    GATEWAY_ADDRESS: A.gateway,
    CASHBACK_ROUTER_ADDRESS: A.router,
    OPERATOR_PRIVATE_KEY: keys.operator,
    KEEPER_PRIVATE_KEY: keys.keeper,
    QUOTE_SIGNER_PRIVATE_KEY: keys.signer,
    PROVIDER: "mock",
  });
  resetEnv();

  // keeper funds the cashback reserve through the (mock) TapeOut mint at the public price
  const keeper = createWalletClient({ account: privateKeyToAccount(keys.keeper!), chain, transport: http(RPC) });
  const cost = (await pub.readContract({ address: A.router, abi: cashbackRouterAbi, functionName: "topUpCost", args: [1_000n] })) as bigint;
  await pub.waitForTransactionReceipt({ hash: await keeper.writeContract({ address: A.router, abi: cashbackRouterAbi, functionName: "topUp", args: [1_000n], value: cost }) });

  ctx = {
    chain: viemChainOps(A.gateway, A.router),
    provider,
    now: () => clock,
    confirmations: 1,
    startBlock: BigInt(A.block),
    encryptionKey: process.env.TOKEN_ENCRYPTION_KEY,
    defaultPhone: "08011111111",
    requeryBackoffSec: [1, 1, 1],
    maxLogRange: 100n,
  };
}, 180_000);

afterAll(() => anvil?.kill());

beforeEach(async () => {
  await prisma.orderEvent.deleteMany();
  await prisma.order.deleteMany();
  await prisma.quote.deleteMany();
  await prisma.cashbackPayout.deleteMany();
  await prisma.chainLog.deleteMany();
  await prisma.chainCursor.deleteMany();
  clock = new Date((Number((await pub.getBlock()).timestamp) + 1) * 1000);
});

async function buy(user: "user1" | "user2", meterNumber: string, amountNgn = 5_000) {
  const account = privateKeyToAccount(keys[user]!);
  const q = await createQuote(
    { serviceID: "portharcourt-electric", meterNumber, meterType: "prepaid", amountNgn, payer: account.address },
    {
      provider,
      gateway: viemGatewayReader(pub, A.gateway),
      gatewayAddress: A.gateway,
      chainId: 196,
      signer: privateKeyToAccount(keys.signer!),
      pricing: { rateKobo: 135_200n, spreadBps: 150, quotesPaused: false, rateUpdatedAt: clock },
      limits: { maxOrderNgn: 40_000, dailyWalletCapNgn: 1_000_000, floatMinNgn: 5_000, ttlSeconds: 120 },
      floatNgn: () => provider.getWalletBalance(),
      now: () => clock,
    },
  );
  const w = createWalletClient({ account, chain, transport: http(RPC) });
  const total = BigInt(q.totalUsdt0);
  await pub.waitForTransactionReceipt({ hash: await w.writeContract({ address: A.usdt0, abi: erc20Abi, functionName: "approve", args: [A.gateway, total] }) });
  const quote = { orderId: q.orderId as Hex, payer: account.address, baseAmount: BigInt(q.baseAmount), fee: BigInt(q.fee), tier: q.tier, cashbackUnits: q.cashbackUnits, expiry: BigInt(q.expiry) };
  await pub.waitForTransactionReceipt({ hash: await w.writeContract({ address: A.gateway, abi: payLightGatewayAbi, functionName: "pay", args: [quote, q.signature as Hex] }) });
  await rpc("anvil_mine", ["0x2"]); // confirmations
  return q;
}

async function tick(n = 1) {
  for (let i = 0; i < n; i++) {
    clock = new Date(clock.getTime() + 2_000);
    await runListener(ctx);
    await runFulfiller(ctx);
    await runSettler(ctx);
    await runRefunder(ctx);
    await rpc("anvil_mine", ["0x2"]);
    await runListener(ctx);
  }
}
const status = async (orderId: string) => (await prisma.order.findUniqueOrThrow({ where: { orderId } })).status;
const onchain = async (orderId: string) => (await ctx.chain.getOrder(orderId as Hex)).status;
const usdt = (a: Address) => pub.readContract({ address: A.usdt0, abi: erc20Abi, functionName: "balanceOf", args: [a] }) as Promise<bigint>;

describe("worker end-to-end on Anvil", () => {
  it("success: PAID → DELIVERED (encrypted token) → SETTLED on-chain → cashback paid", async () => {
    const treasuryBefore = await usdt(addr("treasury"));
    const q = await buy("user1", MockProvider.METERS.success);
    await tick(2);
    expect(await status(q.orderId)).toBe("SETTLED");
    expect(await onchain(q.orderId)).toBe("Fulfilled");
    expect((await usdt(addr("treasury"))) - treasuryBefore).toBe(BigInt(q.totalUsdt0));
    const o = await prisma.order.findUniqueOrThrow({ where: { orderId: q.orderId } });
    expect(o.meterTokenEncrypted).toBeTruthy();
    expect(decryptToken(o.meterTokenEncrypted!, process.env.TOKEN_ENCRYPTION_KEY)).toMatch(/^\d{20}$/);
    expect(o.txHashSettled).toMatch(/^0x/);
    const events = (await prisma.orderEvent.findMany({ where: { orderId: q.orderId }, orderBy: { id: "asc" } })).map((e) => e.to);
    expect(events).toEqual(["PAID", "PROVIDER_PENDING", "DELIVERED", "SETTLED"]);

    await runCashbackKeeper(ctx, { minBatch: 1, maxWaitSec: 0, maxBatch: 40 });
    await rpc("anvil_mine", ["0x2"]);
    await runListener(ctx);
    const payout = await prisma.cashbackPayout.findUnique({ where: { orderId: q.orderId } });
    expect(payout?.units).toBe(q.cashbackUnits);
  });

  it("pending → success after requeries", async () => {
    const q = await buy("user1", MockProvider.METERS.pendingThenSuccess);
    await tick(1);
    expect(await status(q.orderId)).toBe("PROVIDER_PENDING");
    await tick(3);
    expect(await status(q.orderId)).toBe("SETTLED");
    expect(provider.purchases.filter((p) => p.meterNumber === MockProvider.METERS.pendingThenSuccess)).toHaveLength(1); // never re-paid
  });

  it("timeout → requery shows delivered → settled (pay called once)", async () => {
    const before = provider.purchases.length;
    const q = await buy("user2", MockProvider.METERS.timeoutThenSuccess);
    await tick(3);
    expect(await status(q.orderId)).toBe("SETTLED");
    expect(provider.purchases.length - before).toBe(1);
  });

  it("pending → definitive failure → automatic operator refund", async () => {
    const before = await usdt(addr("user1"));
    const q = await buy("user1", MockProvider.METERS.pendingThenFail);
    await tick(5);
    expect(await status(q.orderId)).toBe("REFUNDED");
    expect(await onchain(q.orderId)).toBe("Refunded");
    expect(await usdt(addr("user1"))).toBe(before);
  });

  it("hard failure → refunded", async () => {
    const q = await buy("user2", MockProvider.METERS.hardFail);
    await tick(3);
    expect(await status(q.orderId)).toBe("REFUNDED");
  });

  it("unknown forever → NEEDS_REVIEW, NOT refunded; payer self-refund after timeout is picked up", async () => {
    const q = await buy("user1", MockProvider.METERS.unknownForever);
    await tick(6);
    expect(await status(q.orderId)).toBe("NEEDS_REVIEW");
    expect(await onchain(q.orderId)).toBe("Paid"); // never auto-refunded on unknown status
    await runReviewRequery(ctx);
    expect(await status(q.orderId)).toBe("NEEDS_REVIEW");

    // 24h later anyone triggers the self-refund; funds go to the payer; the listener records it
    await rpc("evm_increaseTime", [24 * 3600 + 10]);
    await rpc("anvil_mine", ["0x1"]);
    const stranger = createWalletClient({ account: privateKeyToAccount(keys.treasury!), chain, transport: http(RPC) });
    await pub.waitForTransactionReceipt({ hash: await stranger.writeContract({ address: A.gateway, abi: payLightGatewayAbi, functionName: "claimRefund", args: [q.orderId as Hex] }) });
    await rpc("anvil_mine", ["0x2"]);
    await runListener(ctx);
    expect(await status(q.orderId)).toBe("REFUNDED");
  });

  it("listener is idempotent and the reconciler finds no mismatches", async () => {
    const q = await buy("user2", MockProvider.METERS.success);
    await tick(2);
    await prisma.chainCursor.deleteMany(); // force a full re-scan
    await runListener(ctx);
    expect(await status(q.orderId)).toBe("SETTLED");
    await rpc("anvil_mine", ["0x5"]);
    const r = await runReconciler(ctx);
    expect(r.mismatches).toBe(0);
  });
});
