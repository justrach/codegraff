/** Extract only our opaque snapshot id; never accept an arbitrary file URL. */
export function mcpAppId(text: string): string | undefined {
  return /\[MCP app\]\([^\r\n]*\/\.graff\/mcp-apps\/([a-f0-9]{32})\.html\)/.exec(text)?.[1];
}

export function validAppId(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{32}$/.test(value);
}
