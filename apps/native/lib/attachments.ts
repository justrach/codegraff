/** Composer attachments: pixels and files that arrive as bytes rather than as
 *  a path the agent could already open.
 *
 *  The harness stages vision blocks from `@[path]` markers in the prompt text
 *  (`stageGuiImageAttachment`), so the browser cannot hand over the bytes
 *  directly — they are written to a temp file first and the prompt mentions
 *  that path. A non-image attachment goes through the same door: the marker
 *  stays literal text and the agent opens it with its own tools. */

export type Attachment = {
  /** Stable across re-renders; the temp path is unique enough to be the key. */
  id: string;
  /** What the chip shows — the original name, not the stamped temp one. */
  name: string;
  /** Absolute temp path, the thing `@[…]` names. */
  path: string;
  /** An object URL for image chips. Revoke it when the chip goes away. */
  preview?: string;
};

/** Anything an image chip can meaningfully preview and the harness can stage.
 *  `isImagePath` in the harness reads the extension, so the type has to
 *  survive as one — a `.webp` pasted as `image/webp` stays a webp. */
export function isImageFile(file: File): boolean {
  return file.type.startsWith("image/");
}

/** The files carried by a paste or a drop. A copied screenshot arrives as an
 *  `image/*` item with an empty name; a copied *file* arrives with its own.
 *  Plain text pastes carry no files at all, which is why the caller must let
 *  the event through untouched when this comes back empty. */
export function filesFrom(data: DataTransfer | null | undefined): File[] {
  if (!data) return [];
  const out: File[] = [];
  // `items` is the only view that exposes a pasted screenshot; `files` is the
  // only one some browsers populate on drop. Prefer items, fall back.
  if (data.items && data.items.length > 0) {
    for (const item of Array.from(data.items)) {
      if (item.kind !== "file") continue;
      const file = item.getAsFile();
      if (file) out.push(file);
    }
  }
  if (out.length === 0 && data.files) out.push(...Array.from(data.files));
  return out;
}

/** File-picker rows must keep the user gesture; preventDefault drops it. */
export function attachRowKeepsUserActivation(rowKey: string): boolean {
  return rowKey === "attach";
}

/** Generous: a large paste should finish, but a hung HTTP/1.1 slot must not. */
export const ATTACH_TIMEOUT_MS = 30_000;

export function attachTimeoutMessage(name: string): string {
  return `Adding ${name.trim() || "the file"} timed out. Try again.`;
}

function attachFailure(err: unknown, name: string): Error {
  if (err instanceof DOMException && (err.name === "TimeoutError" || err.name === "AbortError")) {
    return new Error(attachTimeoutMessage(name));
  }
  const detail = err instanceof Error ? err.message : String(err);
  const label = name.trim();
  return new Error(label ? `${label}: ${detail}` : detail);
}

/** Write one file to the harness-readable temp directory and describe it. */
export async function uploadAttachment(file: File, timeoutMs = ATTACH_TIMEOUT_MS, signal?: AbortSignal): Promise<Attachment> {
  const body = new FormData();
  body.append("file", file);
  const timeout = AbortSignal.timeout(timeoutMs);
  const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
  let res: Response;
  try {
    res = await fetch("/api/attach", { method: "POST", body, signal: combined });
  } catch (err) {
    throw attachFailure(err, file.name ?? "");
  }
  const json = (await res.json()) as { path?: string; name?: string; error?: string };
  if (!res.ok || !json.path) {
    throw attachFailure(new Error(json.error ?? `attach failed (${res.status})`), file.name ?? "");
  }
  return {
    id: json.path,
    name: json.name ?? file.name ?? "attachment",
    path: json.path,
    preview: isImageFile(file) ? URL.createObjectURL(file) : undefined,
  };
}

/** The marker the harness looks for. */
export function marker(attachment: Attachment): string {
  return `@[${attachment.path}]`;
}

/** A staged-image marker inside prompt text. One pattern for every reader: the
 *  transcript bubble and a queued chip must not disagree about what counts as
 *  an image. A marker naming anywhere else stays literal text — only files
 *  under the attachment directory can be served back by `/api/attach`. */
const IMAGE_MARKER_RE = /(@\[[^\]\n]*\/graff-native-attachments\/[^/\]\n]+\.(?:png|jpe?g|gif|webp|avif|bmp)\])/gi;

/** Prompt text split into literal runs and image markers; odd indexes are the
 *  markers, which is why every reader tests `index % 2`. */
export function splitImageMarkers(text: string): string[] {
  return text.split(IMAGE_MARKER_RE);
}

/** Pull staged-image markers out of draft text so the composer never shows
 *  `@[…/graff-native-attachments/….png]` as spellchecked prose. */
export function liftAttachmentMarkers(text: string): { text: string; attachments: Attachment[] } {
  const parts = splitImageMarkers(text);
  if (parts.length < 2) return { text, attachments: [] };
  const attachments: Attachment[] = [];
  let visible = "";
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i]!;
    if (i % 2 === 1) {
      const path = part.slice(2, -1);
      attachments.push({
        id: path,
        name: markerName(part),
        path,
        preview: `/api/attach?name=${encodeURIComponent(markerName(part))}`,
      });
    } else {
      visible += part;
    }
  }
  return { text: visible.replace(/[ \t]{2,}/g, " ").trim(), attachments };
}

/** The staged file's basename — the name `/api/attach?name=` answers to. */
export function markerName(marker: string): string {
  return marker.slice(marker.lastIndexOf("/") + 1, -1);
}

/** The prompt text as it goes on the wire: the draft, then a marker for every
 *  attachment the draft has not already named. Someone who typed the path by
 *  hand and also dropped the file should not send it twice. */
export function withAttachmentMarkers(text: string, attachments: readonly Attachment[]): string {
  const missing = attachments.filter((a) => !text.includes(marker(a))).map(marker);
  if (missing.length === 0) return text;
  return [text.trim(), ...missing].filter(Boolean).join(" ");
}

/** Object URLs outlive the component that made them; free them explicitly. */
export function releaseAttachments(attachments: readonly Attachment[]): void {
  for (const a of attachments) if (a.preview) URL.revokeObjectURL(a.preview);
}


/** Dropped drafts release their owned files; sent attachments only release URLs. */
export function discardAttachments(attachments: readonly Attachment[]): void {
  releaseAttachments(attachments);
  if (!attachments.length) return;
  for (let i = 0; i < attachments.length; i += 32) {
    void fetch("/api/attach", { method: "DELETE", headers: { "content-type": "application/json" },
      body: JSON.stringify({ paths: attachments.slice(i, i + 32).map(a => a.path) }), keepalive: true }).catch(() => {});
  }
}
