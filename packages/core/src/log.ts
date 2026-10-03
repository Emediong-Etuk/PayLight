/** Structured logger that masks meter numbers (6–15 digit runs) and 20-digit tokens everywhere. */
const MASKS: Array<[RegExp, (m: string) => string]> = [
  [/\b\d{16,24}\b/g, (m) => `${"*".repeat(m.length - 4)}${m.slice(-4)}`],
  [/\b\d{6,15}\b/g, (m) => `${"*".repeat(m.length - 4)}${m.slice(-4)}`],
];
export const mask = (s: string) => MASKS.reduce((acc, [re, f]) => acc.replace(re, f), s);

function emit(level: string, msg: string, data?: Record<string, unknown>) {
  const line = JSON.stringify({ t: new Date().toISOString(), level, msg, ...data }, (_k, v) => (typeof v === "bigint" ? v.toString() : v));
  (level === "error" ? console.error : console.log)(mask(line));
}
export const log = {
  info: (msg: string, data?: Record<string, unknown>) => emit("info", msg, data),
  warn: (msg: string, data?: Record<string, unknown>) => emit("warn", msg, data),
  error: (msg: string, data?: Record<string, unknown>) => emit("error", msg, data),
};
