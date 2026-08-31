/** Graff `--json` / `graff serve` events that the native harness renders.
 *  Mirrors `sdk/ts/remote.ts` Event, kept local so the UI does not import
 *  Node-only SDK code. Unknown types are ignored (forward compatible). */

export type GraffEvent =
  | { seq?: number; type: "text"; text: string }
  | { seq?: number; type: "reasoning"; text: string }
  | { seq?: number; type: "started"; provider: string; model: string }
  | { seq?: number; type: "model_call_started"; provider: string; model: string }
  | { seq?: number; type: "model_call_finished"; provider: string; model: string; ok: boolean; ms: number }
  | { seq?: number; type: "tool_call"; name: string; input: Record<string, unknown> }
  | { seq?: number; type: "tool_call_started"; name: string; input: Record<string, unknown> }
  | {
      seq?: number;
      type: "tool_rejected";
      name: string;
      reason: string;
      input: Record<string, unknown>;
      message: string;
    }
  | { seq?: number; type: "ask_user"; call_id: string; question: string; input: Record<string, unknown> }
  | { seq?: number; type: "tool_result"; name: string; is_error: boolean; text: string }
  | { seq?: number; type: "tool_call_finished"; name: string; is_error: boolean; ms: number }
  | { seq?: number; type: "finalizing" }
  | {
      seq?: number;
      type: "session_recap";
      text: string;
      status: "needs_input" | "completed" | "failed";
      source: string;
    }
  | {
      seq?: number;
      type: "turn";
      text: string;
      context_tokens: number;
      cost_usd: number;
      complete?: boolean;
    }
  | { seq?: number; type: "error"; message: string }
  | { seq?: number; type: string; [key: string]: unknown };

export type ToolIcon = "think" | "write" | "run" | "read";

export type ToolRow = {
  id: string;
  name: string;
  icon: ToolIcon;
  chip: string;
  status: "running" | "ok" | "error";
  detail: { text: string; tone?: "add" }[];
  path?: string;
  /** Wall-clock bracket, measured client-side — rows tick while running. */
  startedAt?: number;
  elapsedMs?: number;
};

export type DiffChip = {
  file: string;
  add: number;
  del: number;
  lines: { text: string; tone: "add" | "del" | "ctx" }[];
};

export type TodoItem = {
  id: string;
  content: string;
  status: "pending" | "in_progress" | "completed";
};

export type AskPrompt = {
  callId: string;
  question: string;
};

export type TurnStatus = "thinking" | "streaming" | "ask" | "done" | "error";

export type AssistantTurn = {
  reasoning: string;
  text: string;
  tools: ToolRow[];
  diffs: DiffChip[];
  todos: TodoItem[];
  ask?: AskPrompt;
  recap?: string;
  error?: string;
  model?: string;
  provider?: string;
  costUsd?: number;
  /** How long the model thought before its first tool/text, measured by the
   * harness while the turn streamed — kept on the turn so a remount (tab
   * switch) shows the real figure instead of re-timing from mount. */
  thoughtMs?: number;
  /** A tool bracket landed after streamed text — the next text chunk starts a
   * new paragraph instead of fusing onto the previous sentence. */
  pendingBreak?: boolean;
  status: TurnStatus;
};

export function emptyTurn(): AssistantTurn {
  return {
    reasoning: "",
    text: "",
    tools: [],
    diffs: [],
    todos: [],
    status: "thinking",
  };
}

export function iconFor(name: string): ToolIcon {
  if (name === "bash" || name === "bash_output" || name === "bash_kill") return "run";
  if (name === "write_file" || name === "edit_file") return "write";
  if (name === "read_file" || name === "codedb" || name === "webfetch" || name === "skill") return "read";
  if (name === "todo_write" || name === "todo_read") return "think";
  return "think";
}

export function chipFor(name: string, input: Record<string, unknown>): string {
  const path = typeof input.path === "string" ? input.path : undefined;
  const command = typeof input.command === "string" ? input.command : undefined;
  if (path) return path;
  if (command) return command.length > 48 ? `${command.slice(0, 47)}…` : command;
  if (typeof input.url === "string") return input.url;
  return name;
}

function toolId(name: string, input: Record<string, unknown>, tools: ToolRow[]): string {
  const hint = chipFor(name, input);
  const n = tools.filter((t) => t.name === name && t.chip === hint).length;
  return `${name}:${hint}:${n}`;
}

function upsertTool(turn: AssistantTurn, name: string, input: Record<string, unknown>): AssistantTurn {
  const chip = chipFor(name, input);
  const running = [...turn.tools]
    .reverse()
    .find((t) => t.name === name && t.status === "running" && t.chip === chip);
  if (running) return turn;
  const row: ToolRow = {
    id: toolId(name, input, turn.tools),
    name,
    icon: iconFor(name),
    chip,
    status: "running",
    detail: summarizeInput(name, input),
    path: typeof input.path === "string" ? input.path : undefined,
  };
  return { ...turn, tools: [...turn.tools, row], status: turn.status === "ask" ? "ask" : "streaming" };
}

export function summarizeInput(name: string, input: Record<string, unknown>): { text: string; tone?: "add" }[] {
  if (name === "edit_file") {
    const oldS = typeof input.old_string === "string" ? input.old_string : "";
    const newS = typeof input.new_string === "string" ? input.new_string : "";
    const lines: { text: string; tone?: "add" }[] = [];
    if (oldS) lines.push({ text: firstLine(oldS) });
    if (newS) lines.push({ text: firstLine(newS), tone: "add" });
    return lines.length ? lines : [{ text: "staged edit" }];
  }
  if (name === "write_file") {
    const content = typeof input.content === "string" ? input.content : "";
    return [{ text: content ? `${content.split("\n").length} lines` : "write", tone: "add" }];
  }
  if (name === "bash" && typeof input.command === "string") {
    return [{ text: input.command }];
  }
  try {
    const json = JSON.stringify(input);
    return [{ text: json.length > 160 ? `${json.slice(0, 159)}…` : json }];
  } catch {
    return [{ text: name }];
  }
}

export function firstLine(s: string): string {
  const line = s.split("\n")[0] ?? s;
  return line.length > 80 ? `${line.slice(0, 79)}…` : line;
}

function finishTool(turn: AssistantTurn, name: string, isError: boolean, text?: string): AssistantTurn {
  let idx = -1;
  for (let i = turn.tools.length - 1; i >= 0; i--) {
    if (turn.tools[i].name === name && turn.tools[i].status === "running") {
      idx = i;
      break;
    }
  }
  if (idx < 0) {
    if (!text) return turn;
    return {
      ...turn,
      tools: [
        ...turn.tools,
        {
          id: `${name}:result:${turn.tools.length}`,
          name,
          icon: iconFor(name),
          chip: name,
          status: isError ? "error" : "ok",
          detail: text ? [{ text: firstLine(text) }] : [],
        },
      ],
    };
  }
  const prev = turn.tools[idx];
  const detail = text
    ? [...prev.detail, { text: firstLine(text), tone: isError ? undefined : undefined }]
    : prev.detail;
  const tools = turn.tools.slice();
  tools[idx] = { ...prev, status: isError ? "error" : "ok", detail };
  const diffs = name === "edit_file" || name === "write_file" ? mergeDiff(turn.diffs, prev, text) : turn.diffs;
  return { ...turn, tools, diffs };
}

function mergeDiff(diffs: DiffChip[], tool: ToolRow, text?: string): DiffChip[] {
  const file = tool.path ?? tool.chip;
  if (!file || file === tool.name) return diffs;
  const add = tool.name === "write_file" ? 1 : countTone(tool.detail, "add");
  const del = tool.name === "edit_file" ? 1 : 0;
  const lines = (text ?? "")
    .split("\n")
    .slice(0, 8)
    .map((line) => ({
      text: line.slice(0, 80),
      tone: (line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx") as DiffChip["lines"][number]["tone"],
    }));
  const existing = diffs.findIndex((d) => d.file === file);
  const chip: DiffChip = {
    file,
    add: Math.max(add, 1),
    del,
    lines: lines.length ? lines : tool.detail.map((d) => ({ text: d.text, tone: d.tone === "add" ? "add" : "ctx" })),
  };
  if (existing < 0) return [...diffs, chip];
  const next = diffs.slice();
  next[existing] = chip;
  return next;
}

function countTone(detail: ToolRow["detail"], tone: "add"): number {
  return detail.filter((d) => d.tone === tone).length;
}

function parseTodos(input: Record<string, unknown>): TodoItem[] {
  const raw = input.todos ?? input.items ?? input.list;
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item, i) => {
    if (!item || typeof item !== "object") return [];
    const rec = item as Record<string, unknown>;
    const content = typeof rec.content === "string" ? rec.content : typeof rec.text === "string" ? rec.text : "";
    if (!content) return [];
    const status = rec.status === "completed" || rec.status === "in_progress" || rec.status === "pending"
      ? rec.status
      : "pending";
    const id = typeof rec.id === "string" ? rec.id : `todo-${i}`;
    return [{ id, content, status }];
  });
}

export function applyEvent(turn: AssistantTurn, ev: GraffEvent): AssistantTurn {
  switch (ev.type) {
    case "started":
    case "model_call_started":
      return {
        ...turn,
        provider: typeof ev.provider === "string" ? ev.provider : turn.provider,
        model: typeof ev.model === "string" ? ev.model : turn.model,
        status: turn.status === "ask" ? "ask" : "thinking",
      };
    case "reasoning":
      return {
        ...turn,
        reasoning: `${turn.reasoning}${typeof ev.text === "string" ? ev.text : ""}`,
        status: turn.status === "ask" ? "ask" : "thinking",
      };
    case "text":
      return {
        ...turn,
        text: `${turn.text}${typeof ev.text === "string" ? ev.text : ""}`,
        status: turn.status === "ask" ? "ask" : "streaming",
      };
    case "tool_call":
    case "tool_call_started": {
      const name = typeof ev.name === "string" ? ev.name : "tool";
      const input = ev.input && typeof ev.input === "object" ? (ev.input as Record<string, unknown>) : {};
      const next = upsertTool(turn, name, input);
      const todos = name === "todo_write" ? parseTodos(input) : next.todos;
      return todos.length ? { ...next, todos } : next;
    }
    case "tool_result":
      return finishTool(
        turn,
        typeof ev.name === "string" ? ev.name : "tool",
        Boolean(ev.is_error),
        typeof ev.text === "string" ? ev.text : undefined,
      );
    case "tool_call_finished":
      return finishTool(turn, typeof ev.name === "string" ? ev.name : "tool", Boolean(ev.is_error));
    case "tool_rejected":
      return {
        ...turn,
        tools: [
          ...turn.tools,
          {
            id: `rejected:${String(ev.name)}:${turn.tools.length}`,
            name: String(ev.name ?? "tool"),
            icon: iconFor(String(ev.name ?? "")),
            chip: String(ev.reason ?? "rejected"),
            status: "error",
            detail: [{ text: String(ev.message ?? "rejected") }],
          },
        ],
      };
    case "ask_user":
      return {
        ...turn,
        ask: {
          callId: String(ev.call_id ?? ""),
          question: String(ev.question ?? "The agent needs a decision."),
        },
        status: "ask",
      };
    case "session_recap":
      return { ...turn, recap: typeof ev.text === "string" ? ev.text : turn.recap };
    case "turn":
      return {
        ...turn,
        text: turn.text || (typeof ev.text === "string" ? ev.text : turn.text),
        costUsd: typeof ev.cost_usd === "number" ? ev.cost_usd : turn.costUsd,
        ask: undefined,
        status: "done",
      };
    case "error":
      return {
        ...turn,
        error: typeof ev.message === "string" ? ev.message : "error",
        status: "error",
      };
    case "finalizing":
      return { ...turn, status: turn.status === "ask" ? "ask" : "streaming" };
    default:
      return turn;
  }
}

export function parseEventLine(line: string): GraffEvent | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const ev = JSON.parse(trimmed) as GraffEvent;
    return ev && typeof ev.type === "string" ? ev : null;
  } catch {
    return null;
  }
}
