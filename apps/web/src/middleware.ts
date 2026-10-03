import { NextResponse, type NextRequest } from "next/server";

/** Basic auth in front of /admin and /api/admin (second factor: allowlisted SIWE wallet, checked in the routes). */
export function middleware(req: NextRequest) {
  const expected = process.env.ADMIN_BASIC_AUTH; // "user:password"
  if (!expected) return new NextResponse("Admin disabled", { status: 503 });
  const header = req.headers.get("authorization") ?? "";
  const [scheme, value] = header.split(" ");
  if (scheme === "Basic" && value && atob(value) === expected) return NextResponse.next();
  return new NextResponse("Authentication required", { status: 401, headers: { "WWW-Authenticate": 'Basic realm="PayLight admin"' } });
}

export const config = { matcher: ["/admin/:path*", "/api/admin/:path*"] };
