import {readView} from "@/lib/snapshot-store";
import {validAppId} from "@/lib/mcp-apps";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** A model-authored page is contained by policy, not by a wrapper document:
 *  the CSP `sandbox` directive gives the response an opaque origin (no app
 *  DOM, no cookies, no storage, no API reach) and `default-src 'none'` keeps
 *  it off the network, whether the transcript frames it or someone opens the
 *  file's own URL. Inline script and style stay on — that is what makes a
 *  self-contained page work — and images must be `data:`/`blob:`. */
const POLICY = "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const origin = request.headers.get("origin");
  if (request.headers.get("sec-fetch-site") === "cross-site" || (origin && origin !== url.origin))
    return new Response("Forbidden", {status:403});
  const id = url.searchParams.get("id");
  if (!validAppId(id)) return new Response("Invalid view id", {status:400});
  try {
    return new Response(await readView(id), {headers:{
      "Content-Type":"text/html; charset=utf-8", "Cache-Control":"no-store",
      "X-Content-Type-Options":"nosniff", "Referrer-Policy":"no-referrer", "Content-Security-Policy":POLICY,
    }});
  } catch { return new Response("This view is no longer available.", {status:404}); }
}
