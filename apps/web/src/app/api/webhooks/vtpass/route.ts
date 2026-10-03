import { prisma } from "@paylight/db";
import { log } from "@paylight/core";
import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

/**
 * VTpass callback. We acknowledge immediately ({"response":"success"}) and never trust the payload: a
 * transaction-update only schedules an immediate REQUERY of that request_id by the worker.
 */
export async function POST(req: Request) {
  try {
    const body = (await req.json()) as { type?: string; data?: Record<string, unknown> };
    if (body.type === "transaction-update") {
      const d = body.data ?? {};
      const requestId = String(d.requestId ?? (d as { request_id?: string }).request_id ?? "");
      if (/^\d{12}[0-9a-zA-Z]{1,40}$/.test(requestId)) {
        const r = await prisma.order.updateMany({
          where: { providerRequestId: requestId, status: { in: ["PROVIDER_PENDING", "NEEDS_REVIEW"] } },
          data: { nextActionAt: new Date() },
        });
        log.info("vtpass webhook", { type: body.type, matched: r.count });
      }
    }
  } catch (e) {
    log.warn("vtpass webhook parse error", { err: (e as Error).message });
  }
  return NextResponse.json({ response: "success" });
}
