import { createHmac, timingSafeEqual } from "node:crypto";
import { cookies } from "next/headers";

/** Minimal signed session cookie for SIWE: base64url(address|expiry).hmac. HttpOnly, Secure, SameSite=Lax. */
const COOKIE = "pl_session";
const TTL_SEC = 7 * 24 * 3600;

const secret = () => {
  const s = process.env.SESSION_SECRET;
  if (!s || s.length < 32) throw new Error("SESSION_SECRET must be >= 32 chars");
  return s;
};
const sign = (payload: string) => createHmac("sha256", secret()).update(payload).digest("base64url");

export async function setSession(address: string) {
  const payload = Buffer.from(`${address.toLowerCase()}|${Math.floor(Date.now() / 1000) + TTL_SEC}`).toString("base64url");
  (await cookies()).set(COOKIE, `${payload}.${sign(payload)}`, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: TTL_SEC,
  });
}

export async function clearSession() {
  (await cookies()).delete(COOKIE);
}

/** Returns the signed-in wallet address (lowercase) or null. */
export async function getSession(): Promise<string | null> {
  const raw = (await cookies()).get(COOKIE)?.value;
  if (!raw) return null;
  const [payload, mac] = raw.split(".");
  if (!payload || !mac) return null;
  const expected = sign(payload);
  if (expected.length !== mac.length || !timingSafeEqual(Buffer.from(expected), Buffer.from(mac))) return null;
  const [address, exp] = Buffer.from(payload, "base64url").toString().split("|");
  if (!address || !exp || Number(exp) < Date.now() / 1000) return null;
  return address;
}
