import { getSession } from "@/lib/session";
import { handler, json } from "@/lib/http";
export const dynamic = "force-dynamic";
export const GET = handler(async () => json({ address: await getSession() }));
