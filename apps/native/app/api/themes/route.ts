import { listThemes, saveTheme } from "@/lib/theme-files";
import { themeLimit } from "@/lib/custom-themes";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET() {
  try { return Response.json(await listThemes(), { headers: { "cache-control": "no-store" } }); }
  catch { return Response.json({ error: "Could not read your themes folder." }, { status: 500 }); }
}
export async function POST(request: Request) {
  const reader = request.body?.getReader(); if (!reader) return Response.json({ error: "Choose a theme JSON file." }, { status: 400 });
  try {
    let size = 0; const chunks: Uint8Array[] = [];
    while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; if (size > themeLimit) { await reader.cancel(); return Response.json({ error: "Theme exceeds 16 KiB." }, { status: 413 }); } chunks.push(value); }
    return Response.json(await saveTheme(JSON.parse(Buffer.concat(chunks).toString("utf8"))));
  } catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Could not import theme." }, { status: 400 }); }
  finally { reader.releaseLock(); }
}
