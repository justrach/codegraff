"use client";
import { useEffect, useState } from "react";
import { restoreProjects } from "@/lib/project-preferences";
import { findWorkspace } from "@/lib/workspaces";

type Server = {
  name: string;
  kind: "stdio" | "http";
  target: string;
  scope: "user" | "local";
  disabled: boolean;
  active: boolean;
};
type Payload = { ok: true; servers: Server[] };

export default function McpServers() {
  const [root, setRoot] = useState("");
  const [mcpEnabled, setMcpEnabled] = useState(true);
  const [open, setOpen] = useState(false);
  const [servers, setServers] = useState<Server[]>([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [name, setName] = useState("");
  const [kind, setKind] = useState<"stdio" | "http">("stdio");
  const [command, setCommand] = useState("");
  const [url, setUrl] = useState("");
  const [scope, setScope] = useState<"user" | "local">("user");

  useEffect(() => {
    if (!open) return;
    let alive = true;
    setBusy(true); setError("");
    void (async () => {
      const projects = await restoreProjects(window.localStorage);
      if (!alive) return;
      const active = findWorkspace(projects.list, projects.active)?.path ?? projects.active ?? "";
      const workspace = findWorkspace(projects.list, active);
      setRoot(active);
      setMcpEnabled(workspace?.mcp !== false);
      const params = new URLSearchParams();
      if (active) params.set("root", active);
      params.set("mcp", workspace?.mcp === false ? "0" : "1");
      const response = await fetch(`/api/mcp?${params}`, { cache: "no-store" });
      const body = await response.json() as Payload | { error?: string };
      if (!response.ok || !("ok" in body)) throw new Error("error" in body && body.error ? body.error : "Could not list MCP servers.");
      if (alive) setServers(body.servers);
    })().catch((err: unknown) => { if (alive) setError(err instanceof Error ? err.message : "Could not list MCP servers."); })
      .finally(() => { if (alive) setBusy(false); });
    return () => { alive = false; };
  }, [open]);

  const query = () => {
    const params = new URLSearchParams();
    if (root) params.set("root", root);
    params.set("mcp", mcpEnabled ? "1" : "0");
    return params;
  };

  const add = async () => {
    setBusy(true); setError("");
    try {
      const response = await fetch("/api/mcp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name, scope, root: root || undefined, mcp: mcpEnabled, ...(kind === "http" ? { url } : { command }) }),
      });
      const body = await response.json() as Payload | { error?: string };
      if (!response.ok || !("ok" in body)) throw new Error("error" in body && body.error ? body.error : "Could not add MCP server.");
      setServers(body.servers);
      setName(""); setCommand(""); setUrl("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not add MCP server.");
    } finally { setBusy(false); }
  };

  const remove = async (server: Server) => {
    setBusy(true); setError("");
    try {
      const params = query();
      params.set("name", server.name);
      params.set("scope", server.scope);
      const response = await fetch(`/api/mcp?${params}`, { method: "DELETE" });
      const body = await response.json() as Payload | { error?: string };
      if (!response.ok || !("ok" in body)) throw new Error("error" in body && body.error ? body.error : "Could not remove MCP server.");
      setServers(body.servers);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not remove MCP server.");
    } finally { setBusy(false); }
  };

  return (
    <details className="mt-3 border-t border-line pt-3" onToggle={(event) => setOpen((event.target as HTMLDetailsElement).open)}>
      <summary className="cursor-pointer text-xs font-medium text-ink-2 hover:text-ink">MCP servers</summary>
      <div className="mt-2">
        {busy && servers.length === 0 ? <p className="text-[11px] text-ink-3">Loading…</p> : null}
        {!mcpEnabled && <p className="mb-2 text-[11px] text-ink-3">Off for this folder — turn on in Project settings.</p>}
        {servers.length === 0 && !busy ? <p className="text-[11px] text-ink-3">None configured.</p> : (
          <ul className="grid gap-0.5">
            {servers.map((server) => (
              <li key={`${server.scope}:${server.name}`} className="flex items-center gap-2 py-0.5" title={server.target}>
                <span className="min-w-0 flex-1 truncate text-[12px] text-ink">{server.name}</span>
                <span className="shrink-0 text-[10px] text-ink-3">{server.active ? "On" : "Off"}</span>
                <button type="button" disabled={busy} onClick={() => void remove(server)} className="shrink-0 rounded px-1 text-[11px] text-ink-3 hover:bg-hover hover:text-ink">Remove</button>
              </li>
            ))}
          </ul>
        )}
        <form className="mt-2 grid gap-1.5" onSubmit={(event) => { event.preventDefault(); void add(); }}>
          <input value={name} onChange={(event) => setName(event.target.value)} placeholder="Name" aria-label="Server name" className="h-7 rounded-[8px] bg-inset px-2 text-[12px] text-ink shadow-hairline" />
          <div className="flex gap-1">
            <button type="button" aria-pressed={kind === "stdio"} onClick={() => setKind("stdio")} className={`h-6 rounded-full px-2 text-[11px] ${kind === "stdio" ? "bg-hover-2 text-ink" : "text-ink-3"}`}>Command</button>
            <button type="button" aria-pressed={kind === "http"} onClick={() => setKind("http")} className={`h-6 rounded-full px-2 text-[11px] ${kind === "http" ? "bg-hover-2 text-ink" : "text-ink-3"}`}>URL</button>
          </div>
          {kind === "http"
            ? <input value={url} onChange={(event) => setUrl(event.target.value)} placeholder="https://…" aria-label="Server URL" className="h-7 rounded-[8px] bg-inset px-2 font-mono text-[11px] text-ink shadow-hairline" />
            : <input value={command} onChange={(event) => setCommand(event.target.value)} placeholder="command" aria-label="Server command" className="h-7 rounded-[8px] bg-inset px-2 font-mono text-[11px] text-ink shadow-hairline" />}
          <button type="submit" disabled={busy || !name.trim() || (kind === "http" ? !url.trim() : !command.trim())} className="h-7 rounded-full bg-hover-2 px-3 text-[12px] font-medium text-ink disabled:opacity-50">Add</button>
        </form>
        {error && <p role="alert" className="mt-2 text-[11px] text-red">{error}</p>}
      </div>
    </details>
  );
}
