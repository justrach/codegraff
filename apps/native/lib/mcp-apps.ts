/** Extract only our opaque snapshot id; never accept an arbitrary file URL. */
export function mcpAppId(text: string): string | undefined {
  return /\[MCP app\]\([^\r\n]*\/\.graff\/mcp-apps\/([a-f0-9]{32})\.html\)/.exec(text)?.[1];
}

/** The model's own page (`render_html`), saved and matched the same opaque
 *  way: an id, never a path a tool result could talk us into fetching. */
export function viewSnapshotId(text: string): string | undefined {
  return /\[Rendered view\]\([^\r\n]*\/\.graff\/views\/([a-f0-9]{32})\.html\)/.exec(text)?.[1];
}

export function validAppId(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{32}$/.test(value);
}
