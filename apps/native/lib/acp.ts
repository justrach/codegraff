/** ACP v1 session/update shapes the native harness renders. */

export type AcpContent = { type: "text"; text: string };

/** One entry of the agent's `available_commands_update`: the slash commands
 * this build actually services, named without the leading slash. */
export type AcpCommand = { name: string; description: string; input?: { hint?: string } | null };

export type AcpToolKind = "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "other";

export type AcpToolStatus = "pending" | "in_progress" | "completed" | "failed";

export type AcpUpdate =
  | { sessionUpdate: "agent_thought_chunk"; content: AcpContent }
  | { sessionUpdate: "agent_message_chunk"; content: AcpContent }
  | {
      sessionUpdate: "tool_call";
      toolCallId: string;
      title?: string;
      kind?: AcpToolKind | string;
      status?: AcpToolStatus | string;
      rawInput?: Record<string, unknown>;
      locations?: { path: string }[];
    }
  | {
      sessionUpdate: "tool_call_update";
      toolCallId: string;
      title?: string;
      kind?: AcpToolKind | string;
      status?: AcpToolStatus | string;
      rawInput?: Record<string, unknown>;
      content?: { type: string; content?: AcpContent }[];
    }
  | { sessionUpdate: string; [key: string]: unknown };

export type JsonRpcLine =
  | { jsonrpc?: string; method: "session/update"; params: { sessionId?: string; update: AcpUpdate } }
  | { jsonrpc?: string; id: number | string; result: unknown }
  | { jsonrpc?: string; id: number | string; error: { code: number; message: string } };

import {
  emptyTurn,
  type AssistantTurn,
  type ToolIcon,
  type ToolRow,
  type TodoItem,
} from "./graff-events.ts";

function iconForKind(kind: string | undefined, title: string): ToolIcon {
  if (kind === "execute") return "run";
  if (kind === "edit" || kind === "delete" || kind === "move") return "write";
  if (kind === "read" || kind === "fetch" || kind === "search") return "read";
  if (title.includes("bash") || title.includes("run")) return "run";
  return "think";
}

/** `mcp__codedbpro__faster_search` → { server: "codedbpro", tool: "faster_search" } */
function mcpParts(name: string): { server: string; tool: string } | null {
  if (!name.startsWith("mcp__")) return null;
  const rest = name.slice(5);
  const split = rest.indexOf("__");
  if (split < 0) return { server: "", tool: rest };
  return { server: rest.slice(0, split), tool: rest.slice(split + 2) };
}

function humanize(id: string): string {
  const words = id.replace(/[_-]+/g, " ").trim();
  return words ? words[0].toUpperCase() + words.slice(1) : id;
}

function labelForKind(kind: string | undefined, title: string): string {
  const mcp = mcpParts(title);
  if (mcp) return humanize(mcp.tool);
  // Bare engine tools (codedb, todo_write…) beat a generic kind of "read".
  if (/^[a-z][a-z0-9_]*$/.test(title)) return humanize(title);
  if (kind === "execute") return "Run";
  if (kind === "edit") return "Edit";
  if (kind === "delete") return "Delete";
  if (kind === "move") return "Move";
  if (kind === "read") return "Read";
  if (kind === "fetch") return "Fetch";
  if (kind === "search") return "Search";
  if (kind === "think") return "Plan";
  return title;
}

function firstLine(s: string): string {
  const line = s.split("\n")[0] ?? s;
  return line.length > 80 ? `${line.slice(0, 79)}…` : line;
}

function detailFromInput(input: Record<string, unknown>): ToolRow["detail"] {
  const oldS = typeof input.old_string === "string" ? input.old_string : "";
  const newS = typeof input.new_string === "string" ? input.new_string : "";
  if (oldS || newS) {
    const lines: ToolRow["detail"] = [];
    if (oldS) lines.push({ text: firstLine(oldS) });
    if (newS) lines.push({ text: firstLine(newS), tone: "add" });
    return lines;
  }
  if (typeof input.command === "string") return [{ text: input.command }];
  if (typeof input.content === "string") {
    return [{ text: `${input.content.split("\n").length} lines`, tone: "add" }];
  }
  return [];
}

function mergeDiff(turn: AssistantTurn, row: ToolRow, text: string): AssistantTurn["diffs"] {
  const file = row.path ?? (row.chip !== row.name ? row.chip : "");
  if (!file) return turn.diffs;
  const lines = (text || row.detail.map((d) => d.text).join("\n"))
    .split("\n")
    .slice(0, 8)
    .map((line) => ({
      text: line.slice(0, 80),
      tone: (line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : row.icon === "write" && line ? "add" : "ctx") as
        | "add"
        | "del"
        | "ctx",
    }));
  const chip = {
    file,
    add: Math.max(1, row.detail.filter((d) => d.tone === "add").length),
    del: row.icon === "write" ? 1 : 0,
    lines: lines.length ? lines : [{ text: file, tone: "ctx" as const }],
  };
  const idx = turn.diffs.findIndex((d) => d.file === file);
  if (idx < 0) return [...turn.diffs, chip];
  const next = turn.diffs.slice();
  next[idx] = chip;
  return next;
}

function parseTodos(input: Record<string, unknown> | undefined): TodoItem[] {
  const raw = input?.todos ?? input?.items ?? input?.list;
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item, i) => {
    if (!item || typeof item !== "object") return [];
    const rec = item as Record<string, unknown>;
    const content = typeof rec.content === "string" ? rec.content : typeof rec.text === "string" ? rec.text : "";
    if (!content) return [];
    const status =
      rec.status === "completed" || rec.status === "in_progress" || rec.status === "pending" ? rec.status : "pending";
    const id = typeof rec.id === "string" ? rec.id : `todo-${i}`;
    return [{ id, content, status }];
  });
}

function upsertTool(turn: AssistantTurn, update: Extract<AcpUpdate, { toolCallId: string }>): AssistantTurn {
  const id = update.toolCallId;
  const idx = turn.tools.findIndex((t) => t.id === id);
  const prev = idx >= 0 ? turn.tools[idx] : undefined;
  const title = typeof update.title === "string" ? update.title : prev?.chip ?? id;
  const kind = typeof update.kind === "string" ? update.kind : prev ? undefined : "other";
  const statusRaw = typeof update.status === "string" ? update.status : prev ? undefined : "pending";
  const status: ToolRow["status"] = statusRaw
    ? statusRaw === "completed"
      ? "ok"
      : statusRaw === "failed"
        ? "error"
        : "running"
    : (prev?.status ?? "running");
  const rawInput = update.rawInput && typeof update.rawInput === "object" ? update.rawInput : {};
  // codedbpro-style tools say `file`, catalog tools say `path`.
  const path =
    typeof rawInput.path === "string"
      ? rawInput.path
      : typeof rawInput.file === "string"
        ? rawInput.file
        : prev?.path;
  const contentItems = "content" in update && Array.isArray(update.content) ? update.content : [];
  const contentText = contentItems
    .map((item) => item.content?.text)
    .filter((t): t is string => typeof t === "string")
    .join("\n");
  const fromInput = detailFromInput(rawInput);
  const detail = contentText
    ? [...(prev?.detail ?? fromInput), { text: firstLine(contentText) }]
    : fromInput.length
      ? fromInput
      : (prev?.detail ?? []);
  const mcp = mcpParts(title);
  const label = labelForKind(kind, title);
  const command = typeof rawInput.command === "string" ? firstLine(rawInput.command) : undefined;
  // A raw MCP name as chip repeated the label; show the server instead, and
  // no chip at all when it would just echo the label. codedb's query lives
  // in `command` — without it every call rendered as a blank "Read".
  const chipRaw = path ?? command ?? (mcp ? mcp.server : title);
  const row: ToolRow = {
    id,
    name: label,
    icon: iconForKind(kind, title),
    chip: chipRaw === label || humanize(chipRaw) === label ? "" : chipRaw,
    status,
    detail,
    path,
    startedAt: prev?.startedAt ?? Date.now(),
    atChars: prev?.atChars ?? turn.text.length,
  };
  const tools = turn.tools.slice();
  const merged: ToolRow = idx >= 0
    ? { ...prev!, ...row, name: kind ? row.name : prev!.name, icon: kind ? row.icon : prev!.icon }
    : row;
  if ((status === "ok" || status === "error") && merged.elapsedMs === undefined && merged.startedAt !== undefined) {
    merged.elapsedMs = Date.now() - merged.startedAt;
  }
  if (idx >= 0) tools[idx] = merged;
  else tools.push(merged);
  const todos = parseTodos(rawInput);
  const next: AssistantTurn = {
    ...turn,
    tools,
    todos: todos.length ? todos : turn.todos,
    // Text after a tool bracket is a new message segment, not a continuation.
    pendingBreak: turn.text.length > 0 ? true : turn.pendingBreak,
    status: turn.status === "ask" ? "ask" : status === "running" || turn.status === "thinking" ? "streaming" : turn.status,
  };
  if ((merged.icon === "write" || kind === "edit") && (status === "ok" || status === "error")) {
    return { ...next, diffs: mergeDiff(next, merged, contentText) };
  }
  return next;
}

export function finishAcpTurn(turn: AssistantTurn): AssistantTurn {
  if (turn.status === "error") return turn;
  return {
    ...turn,
    tools: turn.tools.map((t) => (t.status === "running" ? { ...t, status: "ok" as const } : t)),
    status: "done",
  };
}

export type TurnBlock = { kind: "text"; text: string } | { kind: "tools"; tools: ToolRow[] };

/** Split a turn into the order the user should see it: text, then the tools
 * that landed at that cursor, then the next text. Tools without `atChars`
 * (old sessions) stay in a single group at the top. */
export function turnBlocks(text: string, tools: ToolRow[]): TurnBlock[] {
  if (tools.length === 0) return text ? [{ kind: "text", text }] : [];
  const blocks: TurnBlock[] = [];
  let cursor = 0;
  let i = 0;
  while (i < tools.length) {
    const mark = tools[i].atChars ?? 0;
    const at = Math.min(Math.max(mark, 0), text.length);
    if (at > cursor) {
      blocks.push({ kind: "text", text: text.slice(cursor, at) });
      cursor = at;
    }
    const group: ToolRow[] = [];
    while (i < tools.length && (tools[i].atChars ?? 0) === mark) {
      group.push(tools[i]);
      i += 1;
    }
    blocks.push({ kind: "tools", tools: group });
  }
  if (cursor < text.length) blocks.push({ kind: "text", text: text.slice(cursor) });
  return blocks;
}

export function applyAcpUpdate(turn: AssistantTurn, update: AcpUpdate): AssistantTurn {
  switch (update.sessionUpdate) {
    case "agent_thought_chunk": {
      const text = (update as { content?: AcpContent }).content?.text ?? "";
      return {
        ...turn,
        reasoning: `${turn.reasoning}${text}`,
        status: turn.status === "ask" ? "ask" : turn.text ? "streaming" : "thinking",
      };
    }
    case "agent_message_chunk": {
      const text = (update as { content?: AcpContent }).content?.text ?? "";
      const needsBreak = turn.pendingBreak && turn.text.length > 0 && !/\s$/.test(turn.text) && !/^\s/.test(text);
      return {
        ...turn,
        text: `${turn.text}${needsBreak ? "\n\n" : ""}${text}`,
        pendingBreak: false,
        status: turn.status === "ask" ? "ask" : "streaming",
      };
    }
    case "tool_call":
    case "tool_call_update":
      // The catch-all AcpUpdate member defeats literal narrowing here.
      return upsertTool(turn, update as Extract<AcpUpdate, { toolCallId: string }>);
    default:
      return turn;
  }
}

export function parseRpcLine(line: string): JsonRpcLine | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    return JSON.parse(trimmed) as JsonRpcLine;
  } catch {
    return null;
  }
}

export { emptyTurn };
export type { AssistantTurn };
