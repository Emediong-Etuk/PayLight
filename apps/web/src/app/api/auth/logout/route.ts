import { clearSession } from "@/lib/session";
import { handler, json } from "@/lib/http";
export const POST = handler(async () => {
  await clearSession();
  return json({ ok: true });
});
