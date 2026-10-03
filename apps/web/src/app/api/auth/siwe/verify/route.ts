import { z } from "zod";
import { parseSiweMessage, verifySiweMessage } from "viem/siwe";
import { prisma } from "@paylight/db";
import { env, publicClient } from "@paylight/core";
import { setSession } from "@/lib/session";
import { fail, handler, json, parseBody } from "@/lib/http";

export const dynamic = "force-dynamic";
const body = z.object({ message: z.string().max(4000), signature: z.string().regex(/^0x[0-9a-fA-F]+$/) });

/** Verifies a SIWE message (EOA or smart-wallet via ERC-1271/6492), consumes the nonce once, sets the session cookie. */
export const POST = handler(async (req: Request) => {
  const { message, signature } = await parseBody(req, body);
  const parsed = parseSiweMessage(message);
  if (!parsed.nonce || !parsed.address) return fail("Invalid sign-in message", 400);
  if (parsed.chainId !== env().CHAIN_ID) return fail("Wrong network", 400);
  const host = req.headers.get("x-forwarded-host") ?? req.headers.get("host") ?? "";
  if (parsed.domain !== host) return fail("Sign-in message is for a different site", 400);

  const used = await prisma.siweNonce.updateMany({ where: { nonce: parsed.nonce, usedAt: null, expiresAt: { gt: new Date() } }, data: { usedAt: new Date() } });
  if (used.count !== 1) return fail("Sign-in expired. Please try again.", 400);

  const ok = await verifySiweMessage(publicClient(), { message, signature: signature as `0x${string}`, domain: host, nonce: parsed.nonce });
  if (!ok) return fail("Signature check failed", 401);
  await setSession(parsed.address);
  return json({ address: parsed.address.toLowerCase() });
});
