import { alert, setConfig, getConfig, env } from "@paylight/core";
import type { WorkerContext } from "../context";

const AUTO_PAUSE_KEY = "quotes_auto_paused_reason";

/**
 * Every 5 min: VTpass NGN float and operator OKB gas. Below threshold → auto-pause quotes (separate flag from the
 * admin pause) + alert; recovers automatically.
 */
export async function runMonitor(ctx: WorkerContext): Promise<{ floatNgn: number | null; gasWei: bigint | null }> {
  const e = env();
  let floatNgn: number | null = null;
  let gasWei: bigint | null = null;
  const reasons: string[] = [];
  try {
    floatNgn = await ctx.provider.getWalletBalance();
    if (floatNgn < e.FLOAT_MIN_NGN) reasons.push(`provider float ₦${floatNgn} < ₦${e.FLOAT_MIN_NGN}`);
  } catch (err) {
    reasons.push(`provider balance unreadable: ${(err as Error).message}`);
  }
  try {
    gasWei = await ctx.chain.operatorGasWei();
    if (gasWei < e.MIN_OPERATOR_OKB_WEI) reasons.push(`operator gas ${gasWei} wei < ${e.MIN_OPERATOR_OKB_WEI}`);
  } catch (err) {
    reasons.push(`operator gas unreadable: ${(err as Error).message}`);
  }
  const previous = (await getConfig(AUTO_PAUSE_KEY)) ?? "";
  const next = reasons.join("; ");
  if (next !== previous) {
    await setConfig(AUTO_PAUSE_KEY, next, "worker:monitor");
    await alert(next ? `Quotes auto-paused: ${next}` : "Quotes resumed: float and gas back above thresholds.");
  }
  return { floatNgn, gasWei };
}
export { AUTO_PAUSE_KEY };
