import { generateSiweNonce } from "viem/siwe";
import { prisma } from "@paylight/db";
import { handler, json } from "@/lib/http";

export const dynamic = "force-dynamic";

export const POST = handler(async () => {
  const nonce = generateSiweNonce();
  await prisma.siweNonce.create({ data: { nonce, expiresAt: new Date(Date.now() + 10 * 60_000) } });
  return json({ nonce });
});
