import { randomBytes } from "node:crypto";

/**
 * VTpass request_id: first 12 chars MUST be today's date-time in Africa/Lagos as YYYYMMDDHHmm, then any alphanumeric
 * suffix (docs: how-to-generate-request-id; errors 085/014). We append 16 random hex chars.
 */
export function lagosTimestamp(now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Lagos",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)!.value;
  return `${get("year")}${get("month")}${get("day")}${get("hour")}${get("minute")}`;
}

export const newRequestId = (now: Date = new Date()) => `${lagosTimestamp(now)}${randomBytes(8).toString("hex")}`;
