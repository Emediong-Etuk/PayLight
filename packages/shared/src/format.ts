/** "35419981304203731832" => "3541 9981 3042 0373 1832" */
export const groupToken = (token: string) => token.replace(/\D/g, "").replace(/(\d{4})(?=\d)/g, "$1 ");

/** Mask all but the last 4 digits: "45012345678" => "*******5678". */
export const maskMeter = (meter: string) => (meter.length <= 4 ? meter : "*".repeat(meter.length - 4) + meter.slice(-4));

/** "JOHN DOE OKAFOR" => "JOHN D**E O****R" (first word intact, others masked inside). */
export function maskName(name: string): string {
  return name
    .trim()
    .split(/\s+/)
    .map((w, i) => (i === 0 || w.length <= 2 ? w : w[0] + "*".repeat(Math.max(1, w.length - 2)) + w[w.length - 1]))
    .join(" ");
}

/** Keep only the last two address parts ("12 Foo St, Rumuola, Port Harcourt" => "Rumuola, Port Harcourt"). */
export function maskAddress(address: string): string {
  const parts = address.split(",").map((p) => p.trim()).filter(Boolean);
  return parts.length <= 1 ? (parts[0] ?? "").replace(/^\d+\s*/, "") : parts.slice(-2).join(", ");
}
