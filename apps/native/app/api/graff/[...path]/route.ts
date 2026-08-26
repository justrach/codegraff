import { NextRequest } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function upstream(): string {
  return (process.env.GRAFF_SERVE_URL ?? "http://127.0.0.1:8787").replace(/\/+$/, "");
}

function headers(req: NextRequest): Headers {
  const h = new Headers();
  const type = req.headers.get("content-type");
  if (type) h.set("content-type", type);
  const token = process.env.HARNESS_SERVE_TOKEN;
  if (token) h.set("authorization", `Bearer ${token}`);
  return h;
}

function target(req: NextRequest, path: string[]): string {
  const suffix = path.join("/");
  const url = new URL(req.url);
  return `${upstream()}/${suffix}${url.search}`;
}

async function relay(req: NextRequest, path: string[], method: string): Promise<Response> {
  const init: RequestInit = {
    method,
    headers: headers(req),
    cache: "no-store",
  };
  if (method !== "GET" && method !== "HEAD" && method !== "DELETE") {
    init.body = await req.text();
  }
  let res: Response;
  try {
    res = await fetch(target(req, path), init);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    return Response.json(
      {
        error: "graff serve is not reachable",
        hint: "From the repo root: zig-out/bin/graff serve --port 8787",
        detail,
      },
      { status: 502 },
    );
  }
  const out = new Headers();
  const ct = res.headers.get("content-type");
  if (ct) out.set("content-type", ct);
  out.set("cache-control", "no-store");
  return new Response(res.body, { status: res.status, headers: out });
}

type Ctx = { params: Promise<{ path: string[] }> };

export async function GET(req: NextRequest, ctx: Ctx) {
  return relay(req, (await ctx.params).path, "GET");
}

export async function POST(req: NextRequest, ctx: Ctx) {
  return relay(req, (await ctx.params).path, "POST");
}

export async function DELETE(req: NextRequest, ctx: Ctx) {
  return relay(req, (await ctx.params).path, "DELETE");
}
