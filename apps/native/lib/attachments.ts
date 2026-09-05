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

/** Write one file to the harness-readable temp directory and describe it. */
export async function uploadAttachment(file: File): Promise<Attachment> {
  const body = new FormData();
  body.append("file", file);
  const res = await fetch("/api/attach", { method: "POST", body });
  const json = (await res.json()) as { path?: string; name?: string; error?: string };
  if (!res.ok || !json.path) throw new Error(json.error ?? `attach failed (${res.status})`);
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
