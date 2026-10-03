import { PrismaClient } from "@prisma/client";

export * from "@prisma/client";

const globalForPrisma = globalThis as unknown as { __paylightPrisma?: PrismaClient };

/** Singleton Prisma client (survives Next.js dev hot reloads). */
export const prisma: PrismaClient = globalForPrisma.__paylightPrisma ?? new PrismaClient();
if (process.env.NODE_ENV !== "production") globalForPrisma.__paylightPrisma = prisma;
