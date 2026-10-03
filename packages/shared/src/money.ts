/**
 * Money math. bigint only — never floats for money.
 * - NGN amounts are whole naira (VTpass takes naira).
 * - Rates are stored as kobo per 1 USD₮0 (e.g. ₦1,352.00 => 135200n).
 * - USD₮0 amounts are base units (6 decimals).
 */
export const USDT0_UNIT = 1_000_000n;
export const MIN_BASE_PER_CASHBACK_UNIT = 250_000n; // mirrors PayLightGateway.MIN_BASE_PER_CASHBACK_UNIT
export const MAX_CASHBACK_UNITS = 50; // mirrors PayLightGateway.MAX_CASHBACK_UNITS
export const NGN_PER_CASHBACK_UNIT = 1_000n; // 1 NAND per ₦1,000 (approved parameter sheet)

export const ceilDiv = (a: bigint, b: bigint) => {
  if (b <= 0n) throw new Error("ceilDiv by non-positive");
  if (a < 0n) throw new Error("ceilDiv of negative");
  return a === 0n ? 0n : (a - 1n) / b + 1n;
};

/** USD₮0 base units needed to cover `amountNgn` naira at `rateKoboPerUsdt0`, rounded UP. */
export function ngnToUsdt0(amountNgn: bigint, rateKoboPerUsdt0: bigint): bigint {
  if (amountNgn <= 0n) throw new Error("amount must be positive");
  if (rateKoboPerUsdt0 <= 0n) throw new Error("rate must be positive");
  return ceilDiv(amountNgn * 100n * USDT0_UNIT, rateKoboPerUsdt0);
}

/** Exactly PayLightGateway.previewFee: ceil(base * bps / 10_000). */
export const feeFor = (baseAmount: bigint, bps: number) => ceilDiv(baseAmount * BigInt(bps), 10_000n);

/** min(50, max(1, floor(ngn / 1000))), never more than the on-chain backing rule allows. */
export function cashbackUnitsFor(amountNgn: bigint, baseAmount: bigint): number {
  const byNgn = amountNgn / NGN_PER_CASHBACK_UNIT;
  const wanted = byNgn < 1n ? 1n : byNgn;
  const backed = baseAmount / MIN_BASE_PER_CASHBACK_UNIT;
  let units = wanted < backed ? wanted : backed;
  if (units > BigInt(MAX_CASHBACK_UNITS)) units = BigInt(MAX_CASHBACK_UNITS);
  return Number(units);
}

/** "12.345678" style formatting of USD₮0 base units (trims trailing zeros, keeps >= 2 dp). */
export function formatUsdt0(amount: bigint): string {
  const neg = amount < 0n;
  const a = neg ? -amount : amount;
  const whole = a / USDT0_UNIT;
  let frac = (a % USDT0_UNIT).toString().padStart(6, "0").replace(/0+$/, "");
  if (frac.length < 2) frac = frac.padEnd(2, "0");
  return `${neg ? "-" : ""}${whole.toString()}.${frac}`;
}

/** ₦5,000 */
export const formatNgn = (amountNgn: bigint | number) =>
  `₦${new Intl.NumberFormat("en-NG", { maximumFractionDigits: 0 }).format(Number(amountNgn))}`;

/** "1352.5" => 135250n kobo; accepts up to 2 decimals. */
export function parseRateToKobo(rate: string): bigint {
  const m = /^(\d{1,9})(?:\.(\d{1,2}))?$/.exec(rate.trim());
  if (!m) throw new Error(`invalid rate: ${rate}`);
  return BigInt(m[1]!) * 100n + BigInt((m[2] ?? "").padEnd(2, "0"));
}
