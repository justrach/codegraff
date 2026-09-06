import { NextRequest, NextResponse } from "next/server";

// The desktop's API can run tools and read files. Only its own renderer
// session receives this per-launch header; embedded websites never do.
export function proxy(request: NextRequest) {
  const token = process.env.GRAFF_DESKTOP_TOKEN;
  if (token && request.headers.get("x-graff-desktop") !== token) {
    return NextResponse.json({ error: "Desktop session required" }, { status: 403 });
  }
  return NextResponse.next();
}
export const config = { matcher: "/api/:path*" };
