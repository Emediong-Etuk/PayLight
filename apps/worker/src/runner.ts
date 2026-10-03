import { log } from "@paylight/core";

export interface Job {
  name: string;
  everyMs: number;
  run: () => Promise<unknown>;
}

export const heartbeats: Record<string, { lastOk?: string; lastError?: string; lastErrorAt?: string; runs: number }> = {};

/** Runs each job on its own interval, never overlapping itself, never letting one job's error stop the others. */
export function startJobs(jobs: Job[], signal: AbortSignal): Promise<void[]> {
  return Promise.all(
    jobs.map(async (job) => {
      heartbeats[job.name] = { runs: 0 };
      while (!signal.aborted) {
        const started = Date.now();
        try {
          await job.run();
          heartbeats[job.name]!.lastOk = new Date().toISOString();
        } catch (e) {
          heartbeats[job.name]!.lastError = (e as Error).message.slice(0, 300);
          heartbeats[job.name]!.lastErrorAt = new Date().toISOString();
          log.error(`job ${job.name} failed`, { err: (e as Error).message });
        }
        heartbeats[job.name]!.runs++;
        const wait = Math.max(250, job.everyMs - (Date.now() - started));
        await new Promise((r) => setTimeout(r, wait));
      }
    }),
  );
}
