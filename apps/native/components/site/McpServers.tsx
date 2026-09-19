"use client";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { restoreActionFocus } from "../primitives/ActionMenu";
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

export default function McpServers({ labeled = false }: { labeled?: boolean }) {
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
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);

  const query = () => {
    const params = new URLSearchParams();
    if (root) params.set("root", root);
    params.set("mcp", mcpEnabled ? "1" : "0");
    return params;
  };

  useEffect(() => {
    if (!open) return;
    let alive = true;
    setBusy(true);
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
    panel.current?.querySelector<HTMLInputElement>("input")?.focus();
    const keys = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.stopPropagation(); setOpen(false); restoreActionFocus(trigger.current); }
    };
    document.addEventListener("keydown", keys);
    return () => { alive = false; document.removeEventListener("keydown", keys); };
  }, [open]);

  const add = async () => {
    setBusy(true); setError("");
    try {
      const response = await fetch("/api/mcp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          name, scope, root: root || undefined, mcp: mcpEnabled,
          ...(kind === "http" ? { url } : { command }),
        }),
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

  return <>
    <button ref={trigger} type="button" aria-label="MCP servers" aria-haspopup="dialog" aria-expanded={open}
      onClick={event => { event.stopPropagation(); setOpen((value) => !value); }}
      className={labeled
        ? "flex w-full items-center justify-start rounded-md px-3 py-2 text-left text-xs text-ink-3 hover:bg-hover hover:text-ink"
        : "flex size-8 shrink-0 items-center justify-center rounded-lg text-ink-3 hover:bg-hover hover:text-ink"}>
      MCP servers
    </button>
    {open && createPortal(<div className="fixed inset-0 z-[200] flex items-center justify-center bg-black/20 p-4" onPointerDown={(event) => {
      if (event.target === event.currentTarget) { setOpen(false); restoreActionFocus(trigger.current); }
    }}>
      <div ref={panel} role="dialog" aria-label="MCP servers" aria-modal="true" className="flex max-h-[min(36rem,calc(100vh-2rem))] w-[440px] max-w-full flex-col rounded-xl border border-line bg-surface shadow-overlay">
        <div className="flex items-center justify-between border-b border-line px-4 py-3">
          <strong className="text-sm font-medium">MCP servers</strong>
          <button type="button" aria-label="Close MCP servers" onClick={() => { setOpen(false); restoreActionFocus(trigger.current); }} className="rounded px-1.5 text-ink-3 hover:bg-hover">×</button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-4 py-3">
          <p className="mb-3 text-[12px] text-ink-3">
            Servers already in <span className="font-mono text-ink-2">~/.codegraff/mcp.json</span> or this folder's <span className="font-mono text-ink-2">.mcp.json</span> show here.
            Active means they will start with new chats (Start MCP servers is on).
          </p>
          {!mcpEnabled && <p className="mb-3 rounded-lg bg-inset px-3 py-2 text-[12px] text-ink-2">Start MCP servers is off for this folder, so every server is inactive until you turn it on in Project settings.</p>}
          {servers.length === 0 && !busy ? <p className="mb-3 text-[12px] text-ink-3">No MCP servers configured yet.</p> : (
            <ul className="mb-4 grid gap-2">
              {servers.map((server) => (
                <li key={`${server.scope}:${server.name}`} className="rounded-lg border border-line px-3 py-2">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="text-[13px] font-medium text-ink">{server.name}</span>
                        <span className={`rounded-full px-1.5 py-0.5 text-[10px] font-medium ${server.active ? "bg-accent-tint text-accent" : "bg-inset text-ink-3"}`}>
                          {server.active ? "Active" : "Inactive"}
                        </span>
                        <span className="text-[10px] text-ink-3">{server.kind === "http" ? "HTTP" : "stdio"} · {server.scope}</span>
                      </div>
                      <p className="mt-0.5 truncate font-mono text-[11px] text-ink-3" title={server.target}>{server.target}</p>
                    </div>
                    <button type="button" disabled={busy} onClick={() => void remove(server)} className="shrink-0 rounded px-1.5 text-[11px] text-ink-3 hover:bg-hover hover:text-ink">Remove</button>
                  </div>
                </li>
              ))}
            </ul>
          )}
          <form className="grid gap-2 border-t border-line pt-3" onSubmit={(event) => { event.preventDefault(); void add(); }}>
            <div className="text-[12px] font-medium text-ink">Add a server</div>
            <input value={name} onChange={(event) => setName(event.target.value)} placeholder="Name" aria-label="Server name" className="h-8 rounded-[8px] bg-inset px-2.5 text-[12px] text-ink shadow-hairline" />
            <div className="flex gap-2">
              <button type="button" aria-pressed={kind === "stdio"} onClick={() => setKind("stdio")} className={`h-7 rounded-full px-2.5 text-[11px] ${kind === "stdio" ? "bg-accent-tint text-accent" : "bg-hover-2 text-ink-2"}`}>Command</button>
              <button type="button" aria-pressed={kind === "http"} onClick={() => setKind("http")} className={`h-7 rounded-full px-2.5 text-[11px] ${kind === "http" ? "bg-accent-tint text-accent" : "bg-hover-2 text-ink-2"}`}>URL</button>
              <select value={scope} onChange={(event) => setScope(event.target.value as "user" | "local")} aria-label="Save in" className="ml-auto h-7 rounded-full bg-hover-2 px-2 text-[11px] text-ink-2">
                <option value="user">All folders</option>
                <option value="local">This folder</option>
              </select>
            </div>
            {kind === "http" ? (
              <input value={url} onChange={(event) => setUrl(event.target.value)} placeholder="https://…" aria-label="Server URL" className="h-8 rounded-[8px] bg-inset px-2.5 font-mono text-[12px] text-ink shadow-hairline" />
            ) : (
              <input value={command} onChange={(event) => setCommand(event.target.value)} placeholder="npx -y @modelcontextprotocol/server-filesystem ." aria-label="Server command" className="h-8 rounded-[8px] bg-inset px-2.5 font-mono text-[12px] text-ink shadow-hairline" />
            )}
            <button type="submit" disabled={busy || !name.trim() || (kind === "http" ? !url.trim() : !command.trim())} className="h-8 rounded-full bg-ink px-3 text-[12.5px] font-medium text-surface disabled:opacity-50">Add</button>
          </form>
          {error && <p role="alert" className="mt-3 text-[12px] text-red">{error}</p>}
        </div>
      </div>
    </div>, document.body)}
  </>;
}
