import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import {
  emptyMcpConfig,
  isActive,
  mergeServerRows,
  parseMcpConfig,
  removeServer,
  splitCommandLine,
  upsertHttp,
  upsertStdio,
  validRemoteUrl,
  validServerName,
  type McpConfigFile,
  type McpServerScope,
} from "@/lib/mcp-servers";
import { resolveRoot } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function userConfigPath(): string {
  return process.env.GRAFF_MCP_CONFIG || path.join(os.homedir(), ".codegraff", "mcp.json");
}

function localConfigPath(root: string): string {
  return path.join(root, ".mcp.json");
}

function readConfig(file: string): McpConfigFile {
  if (!existsSync(file)) return emptyMcpConfig();
  try {
    return parseMcpConfig(readFileSync(file, "utf8"));
  } catch {
    return emptyMcpConfig();
  }
}

function writeConfig(file: string, config: McpConfigFile): void {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
}

function payload(root: string, mcpEnabled: boolean) {
  const user = readConfig(userConfigPath());
  const local = readConfig(localConfigPath(root));
  const servers = mergeServerRows(user.mcpServers, local.mcpServers).map((row) => ({
    ...row,
    active: isActive(row, mcpEnabled),
  }));
  return { ok: true as const, root, userConfig: userConfigPath(), localConfig: localConfigPath(root), servers };
}

export async function GET(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const mcpEnabled = req.nextUrl.searchParams.get("mcp") !== "0";
  return Response.json(payload(resolved.root, mcpEnabled));
}

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") return Response.json({ error: "expected a JSON object" }, { status: 400 });
  const name = typeof body.name === "string" ? body.name.trim() : "";
  if (!validServerName(name)) {
    return Response.json({ error: "name must be letters, digits, _ or -" }, { status: 400 });
  }
  const scope: McpServerScope = body.scope === "local" ? "local" : "user";
  const resolved = resolveRoot(typeof body.root === "string" ? body.root : null);
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const file = scope === "local" ? localConfigPath(resolved.root) : userConfigPath();
  const config = readConfig(file);
  const url = typeof body.url === "string" ? body.url.trim() : "";
  const commandLine = typeof body.command === "string" ? body.command : "";
  let next: McpConfigFile;
  if (url) {
    if (!validRemoteUrl(url)) {
      return Response.json({ error: "URL must be HTTPS (HTTP only for localhost)" }, { status: 400 });
    }
    next = upsertHttp(config, name, url);
  } else {
    const split = splitCommandLine(commandLine);
    if (!split) return Response.json({ error: "command is required" }, { status: 400 });
    next = upsertStdio(config, name, split.command, split.args);
  }
  writeConfig(file, next);
  const mcpEnabled = body.mcp !== false;
  return Response.json(payload(resolved.root, mcpEnabled));
}

export async function DELETE(req: NextRequest) {
  const name = req.nextUrl.searchParams.get("name")?.trim() ?? "";
  if (!validServerName(name)) return Response.json({ error: "invalid name" }, { status: 400 });
  const scope: McpServerScope = req.nextUrl.searchParams.get("scope") === "local" ? "local" : "user";
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const file = scope === "local" ? localConfigPath(resolved.root) : userConfigPath();
  writeConfig(file, removeServer(readConfig(file), name));
  const mcpEnabled = req.nextUrl.searchParams.get("mcp") !== "0";
  return Response.json(payload(resolved.root, mcpEnabled));
}
