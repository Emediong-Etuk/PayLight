import { createServer } from "node:http";
import { env, getProvider, log, requireAddress } from "@paylight/core";
import { XLAYER } from "@paylight/shared";
import { viemChainOps } from "./chainops";
import { DEFAULT_BACKOFF, type WorkerContext } from "./context";
import { runListener } from "./jobs/listener";
import { runFulfiller, runReviewRequery } from "./jobs/fulfiller";
import { runRefunder, runSettler } from "./jobs/settler";
import { runCashbackKeeper } from "./jobs/keeper";
import { runReconciler } from "./jobs/reconciler";
import { runMonitor } from "./jobs/monitor";
import { heartbeats, startJobs } from "./runner";

/**
 * PayLight worker. Run exactly ONE instance (the fulfiller relies on a single writer per order for its provider call;
 * compare-and-set transitions protect state, but one instance keeps the operator nonce simple).
 */
async function main() {
  const e = env();
  const gateway = requireAddress("GATEWAY_ADDRESS");
  const router = e.CASHBACK_ROUTER_ADDRESS ? requireAddress("CASHBACK_ROUTER_ADDRESS") : undefined;
  const chain = viemChainOps(gateway, router);
  const ctx: WorkerContext = {
    chain,
    provider: getProvider(),
    now: () => new Date(),
    confirmations: e.CONFIRMATIONS,
    startBlock: e.START_BLOCK ?? (await chain.latestBlock()) - 50n,
    encryptionKey: e.TOKEN_ENCRYPTION_KEY,
    defaultPhone: e.DEFAULT_PHONE,
    requeryBackoffSec: DEFAULT_BACKOFF,
    maxLogRange: XLAYER.maxLogRange,
  };
  log.info("worker starting", { gateway, router, provider: ctx.provider.name, confirmations: ctx.confirmations });

  const port = Number(process.env.PORT ?? 8080);
  createServer((req, res) => {
    if (req.url?.startsWith("/health")) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, provider: ctx.provider.name, jobs: heartbeats }));
    } else {
      res.writeHead(404).end();
    }
  }).listen(port, () => log.info("health server", { port }));

  const abort = new AbortController();
  process.on("SIGTERM", () => abort.abort());
  process.on("SIGINT", () => abort.abort());
  await startJobs(
    [
      { name: "listener", everyMs: 2_000, run: () => runListener(ctx) },
      { name: "fulfiller", everyMs: 2_000, run: () => runFulfiller(ctx) },
      { name: "settler", everyMs: 3_000, run: () => runSettler(ctx) },
      { name: "refunder", everyMs: 5_000, run: () => runRefunder(ctx) },
      { name: "review-requery", everyMs: 60_000, run: () => runReviewRequery(ctx) },
      { name: "cashback-keeper", everyMs: 60_000, run: () => runCashbackKeeper(ctx) },
      { name: "reconciler", everyMs: 600_000, run: () => runReconciler(ctx) },
      { name: "monitor", everyMs: 300_000, run: () => runMonitor(ctx) },
    ],
    abort.signal,
  );
}

main().catch((e) => {
  log.error("worker crashed", { err: (e as Error).stack ?? String(e) });
  process.exit(1);
});
