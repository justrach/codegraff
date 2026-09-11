import {readMcpApp} from "@/lib/mcp-app-store";
import {validAppId} from "@/lib/mcp-apps";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const origin = request.headers.get("origin");
  if (request.headers.get("sec-fetch-site") === "cross-site" || (origin && origin !== url.origin))
    return new Response("Forbidden", {status:403});
  const id = url.searchParams.get("id");
  if (!validAppId(id)) return new Response("Invalid app id", {status:400});
  try {
    return new Response(await readMcpApp(id), {headers:{
      "Content-Type":"text/html; charset=utf-8", "Cache-Control":"no-store", "X-Content-Type-Options":"nosniff",
      "Referrer-Policy":"no-referrer", "Content-Security-Policy":"frame-ancestors 'self'; sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox",
    }});
  } catch { return new Response("This app result is no longer available.", {status:404}); }
}
