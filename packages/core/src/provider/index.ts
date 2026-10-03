import { env } from "../env";
import { MockProvider } from "./mock";
import type { BillProvider } from "./types";
import { VtpassProvider } from "./vtpass";

export * from "./types";
export * from "./mock";
export * from "./vtpass";
export * from "./vtpassParse";
export * from "./requestId";

let instance: BillProvider | undefined;
export function getProvider(): BillProvider {
  if (instance) return instance;
  const e = env();
  if (e.PROVIDER === "vtpass") {
    if (!e.VTPASS_API_KEY || !e.VTPASS_PUBLIC_KEY || !e.VTPASS_SECRET_KEY) throw new Error("VTpass keys missing (VTPASS_API_KEY/PUBLIC_KEY/SECRET_KEY)");
    instance = new VtpassProvider({ baseUrl: e.VTPASS_BASE_URL, apiKey: e.VTPASS_API_KEY, publicKey: e.VTPASS_PUBLIC_KEY, secretKey: e.VTPASS_SECRET_KEY });
  } else instance = new MockProvider();
  return instance;
}
export const setProvider = (p: BillProvider | undefined) => {
  instance = p;
};
