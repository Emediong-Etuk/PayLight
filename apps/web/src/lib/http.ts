import { NextResponse } from "next/server";
import { ZodError, type ZodType } from "zod";
import { log } from "@paylight/core";

export const json = (data: unknown, status = 200) =>
  NextResponse.json(JSON.parse(JSON.stringify(data, (_k, v) => (typeof v === "bigint" ? v.toString() : v))), { status });

export const fail = (message: string, status = 400, code?: string) => json({ error: message, code }, status);

export async function parseBody<T>(req: Request, schema: ZodType<T>): Promise<T> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    throw new ZodError([{ code: "custom", message: "invalid JSON", path: [], input: undefined }]);
  }
  return schema.parse(body);
}

/** Wraps a route handler: zod errors → 400, everything else → 500 with a safe message. */
export function handler<A extends unknown[]>(fn: (...args: A) => Promise<Response>) {
  return async (...args: A): Promise<Response> => {
    try {
      return await fn(...args);
    } catch (e) {
      if (e instanceof ZodError) return fail(e.issues.map((i) => i.message).join("; "), 400, "VALIDATION");
      log.error("api error", { err: (e as Error).message });
      return fail("Something went wrong. Please try again.", 500);
    }
  };
}
