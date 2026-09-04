/** Browser annotations: the pins a user drops on the sidecar's page and the
 * block that carries them to the agent. Pure helpers, shared by the pane
 * (browser) and the route (server), tested without a DOM. */

export type PinRect = { x: number; y: number; w: number; h: number };

/** What the page said about the element under the pointer. */
export type PinElement = {
  tag: string;
  role: string;
  name: string;
  text: string;
  selector: string;
  href: string | null;
  rect: PinRect;
};

export type BrowserPin = {
  id: number;
  /** What the user wants done here. */
  comment: string;
  url: string;
  title: string;
  /** Kuri's ref for the same element (`e7`), when the snapshot names it. */
  ref: string | null;
  element: PinElement;
  /** Viewport point of the click, CSS pixels. */
  point: { x: number; y: number };
  /** The element's box in page coordinates (viewport box plus the scroll
   * offset at pin time), so the marker follows the page when it scrolls. */
  doc?: PinRect;
};

export type SnapshotRow = { role: string; name: string; ref: string };

/** Kuri's compact snapshot: one element per line, `role "name" @eN`, refs
 * only on interactive nodes. Names may contain escaped quotes. */
export function parseSnapshotRefs(snapshot: string): SnapshotRow[] {
  const rows: SnapshotRow[] = [];
  for (const raw of snapshot.split("\n")) {
    const line = raw.trim();
    const at = line.lastIndexOf(" @");
    if (at < 0) continue;
    const ref = line.slice(at + 2).split(/\s/)[0];
    if (!/^e[\w]+$/.test(ref)) continue;
    const head = line.slice(0, at);
    const quote = head.indexOf(' "');
    const role = (quote < 0 ? head : head.slice(0, quote)).trim().split(/\s/)[0] ?? "";
    let name = "";
    if (quote >= 0) {
      const rest = head.slice(quote + 2);
      const close = rest.lastIndexOf('"');
      name = (close >= 0 ? rest.slice(0, close) : rest).replace(/\\"/g, '"');
    }
    rows.push({ role, name, ref });
  }
  return rows;
}

function norm(s: string): string {
  return s.trim().replace(/\s+/g, " ").toLowerCase();
}

/** The ref whose accessible name matches the pinned element. Role must
 * agree when the page gave one; a name shared by several nodes is no
 * match — a wrong ref is worse than none. */
export function matchRef(rows: readonly SnapshotRow[], element: Pick<PinElement, "name" | "role" | "text">): string | null {
  const wanted = norm(element.name) || norm(element.text);
  if (!wanted) return null;
  const role = norm(element.role);
  const byName = rows.filter((r) => norm(r.name) === wanted);
  const pool = role ? byName.filter((r) => norm(r.role) === role) : byName;
  const hits = pool.length > 0 ? pool : byName;
  return hits.length === 1 ? hits[0].ref : null;
}

export function describePin(pin: BrowserPin): string {
  const el = pin.element;
  const what = [el.role || el.tag, el.name ? `"${el.name}"` : ""].filter(Boolean).join(" ");
  const where = `${Math.round(el.rect.w)}×${Math.round(el.rect.h)} at ${Math.round(el.rect.x)},${Math.round(el.rect.y)}`;
  const ref = pin.ref ? `[@${pin.ref}] ` : "";
  return `${ref}${what} (${el.selector}, ${where})`;
}

export type KuriHandle = { port: number; token: string; tabId: string };

/** The markdown block that goes ahead of the user's prompt. It names the
 * page, lists every pin with the element's identity and the user's note,
 * and tells the agent how to drive the very same tab. */
export function annotationsBlock(pins: readonly BrowserPin[], kuri: KuriHandle | null): string {
  if (pins.length === 0) return "";
  const first = pins[0];
  const lines: string[] = [];
  lines.push("### Browser annotations (sidecar)");
  lines.push(`Page: ${first.title || "(untitled)"} — ${first.url}`);
  pins.forEach((pin, i) => {
    const note = pin.comment.trim() ? `: ${pin.comment.trim()}` : "";
    lines.push(`${i + 1}. ${describePin(pin)}${note}`);
    if (pin.element.text && pin.element.text !== pin.element.name) lines.push(`   text: "${pin.element.text.slice(0, 120)}"`);
    if (pin.url !== first.url) lines.push(`   on: ${pin.url}`);
  });
  if (kuri) {
    const ref = pins.find((p) => p.ref)?.ref ?? "e7";
    lines.push("");
    lines.push(
      `The page is open in the sidecar browser (kuri) at http://127.0.0.1:${kuri.port}, tab_id=${kuri.tabId}, ` +
        `header \`Authorization: Bearer ${kuri.token}\`. Re-read it with ` +
        `GET /snapshot?tab_id=${kuri.tabId}&filter=interactive&format=compact, act on a ref with ` +
        `GET /action?tab_id=${kuri.tabId}&ref=${ref}&action=click (also type/fill/hover/scroll), ` +
        `run JS with GET /evaluate?tab_id=${kuri.tabId}&expression=…, and GET /highlight?tab_id=${kuri.tabId}&ref=${ref} ` +
        `shows the user what you mean. The user sees that tab live.`,
    );
  }
  return lines.join("\n");
}
