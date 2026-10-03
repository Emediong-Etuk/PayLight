import type { BillProvider } from "@paylight/core";
import type { ChainOps } from "./chainops";

export interface WorkerContext {
  chain: ChainOps;
  provider: BillProvider;
  now: () => Date;
  confirmations: number;
  startBlock: bigint;
  encryptionKey: string | undefined;
  defaultPhone: string;
  /** Requery backoff after an unknown/pending outcome (brief §6.2 rule 2): 10s, 30s, 1m, 2m, 5m, 10m. */
  requeryBackoffSec: number[];
  maxLogRange: bigint;
}

export const DEFAULT_BACKOFF = [10, 30, 60, 120, 300, 600];
