/** User- and workspace-level MCP config (`mcpServers`) for the native GUI. */

export type McpServerKind = "stdio" | "http";
export type McpServerScope = "user" | "local";

export type McpServerSpec = {
  command?: unknown;
  args?: unknown;
  url?: unknown;
  disabled?: unknown;
};

export type McpServerRow = {
  name: string;
  kind: McpServerKind;
  target: string;
  scope: McpServerScope;
  disabled: boolean;
};

export type McpConfigFile = { mcpServers: Record<string, McpServerSpec> };

const NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

export function validServerName(name: string): boolean {
  return NAME.test(name);
}

/** HTTPS, or HTTP only for loopback — same rule as `graff mcp add --url`. */
export function validRemoteUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "https:") return true;
    if (parsed.protocol !== "http:") return false;
    return parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1" || parsed.hostname === "::1";
  } catch {
    return false;
  }
}

export function parseMcpConfig(text: string): McpConfigFile {
  const parsed = JSON.parse(text) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("MCP config must be a JSON object");
  }
  const servers = (parsed as { mcpServers?: unknown }).mcpServers;
  if (servers == null) return { mcpServers: {} };
  if (!servers || typeof servers !== "object" || Array.isArray(servers)) {
    throw new Error("mcpServers must be an object");
  }
  return { mcpServers: servers as Record<string, McpServerSpec> };
}

export function emptyMcpConfig(): McpConfigFile {
  return { mcpServers: {} };
}

function stringArg(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export function rowFromEntry(name: string, entry: McpServerSpec | undefined, scope: McpServerScope): McpServerRow | null {
  if (!entry || typeof entry !== "object") return null;
  const disabled = entry.disabled === true;
  const url = stringArg(entry.url);
  if (url) {
    return { name, kind: "http", target: url, scope, disabled };
  }
  const command = stringArg(entry.command);
  if (!command) return null;
  const args = Array.isArray(entry.args)
    ? entry.args.filter((arg): arg is string => typeof arg === "string")
    : [];
  const target = [command, ...args].join(" ");
  return { name, kind: "stdio", target, scope, disabled };
}

/** Project entries win on name conflict, matching `src/mcp_config.zig`. */
export function mergeServerRows(
  user: Record<string, McpServerSpec>,
  local: Record<string, McpServerSpec>,
): McpServerRow[] {
  const rows = new Map<string, McpServerRow>();
  for (const [name, entry] of Object.entries(user)) {
    const row = rowFromEntry(name, entry, "user");
    if (row) rows.set(name, row);
  }
  for (const [name, entry] of Object.entries(local)) {
    const row = rowFromEntry(name, entry, "local");
    if (row) rows.set(name, row);
  }
  return [...rows.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function upsertStdio(
  config: McpConfigFile,
  name: string,
  command: string,
  args: string[],
): McpConfigFile {
  return {
    mcpServers: {
      ...config.mcpServers,
      [name]: { command, args },
    },
  };
}

export function upsertHttp(config: McpConfigFile, name: string, url: string): McpConfigFile {
  return {
    mcpServers: {
      ...config.mcpServers,
      [name]: { url },
    },
  };
}

export function removeServer(config: McpConfigFile, name: string): McpConfigFile {
  const mcpServers = { ...config.mcpServers };
  delete mcpServers[name];
  return { mcpServers };
}

export function splitCommandLine(line: string): { command: string; args: string[] } | null {
  const parts = line.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return null;
  return { command: parts[0]!, args: parts.slice(1) };
}

/** A configured server is active when MCP start is on and the entry is not disabled. */
export function isActive(row: McpServerRow, mcpEnabled: boolean): boolean {
  return mcpEnabled && !row.disabled;
}
