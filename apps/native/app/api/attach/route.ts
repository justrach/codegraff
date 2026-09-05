import { mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Pasted and dropped pixels arrive as bytes, but the harness stages a vision
 *  block from a *path* (`@[shot.png]` → `stageGuiImageAttachment`). So the
 *  bytes have to land on disk before a prompt can mention them. They go to a
 *  temp directory rather than the workspace: an attachment belongs to one
 *  message, not to the project the user happens to be sitting in. */
const DIR = path.join(os.tmpdir(), "graff-native-attachments");

/** Generous on purpose. The harness downscales an oversized image to fit its
 *  own budget, so a tight limit here would refuse work it could actually do;
 *  this only stops something pathological. */
const MAX_BYTES = 25 * 1024 * 1024;

/** Attachments are per-message scratch. Sweep anything from a previous day so
 *  the directory cannot grow without bound. */
const MAX_AGE_MS = 24 * 60 * 60 * 1000;

function sweep(now: number) {
  let entries: string[];
  try {
    entries = readdirSync(DIR);
  } catch {
    return;
  }
  for (const name of entries) {
    const full = path.join(DIR, name);
    try {
      if (now - statSync(full).mtimeMs > MAX_AGE_MS) rmSync(full, { force: true });
    } catch {
      // raced with another sweep, or not ours to remove
    }
  }
}

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

  const now = Date.now();
  mkdirSync(DIR, { recursive: true });
  sweep(now);

  const name = safeName(file.name, file.type);
  // Collisions are otherwise certain: every pasted screenshot has the same name.
  const stamped = `${now.toString(36)}-${Math.random().toString(36).slice(2, 8)}-${name}`;
  const target = path.join(DIR, stamped);
  try {
    writeFileSync(target, new Uint8Array(await file.arrayBuffer()));
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
  return Response.json({ ok: true, path: target, name, type: file.type, size: file.size });
}
