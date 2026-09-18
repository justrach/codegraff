import { readFileSync, realpathSync, statSync } from "node:fs";
import { attachmentDirectory, attachmentStore } from "@/lib/attachment-store";
import path from "node:path";
import { NextRequest } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Pasted and dropped pixels arrive as bytes, but the harness stages a vision
 *  block from a *path* (`@[shot.png]` → `stageGuiImageAttachment`). So the
 *  bytes have to land on disk before a prompt can mention them. They go to a
 *  temp directory rather than the workspace: an attachment belongs to one
 *  message, not to the project the user happens to be sitting in. */
const DIR = attachmentDirectory;

/** Generous on purpose. The harness downscales an oversized image to fit its
 *  own budget, so a tight limit here would refuse work it could actually do;
 *  this only stops something pathological. */
const MAX_BYTES = 25 * 1024 * 1024;

/** Keep the name recognisable in the chip, but never let it steer where the
 *  write lands. The extension carries meaning: `isImagePath` reads it to
 *  decide whether these bytes become a vision block. */
function safeName(raw: string, type: string): string {
  const base = path
    .basename(raw || "")
    .replace(/[^\w.-]+/g, "-")
    .replace(/^[-.]+/, "");
  if (base) return base.slice(0, 80);
  const sub = type.startsWith("image/") ? type.slice(6).split("+")[0] : "";
  return sub ? `pasted.${sub === "jpeg" ? "jpg" : sub}` : "pasted";
}

const IMAGE_TYPES: Record<string, string> = {
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".avif": "image/avif", ".bmp": "image/bmp",
};

/** Serve only staged raster images, never arbitrary paths or active SVG content. */
export async function GET(req: NextRequest) {
  const name = req.nextUrl.searchParams.get("name") ?? "";
  const type = IMAGE_TYPES[path.extname(name).toLowerCase()];
  if (!name || path.basename(name) !== name || !type) {
    return new Response("Invalid image", { status: 400 });
  }
  try {
    const target = realpathSync(path.join(DIR, name));
    if (path.dirname(target) !== realpathSync(DIR)) return new Response("Not found", { status: 404 });
    if (statSync(target).size > MAX_BYTES) return new Response("Image too large", { status: 413 });
    return new Response(readFileSync(target), { headers: {
      "Content-Type": type, "Cache-Control": "private, max-age=3600",
      "X-Content-Type-Options": "nosniff",
    } });
  } catch {
    return new Response("Image no longer available", { status: 404 });
  }
}

export async function POST(req: NextRequest) {
  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return Response.json({ error: "expected multipart/form-data" }, { status: 400 });
  }
  const file = form.get("file");
  if (!(file instanceof File)) return Response.json({ error: "no file field" }, { status: 400 });
  if (file.size === 0) return Response.json({ error: "file is empty" }, { status: 400 });
  if (file.size > MAX_BYTES) {
    return Response.json({ error: `larger than the ${MAX_BYTES / (1024 * 1024)}MB attachment limit` }, { status: 413 });
  }

  attachmentStore().sweep();
  const name = safeName(file.name, file.type);
  let target: string;
  try {
    target = attachmentStore().create(name, new Uint8Array(await file.arrayBuffer()));
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
  return Response.json({ ok: true, path: target, name, type: file.type, size: file.size });
}


export async function DELETE(req: NextRequest) {
  try {
    const body = await req.json();
    if (!Array.isArray(body.paths) || body.paths.length > 32 || !body.paths.every((p: unknown) => typeof p === "string")) {
      return Response.json({ error: "Invalid attachments" }, { status: 400 });
    }
    for (const target of body.paths) attachmentStore().discard(target);
    return Response.json({ ok: true });
  } catch { return Response.json({ error: "Attachment cleanup failed" }, { status: 500 }); }
}
