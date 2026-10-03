import "server-only";
import { prisma } from "@paylight/db";
import { getSession } from "./session";

/** Returns the admin wallet, or null if the signed-in wallet isn't in ADMIN_WALLETS. */
export async function requireAdmin(): Promise<string | null> {
  const me = await getSession();
  const allow = (process.env.ADMIN_WALLETS ?? "").toLowerCase().split(",").map((s) => s.trim()).filter(Boolean);
  return me && allow.includes(me) ? me : null;
}

export const audit = (actor: string, action: string, payload: object) =>
  prisma.adminAudit.create({ data: { actor, action, payload: JSON.parse(JSON.stringify(payload, (_k, v) => (typeof v === "bigint" ? v.toString() : v))) } });
