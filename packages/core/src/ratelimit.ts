import { prisma } from "@paylight/db";

/** Fixed-window limiter in Postgres. Returns true if allowed. */
export async function rateLimit(key: string, max: number, windowSeconds: number, now = new Date()): Promise<boolean> {
  const windowEnd = new Date(now.getTime() + windowSeconds * 1000);
  return prisma.$transaction(async (tx) => {
    const row = await tx.rateLimit.findUnique({ where: { key } });
    if (!row || row.windowEnd <= now) {
      await tx.rateLimit.upsert({ where: { key }, create: { key, count: 1, windowEnd }, update: { count: 1, windowEnd } });
      return true;
    }
    if (row.count >= max) return false;
    await tx.rateLimit.update({ where: { key }, data: { count: { increment: 1 } } });
    return true;
  });
}
