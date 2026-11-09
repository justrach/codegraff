"""Serverless / in-memory agent runtime templates for TypeScript and Python SDKs.

Provides a zero-binary, edge-safe (`fetch` + Web Streams in TS; stdlib `urllib`
in Python) agent loop (`ServerlessHarness`) with pluggable workspace operations
(`InMemoryWorkspace`, `WorkspaceOperations`), coding tools (`createCodingTools`,
`createReadOnlyTools`, `defineTool`), tool lifecycle hooks (`beforeToolCall`,
`afterToolCall`, `transformContext`), mid-turn `steer` and `followUp` queues,
and serializable in-memory session snapshots (`exportState` / `importState`)
that emit the exact same `Event` union and `AskResult` shape as `Harness` and
`RemoteHarness`.
"""

SERVERLESS_TS = """
// ── Serverless / In-Memory Agent Runtime (Edge & Worker safe) ─────────────

export interface WorkspaceOperations {
  readFile(path: string): Promise<string> | string;
  writeFile(path: string, content: string): Promise<void> | void;
  deleteFile?(path: string): Promise<void> | void;
  listFiles?(prefix?: string): Promise<string[]> | string[];
  exec?(
    command: string,
    opts?: { cwd?: string; timeoutMs?: number; signal?: AbortSignal },
  ): Promise<{ exitCode: number; output: string }> | { exitCode: number; output: string };
}

function normVirtualPath(p: string): string {
  return p.replace(/\\\\/g, "/").replace(/^(\\.\\/|\\/)+/, "").replace(/\\/+$/, "");
}

/** In-memory virtual workspace for serverless / edge / browser agent runs.
 *  Implements `WorkspaceOperations` with snapshot, restore, and diff helpers. */
export class InMemoryWorkspace implements WorkspaceOperations {
  private files = new Map<string, string>();
  exec?: WorkspaceOperations["exec"];

  constructor(
    initialFiles: Record<string, string> = {},
    opts?: { exec?: WorkspaceOperations["exec"] },
  ) {
    for (const [k, v] of Object.entries(initialFiles)) {
      this.files.set(normVirtualPath(k), v);
    }
    this.exec = opts?.exec;
  }

  readFile(path: string): string {
    const key = normVirtualPath(path);
    const val = this.files.get(key);
    if (val === undefined) throw new Error(`ENOENT: file not found: ${path}`);
    return val;
  }

  writeFile(path: string, content: string): void {
    this.files.set(normVirtualPath(path), content);
  }

  deleteFile(path: string): void {
    const key = normVirtualPath(path);
    if (!this.files.delete(key)) throw new Error(`ENOENT: file not found: ${path}`);
  }

  exists(path: string): boolean {
    return this.files.has(normVirtualPath(path));
  }

  listFiles(prefix = ""): string[] {
    const p = normVirtualPath(prefix);
    const out: string[] = [];
    for (const k of this.files.keys()) {
      if (!p || k === p || k.startsWith(p + "/")) out.push(k);
    }
    return out.sort();
  }

  snapshot(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const k of [...this.files.keys()].sort()) out[k] = this.files.get(k)!;
    return out;
  }

  restore(files: Record<string, string>): void {
    this.files.clear();
    for (const [k, v] of Object.entries(files)) this.files.set(normVirtualPath(k), v);
  }

  diff(baseline: Record<string, string> = {}): Array<{ path: string; status: "added" | "modified" | "deleted" }> {
    const base = new Map<string, string>();
    for (const [k, v] of Object.entries(baseline)) base.set(normVirtualPath(k), v);
    const keys = new Set<string>([...base.keys(), ...this.files.keys()]);
    const changes: Array<{ path: string; status: "added" | "modified" | "deleted" }> = [];
    for (const k of [...keys].sort()) {
      const b = base.get(k);
      const a = this.files.get(k);
      if (b === undefined && a !== undefined) changes.push({ path: k, status: "added" });
      else if (b !== undefined && a === undefined) changes.push({ path: k, status: "deleted" });
      else if (b !== a) changes.push({ path: k, status: "modified" });
    }
    return changes;
  }
}

export interface ServerlessToolContext {
  callId: string;
  signal?: AbortSignal;
  workspace: WorkspaceOperations;
}

export type ServerlessToolOutput = string | { output: string; isError?: boolean };

export interface ServerlessTool<TInput = Record<string, unknown>> {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  execute: (
    input: TInput,
    ctx: ServerlessToolContext,
  ) => Promise<ServerlessToolOutput> | ServerlessToolOutput;
}

/** Type-safe helper for defining a custom tool in `ServerlessHarness`. */
export function defineTool<TInput = Record<string, unknown>>(
  tool: ServerlessTool<TInput>,
): ServerlessTool<TInput> {
  return tool;
}

/** Create read-only coding tools (`read_file`, `list_dir`, `grep`) backed by
 *  any `WorkspaceOperations` (such as `InMemoryWorkspace`). */
export function createReadOnlyTools(workspace: WorkspaceOperations): ServerlessTool[] {
  return [
    defineTool({
      name: "read_file",
      description: "Read the contents of a file in the workspace with optional 1-based line bounds.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "File path to read." },
          start_line: { type: "integer", description: "1-based start line (inclusive)." },
          end_line: { type: "integer", description: "1-based end line (inclusive)." },
        },
        required: ["path"],
      },
      async execute(input) {
        const path = String(input.path ?? "");
        const content = await workspace.readFile(path);
        const lines = content.split("\\n");
        const start = Math.max(1, Number(input.start_line ?? 1));
        const end = Math.min(lines.length, Number(input.end_line ?? lines.length));
        const slice = lines.slice(start - 1, end);
        return slice.map((l, idx) => `${start + idx}: ${l}`).join("\\n");
      },
    }),
    defineTool({
      name: "list_dir",
      description: "List files in the workspace under an optional directory prefix.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "Optional directory prefix." },
        },
      },
      async execute(input) {
        if (!workspace.listFiles) return { output: "list_dir is not supported by this workspace", isError: true };
        const files = await workspace.listFiles(String(input.path ?? ""));
        return files.length ? files.join("\\n") : "(empty)";
      },
    }),
    defineTool({
      name: "grep",
      description: "Search files in the workspace for a regex or substring pattern.",
      parameters: {
        type: "object",
        properties: {
          pattern: { type: "string", description: "Regex or substring to search for." },
          path: { type: "string", description: "Optional directory or file prefix." },
        },
        required: ["pattern"],
      },
      async execute(input) {
        if (!workspace.listFiles) return { output: "grep requires workspace.listFiles", isError: true };
        const pattern = String(input.pattern ?? "");
        let rx: RegExp;
        try { rx = new RegExp(pattern); } catch { rx = new RegExp(pattern.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&")); }
        const files = await workspace.listFiles(String(input.path ?? ""));
        const matches: string[] = [];
        for (const f of files) {
          const text = await workspace.readFile(f);
          const lines = text.split("\\n");
          for (let i = 0; i < lines.length; i++) {
            if (rx.test(lines[i])) {
              matches.push(`${f}:${i + 1}:${lines[i]}`);
              if (matches.length >= 200) return matches.join("\\n") + "\\n... (truncated at 200 matches)";
            }
          }
        }
        return matches.length ? matches.join("\\n") : "No matches found.";
      },
    }),
  ];
}

/** Create full coding tools (`read_file`, `write_file`, `edit_file`, `list_dir`,
 *  `grep`, and `bash` when `workspace.exec` is present) backed by any
 *  `WorkspaceOperations`. */
export function createCodingTools(
  workspace: WorkspaceOperations,
  opts?: { includeBash?: boolean },
): ServerlessTool[] {
  const tools: ServerlessTool[] = [
    ...createReadOnlyTools(workspace),
    defineTool({
      name: "write_file",
      description: "Create or overwrite a file in the workspace.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "File path to write." },
          content: { type: "string", description: "Full file content." },
        },
        required: ["path", "content"],
      },
      async execute(input) {
        const path = String(input.path ?? "");
        const content = String(input.content ?? "");
        await workspace.writeFile(path, content);
        return `Wrote ${content.length} bytes to ${path}`;
      },
    }),
    defineTool({
      name: "edit_file",
      description: "Replace an exact string in a file with a new string.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "File path to edit." },
          old_str: { type: "string", description: "Exact existing text to replace." },
          new_str: { type: "string", description: "Replacement text." },
          replace_all: { type: "boolean", description: "Replace all occurrences instead of requiring a unique match." },
        },
        required: ["path", "old_str", "new_str"],
      },
      async execute(input) {
        const path = String(input.path ?? "");
        const oldStr = String(input.old_str ?? "");
        const newStr = String(input.new_str ?? "");
        const replaceAll = Boolean(input.replace_all);
        if (!oldStr) return { output: "old_str must not be empty", isError: true };
        const content = await workspace.readFile(path);
        const parts = content.split(oldStr);
        const count = parts.length - 1;
        if (count === 0) return { output: `old_str not found in ${path}`, isError: true };
        if (count > 1 && !replaceAll) {
          return { output: `old_str appears ${count} times in ${path}; pass replace_all: true or provide more context`, isError: true };
        }
        const updated = replaceAll ? parts.join(newStr) : content.replace(oldStr, () => newStr);
        await workspace.writeFile(path, updated);
        return `Updated ${path} (${replaceAll ? count : 1} replacement${replaceAll && count > 1 ? "s" : ""})`;
      },
    }),
  ];
  if (opts?.includeBash ?? Boolean(workspace.exec)) {
    tools.push(
      defineTool({
        name: "bash",
        description: "Execute a shell command in the workspace.",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string", description: "Command to run." },
            cwd: { type: "string", description: "Optional working directory." },
            timeout_ms: { type: "integer", description: "Optional timeout in milliseconds." },
          },
          required: ["command"],
        },
        async execute(input, ctx) {
          if (!workspace.exec) return { output: "bash execution is not configured on this workspace", isError: true };
          const res = await workspace.exec(String(input.command ?? ""), {
            cwd: typeof input.cwd === "string" ? input.cwd : undefined,
            timeoutMs: typeof input.timeout_ms === "number" ? input.timeout_ms : undefined,
            signal: ctx.signal,
          });
          return { output: res.output, isError: res.exitCode !== 0 };
        },
      }),
    );
  }
  return tools;
}

export interface ServerlessToolCall {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface ServerlessMessage {
  role: "user" | "assistant" | "tool";
  content: string;
  images?: ImageInput[];
  reasoning?: string;
  toolCalls?: ServerlessToolCall[];
  toolCallId?: string;
  toolName?: string;
  isError?: boolean;
}

export interface ServerlessModelTurn {
  text?: string;
  reasoning?: string;
  toolCalls?: ServerlessToolCall[];
  inputTokens?: number;
  uncachedInputTokens?: number;
  cacheReadTokens?: number;
  outputTokens?: number;
  costUsd?: number;
  onTextDelta?: (delta: string) => void;
}

export interface ServerlessStreamRequest {
  provider: string;
  model: string;
  effort: EffortLevel;
  systemPrompt: string;
  messages: ServerlessMessage[];
  tools: Array<{ name: string; description: string; parameters: Record<string, unknown> }>;
  signal?: AbortSignal;
  onTextDelta?: (delta: string) => void;
  onReasoningDelta?: (delta: string) => void;
}

export type ServerlessStreamFn = (req: ServerlessStreamRequest) => Promise<ServerlessModelTurn>;

export interface BeforeToolCallContext {
  callId: string;
  name: string;
  input: Record<string, unknown>;
  step: number;
  messages: readonly ServerlessMessage[];
}

export interface BeforeToolCallResult {
  block?: boolean;
  reason?: string;
  input?: Record<string, unknown>;
}

export interface AfterToolCallContext {
  callId: string;
  name: string;
  input: Record<string, unknown>;
  output: string;
  isError: boolean;
  step: number;
}

export interface AfterToolCallResult {
  output?: string;
  isError?: boolean;
}

export interface MegaharnessStats {
  wavesLaunched: number;
  opsExecuted: number;
  parallelOpsFused: number;
  llmRoundTripsSaved: number;
}

export interface ServerlessSessionSnapshot {
  version: 1;
  sessionId: string;
  provider: string;
  model: string;
  effort: EffortLevel;
  systemPrompt: string;
  seq: number;
  messages: ServerlessMessage[];
  files?: Record<string, string>;
}

export interface ServerlessOptions {
  /** Provider id ("codegraff", "openai", "anthropic", "deepseek", "xai", "openrouter", ...). */
  provider?: ProviderId | string;
  /** Model name (default "gpt-5.5"). */
  model?: ModelName | string;
  /** API key or bearer token for direct provider calls. */
  apiKey?: string;
  /** Alias for apiKey. */
  token?: string;
  /** Custom provider endpoint URL (auto-selected from `provider` when omitted). */
  endpoint?: string;
  /** Custom fetch implementation. */
  fetch?: typeof fetch;
  /** Pluggable model stream/completion function (for custom transports or tests). */
  streamFn?: ServerlessStreamFn;
  /** Initial reasoning effort (default "medium"). */
  effort?: EffortLevel;
  /** System prompt (default built-in coding assistant prompt). */
  systemPrompt?: string;
  /** Extra instructions appended to the system prompt. */
  appendSystemPrompt?: string;
  /** Virtual file map or custom `WorkspaceOperations`. Defaults to an empty `InMemoryWorkspace`. */
  workspace?: WorkspaceOperations | Record<string, string>;
  /** Attach built-in coding tools (`true` | `"readonly"` | `false`). Default `true`. */
  codingTools?: boolean | "readonly";
  /** Additional custom tools (created via `defineTool`). */
  tools?: ServerlessTool[];
  /** Execute multiple tool calls sequentially, all in parallel, or in Megaharness dependency waves. */
  toolExecution?: "sequential" | "parallel" | "wave";
  /** Per-turn tool-call ceiling (default 32). */
  maxToolCalls?: number;
  /** Session-wide model-call ceiling (default 64). */
  maxModelCalls?: number;
  /** Reject duplicate tool name + normalized JSON input within the same turn. */
  dedupeToolCalls?: boolean;
  /** Guardrail/inspection hook before each tool execution. */
  beforeToolCall?: (
    ctx: BeforeToolCallContext,
  ) => Promise<BeforeToolCallResult | void> | BeforeToolCallResult | void;
  /** Post-processing/redaction hook after each tool execution. */
  afterToolCall?: (
    ctx: AfterToolCallContext,
  ) => Promise<AfterToolCallResult | void> | AfterToolCallResult | void;
  /** Transform or prune message history before each model request. */
  transformContext?: (
    messages: ServerlessMessage[],
  ) => Promise<ServerlessMessage[]> | ServerlessMessage[];
  /** Restore from a previously exported `ServerlessSessionSnapshot`. */
  session?: ServerlessSessionSnapshot;
}

const DEFAULT_SERVERLESS_SYSTEM =
  "You are Graff, an autonomous coding agent. Use the provided tools to inspect, edit, and verify files before answering.";

const PROVIDER_ENDPOINTS: Readonly<Record<string, string>> = {
  codegraff: "https://codegraff.com/api/v1/chat/completions",
  openai: "https://api.openai.com/v1/chat/completions",
  codex: "https://api.openai.com/v1/chat/completions",
  anthropic: "https://api.anthropic.com/v1/messages",
  deepseek: "https://api.deepseek.com/v1/chat/completions",
  xai: "https://api.x.ai/v1/chat/completions",
  moonshot: "https://api.moonshot.ai/v1/chat/completions",
  kimi: "https://api.kimi.com/coding/v1/chat/completions",
  zai: "https://api.z.ai/api/paas/v4/chat/completions",
  minimax: "https://api.minimax.io/v1/chat/completions",
  openrouter: "https://openrouter.ai/api/v1/chat/completions",
};

function isWorkspaceOps(v: unknown): v is WorkspaceOperations {
  return Boolean(v && typeof v === "object" && typeof (v as WorkspaceOperations).readFile === "function");
}

function stableJson(v: unknown): string {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(stableJson).join(",") + "]";
  const entries = Object.entries(v as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b));
  return "{" + entries.map(([k, val]) => `${JSON.stringify(k)}:${stableJson(val)}`).join(",") + "}";
}

/** Zero-binary, edge-safe agent session that runs in-memory on Cloudflare
 *  Workers, Vercel Edge, Deno, Bun, browsers, and Node >= 18.
 *  Implements the same `chat()` / `ask()` / `askResult()` / `review()` /
 *  `setModel()` / `setEffort()` / `setSystemPrompt()` / `compact()` surface and
 *  streams the same `Event` union as `Harness` and `RemoteHarness`. */
export class ServerlessHarness {
  readonly workspace: WorkspaceOperations;
  readonly memoryWorkspace?: InMemoryWorkspace;
  private providerId: string;
  private modelName: string;
  private effortLevel: EffortLevel;
  private baseSystemPrompt: string;
  private appendedSystemPrompt = "";
  private apiKey?: string;
  private endpoint?: string;
  private fetcher: typeof fetch;
  private streamFn?: ServerlessStreamFn;
  private toolMap = new Map<string, ServerlessTool>();
  private toolExecMode: "sequential" | "parallel" | "wave";
  private mhStats: MegaharnessStats = {
    wavesLaunched: 0,
    opsExecuted: 0,
    parallelOpsFused: 0,
    llmRoundTripsSaved: 0,
  };
  private maxToolCalls: number;
  private maxModelCalls: number;
  private totalModelCalls = 0;
  private dedupeToolCalls: boolean;
  private beforeToolCall?: ServerlessOptions["beforeToolCall"];
  private afterToolCall?: ServerlessOptions["afterToolCall"];
  private transformContext?: ServerlessOptions["transformContext"];
  private messages: ServerlessMessage[] = [];
  private steerQueue: string[] = [];
  private followUpQueue: string[] = [];
  private listeners = new Set<(ev: Event) => void>();
  private opTail: Promise<void> = Promise.resolve();
  private activeAbort?: AbortController;
  private closed = false;
  readonly sessionId: string;
  lastSeq = 0;

  constructor(opts: ServerlessOptions = {}) {
    if (opts.workspace === undefined) {
      this.memoryWorkspace = new InMemoryWorkspace();
      this.workspace = this.memoryWorkspace;
    } else if (isWorkspaceOps(opts.workspace)) {
      this.workspace = opts.workspace;
      if (opts.workspace instanceof InMemoryWorkspace) this.memoryWorkspace = opts.workspace;
    } else {
      this.memoryWorkspace = new InMemoryWorkspace(opts.workspace);
      this.workspace = this.memoryWorkspace;
    }

    const snap = opts.session;
    if (snap?.files && this.memoryWorkspace) this.memoryWorkspace.restore(snap.files);
    this.sessionId = snap?.sessionId ?? "serverless-" + Math.random().toString(36).slice(2, 10);
    const rawModel = snap?.model ?? opts.model ?? "gpt-5.5";
    const slash = rawModel.indexOf("/");
    this.providerId = snap?.provider ?? opts.provider ?? (slash > 0 ? rawModel.slice(0, slash) : "codegraff");
    this.modelName = slash > 0 && !opts.provider && !snap?.provider ? rawModel.slice(slash + 1) : rawModel;
    this.effortLevel = snap?.effort ?? opts.effort ?? "medium";
    this.baseSystemPrompt = snap?.systemPrompt ?? opts.systemPrompt ?? DEFAULT_SERVERLESS_SYSTEM;
    this.appendedSystemPrompt = opts.appendSystemPrompt ?? "";
    this.lastSeq = snap?.seq ?? 0;
    if (snap?.messages) this.messages = JSON.parse(JSON.stringify(snap.messages)) as ServerlessMessage[];

    this.apiKey = opts.apiKey ?? opts.token;
    this.endpoint = opts.endpoint;
    this.fetcher = opts.fetch ?? globalThis.fetch.bind(globalThis);
    this.streamFn = opts.streamFn;
    this.toolExecMode = opts.toolExecution ?? "sequential";
    this.maxToolCalls = opts.maxToolCalls ?? 32;
    this.maxModelCalls = opts.maxModelCalls ?? 64;
    this.dedupeToolCalls = opts.dedupeToolCalls ?? false;
    this.beforeToolCall = opts.beforeToolCall;
    this.afterToolCall = opts.afterToolCall;
    this.transformContext = opts.transformContext;

    const codingMode = opts.codingTools ?? true;
    if (codingMode === "readonly") {
      for (const t of createReadOnlyTools(this.workspace)) this.toolMap.set(t.name, t);
    } else if (codingMode) {
      for (const t of createCodingTools(this.workspace)) this.toolMap.set(t.name, t);
    }
    for (const t of opts.tools ?? []) this.toolMap.set(t.name, t);
  }

  static init(opts: ServerlessOptions = {}): ServerlessHarness {
    return new ServerlessHarness(opts);
  }

  static fromState(snapshot: ServerlessSessionSnapshot, opts: Omit<ServerlessOptions, "session"> = {}): ServerlessHarness {
    return new ServerlessHarness({ ...opts, session: snapshot });
  }

  /** Subscribe to every emitted `Event` across turns and controls. */
  subscribe(listener: (ev: Event) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  /** Inject a user steering message before the next model step in an active turn. */
  steer(text: string): void {
    if (text.trim()) this.steerQueue.push(text);
  }

  /** Queue a follow-up user message to run automatically if the current turn would otherwise stop. */
  followUp(text: string): void {
    if (text.trim()) this.followUpQueue.push(text);
  }

  /** Return a read-only view of the current in-memory message history. */
  getMessages(): readonly ServerlessMessage[] {
    return this.messages;
  }

  /** Return Megaharness fused execution telemetry for this session (ADR 0322). */
  getMegaharnessStats(): MegaharnessStats {
    return { ...this.mhStats };
  }

  /** Export a serializable snapshot of conversation state and `InMemoryWorkspace` files. */
  exportState(): ServerlessSessionSnapshot {
    return {
      version: 1,
      sessionId: this.sessionId,
      provider: this.providerId,
      model: this.modelName,
      effort: this.effortLevel,
      systemPrompt: this.effectiveSystemPrompt(),
      seq: this.lastSeq,
      messages: JSON.parse(JSON.stringify(this.messages)) as ServerlessMessage[],
      ...(this.memoryWorkspace ? { files: this.memoryWorkspace.snapshot() } : {}),
    };
  }

  /** Restore conversation state (and `InMemoryWorkspace` files if present) from a snapshot. */
  importState(snapshot: ServerlessSessionSnapshot): void {
    this.providerId = snapshot.provider;
    this.modelName = snapshot.model;
    this.effortLevel = snapshot.effort;
    this.baseSystemPrompt = snapshot.systemPrompt;
    this.appendedSystemPrompt = "";
    this.lastSeq = snapshot.seq;
    this.messages = JSON.parse(JSON.stringify(snapshot.messages)) as ServerlessMessage[];
    if (snapshot.files && this.memoryWorkspace) this.memoryWorkspace.restore(snapshot.files);
  }

  private effectiveSystemPrompt(): string {
    return this.appendedSystemPrompt
      ? `${this.baseSystemPrompt}\\n\\n${this.appendedSystemPrompt}`
      : this.baseSystemPrompt;
  }

  private emit<T extends Record<string, unknown>>(ev: T): Event {
    const stamped = { seq: ++this.lastSeq, ...ev } as unknown as Event;
    for (const fn of this.listeners) {
      try { fn(stamped); } catch { /* listener errors do not break the stream */ }
    }
    return stamped;
  }

  private acquireOp(): Promise<() => void> {
    if (this.closed) return Promise.reject(new Error("harness is closed"));
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const acquired = this.opTail.then(() => release);
    this.opTail = this.opTail.then(() => gate);
    return acquired;
  }

  private async runOp<T>(op: () => Promise<T>): Promise<T> {
    const release = await this.acquireOp();
    try { return await op(); } finally { release(); }
  }

  private async callProvider(
    req: ServerlessStreamRequest,
  ): Promise<ServerlessModelTurn> {
    if (this.streamFn) return await this.streamFn(req);
    const url = this.endpoint ?? PROVIDER_ENDPOINTS[req.provider] ?? PROVIDER_ENDPOINTS.codegraff;
    if (req.provider === "anthropic") {
      const headers: Record<string, string> = {
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
      };
      if (this.apiKey) headers["x-api-key"] = this.apiKey;
      const anthMessages: Array<Record<string, unknown>> = [];
      for (const m of req.messages) {
        if (m.role === "user") {
          const content: Array<Record<string, unknown>> = [{ type: "text", text: m.content }];
          for (const img of m.images ?? []) {
            if (img.type === "image_base64") {
              content.push({ type: "image", source: { type: "base64", media_type: img.mediaType, data: img.data } });
            } else {
              content.push({ type: "image", source: { type: "url", url: img.url } });
            }
          }
          anthMessages.push({ role: "user", content });
        } else if (m.role === "assistant") {
          const content: Array<Record<string, unknown>> = [];
          if (m.content) content.push({ type: "text", text: m.content });
          for (const tc of m.toolCalls ?? []) {
            content.push({ type: "tool_use", id: tc.id, name: tc.name, input: tc.input });
          }
          anthMessages.push({ role: "assistant", content });
        } else if (m.role === "tool") {
          anthMessages.push({
            role: "user",
            content: [{ type: "tool_result", tool_use_id: m.toolCallId ?? "call", content: m.content, is_error: Boolean(m.isError) }],
          });
        }
      }
      const res = await this.fetcher(url, {
        method: "POST",
        headers,
        signal: req.signal,
        body: JSON.stringify({
          model: req.model,
          max_tokens: 8192,
          system: req.systemPrompt,
          messages: anthMessages,
          ...(req.tools.length
            ? { tools: req.tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.parameters })) }
            : {}),
        }),
      });
      if (!res.ok) throw new Error(`Anthropic HTTP ${res.status}: ${(await res.text().catch(() => "")).slice(0, 256)}`);
      const data = (await res.json()) as Record<string, unknown>;
      const blocks = Array.isArray(data.content) ? (data.content as Array<Record<string, unknown>>) : [];
      let text = "";
      const toolCalls: ServerlessToolCall[] = [];
      for (const b of blocks) {
        if (b.type === "text" && typeof b.text === "string") {
          text += b.text;
          req.onTextDelta?.(b.text);
        } else if (b.type === "tool_use" && typeof b.name === "string") {
          toolCalls.push({
            id: typeof b.id === "string" ? b.id : `call_${toolCalls.length + 1}`,
            name: b.name,
            input: (b.input && typeof b.input === "object" ? b.input : {}) as Record<string, unknown>,
          });
        }
      }
      const usage = (data.usage ?? {}) as Record<string, number>;
      return {
        text,
        toolCalls,
        inputTokens: usage.input_tokens ?? 0,
        uncachedInputTokens: usage.input_tokens ?? 0,
        cacheReadTokens: usage.cache_read_input_tokens ?? 0,
        outputTokens: usage.output_tokens ?? 0,
      };
    }

    // OpenAI / Codegraff Gateway compatible chat completions
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (this.apiKey) headers.authorization = `Bearer ${this.apiKey}`;
    const oaiMessages: Array<Record<string, unknown>> = [
      { role: "system", content: req.systemPrompt },
    ];
    for (const m of req.messages) {
      if (m.role === "user") {
        if (m.images?.length) {
          const parts: Array<Record<string, unknown>> = [{ type: "text", text: m.content }];
          for (const img of m.images) {
            parts.push({
              type: "image_url",
              image_url: { url: img.type === "image_url" ? img.url : `data:${img.mediaType};base64,${img.data}` },
            });
          }
          oaiMessages.push({ role: "user", content: parts });
        } else {
          oaiMessages.push({ role: "user", content: m.content });
        }
      } else if (m.role === "assistant") {
        const msg: Record<string, unknown> = { role: "assistant", content: m.content || null };
        if (m.toolCalls?.length) {
          msg.tool_calls = m.toolCalls.map((tc) => ({
            id: tc.id,
            type: "function",
            function: { name: tc.name, arguments: JSON.stringify(tc.input) },
          }));
        }
        oaiMessages.push(msg);
      } else if (m.role === "tool") {
        oaiMessages.push({
          role: "tool",
          tool_call_id: m.toolCallId ?? "call",
          content: m.content,
        });
      }
    }
    const res = await this.fetcher(url, {
      method: "POST",
      headers,
      signal: req.signal,
      body: JSON.stringify({
        model: req.model,
        messages: oaiMessages,
        ...(req.tools.length
          ? {
              tools: req.tools.map((t) => ({
                type: "function",
                function: { name: t.name, description: t.description, parameters: t.parameters },
              })),
            }
          : {}),
      }),
    });
    if (!res.ok) throw new Error(`Provider HTTP ${res.status}: ${(await res.text().catch(() => "")).slice(0, 256)}`);
    const data = (await res.json()) as Record<string, unknown>;
    const choices = Array.isArray(data.choices) ? (data.choices as Array<Record<string, unknown>>) : [];
    const msg = ((choices[0]?.message ?? {}) as Record<string, unknown>);
    const text = typeof msg.content === "string" ? msg.content : "";
    const reasoning = typeof msg.reasoning_content === "string" ? msg.reasoning_content : undefined;
    if (reasoning) req.onReasoningDelta?.(reasoning);
    if (text) req.onTextDelta?.(text);
    const rawCalls = Array.isArray(msg.tool_calls) ? (msg.tool_calls as Array<Record<string, unknown>>) : [];
    const toolCalls: ServerlessToolCall[] = rawCalls.map((rc, idx) => {
      const fn = (rc.function ?? {}) as Record<string, unknown>;
      let parsed: Record<string, unknown> = {};
      if (typeof fn.arguments === "string" && fn.arguments.trim()) {
        try { parsed = JSON.parse(fn.arguments) as Record<string, unknown>; } catch { parsed = {}; }
      } else if (fn.arguments && typeof fn.arguments === "object") {
        parsed = fn.arguments as Record<string, unknown>;
      }
      return {
        id: typeof rc.id === "string" ? rc.id : `call_${idx + 1}`,
        name: String(fn.name ?? ""),
        input: parsed,
      };
    });
    const usage = (data.usage ?? {}) as Record<string, unknown>;
    const promptDetails = (usage.prompt_tokens_details ?? {}) as Record<string, number>;
    const inputTokens = Number(usage.prompt_tokens ?? usage.input_tokens ?? 0);
    const cacheReadTokens = Number(promptDetails.cached_tokens ?? usage.cache_read_input_tokens ?? 0);
    return {
      text,
      reasoning,
      toolCalls,
      inputTokens,
      uncachedInputTokens: Math.max(0, inputTokens - cacheReadTokens),
      cacheReadTokens,
      outputTokens: Number(usage.completion_tokens ?? usage.output_tokens ?? 0),
    };
  }

  async *chat(input: string | ChatOptions): AsyncGenerator<Event> {
    const prompt = typeof input === "string" ? input : input.prompt;
    const isReview = typeof input !== "string" && Boolean(input.review);
    const images = typeof input === "string" ? undefined : input.images;
    const callerSignal = typeof input === "string" ? undefined : input.signal;
    callerSignal?.throwIfAborted();

    const release = await this.acquireOp();
    const savedReviewMessages = isReview
      ? (JSON.parse(JSON.stringify(this.messages)) as ServerlessMessage[])
      : undefined;
    const turnController = new AbortController();
    this.activeAbort = turnController;
    const onCallerAbort = () => turnController.abort();
    callerSignal?.addEventListener("abort", onCallerAbort, { once: true });

    try {
      yield this.emit({ type: "started", provider: this.providerId, model: this.modelName });
      this.messages.push({ role: "user", content: prompt, ...(images?.length ? { images } : {}) });

      let toolCallsThisTurn = 0;
      let apiCallsThisTurn = 0;
      let inputTokens = 0;
      let uncachedInputTokens = 0;
      let cacheReadTokens = 0;
      let outputTokens = 0;
      let costUsd = 0;
      let finalText = "";
      const seenToolKeys = new Set<string>();

      const activeTools = isReview
        ? createReadOnlyTools(this.workspace)
        : [...this.toolMap.values()];
      const activeToolMap = new Map(activeTools.map((t) => [t.name, t]));
      const toolSchemas = activeTools.map((t) => ({
        name: t.name,
        description: t.description,
        parameters: t.parameters,
      }));

      while (true) {
        if (turnController.signal.aborted) {
          yield this.emit({ type: "error", message: "turn cancelled" });
          return;
        }
        // Drain any soft steering messages injected mid-turn.
        while (this.steerQueue.length > 0) {
          const steerText = this.steerQueue.shift()!;
          this.messages.push({ role: "user", content: steerText });
        }
        if (this.totalModelCalls >= this.maxModelCalls) {
          yield this.emit({ type: "error", message: `max_model_calls (${this.maxModelCalls}) exceeded` });
          return;
        }

        const contextMessages = this.transformContext
          ? await this.transformContext([...this.messages])
          : [...this.messages];

        const deltas: string[] = [];
        const reasoningDeltas: string[] = [];
        const startedMs = Date.now();
        yield this.emit({ type: "model_call_started", provider: this.providerId, model: this.modelName });

        let turnResp: ServerlessModelTurn;
        try {
          this.totalModelCalls += 1;
          apiCallsThisTurn += 1;
          turnResp = await this.callProvider({
            provider: this.providerId,
            model: this.modelName,
            effort: this.effortLevel,
            systemPrompt: isReview
              ? `${this.effectiveSystemPrompt()}\\n\\n[review mode: read-only inspection]`
              : this.effectiveSystemPrompt(),
            messages: contextMessages,
            tools: toolSchemas,
            signal: turnController.signal,
            onTextDelta: (d) => { if (d) deltas.push(d); },
            onReasoningDelta: (d) => { if (d) reasoningDeltas.push(d); },
          });
        } catch (err) {
          yield this.emit({
            type: "model_call_finished",
            provider: this.providerId,
            model: this.modelName,
            ok: false,
            ms: Math.max(0, Date.now() - startedMs),
          });
          const msg = turnController.signal.aborted
            ? "turn cancelled"
            : err instanceof Error ? err.message : String(err);
          yield this.emit({ type: "error", message: msg });
          return;
        }

        yield this.emit({
          type: "model_call_finished",
          provider: this.providerId,
          model: this.modelName,
          ok: true,
          ms: Math.max(0, Date.now() - startedMs),
        });

        inputTokens += turnResp.inputTokens ?? 0;
        uncachedInputTokens += turnResp.uncachedInputTokens ?? turnResp.inputTokens ?? 0;
        cacheReadTokens += turnResp.cacheReadTokens ?? 0;
        outputTokens += turnResp.outputTokens ?? 0;
        costUsd += turnResp.costUsd ?? 0;

        if (reasoningDeltas.length > 0) {
          for (const rd of reasoningDeltas) yield this.emit({ type: "reasoning", text: rd });
        } else if (turnResp.reasoning) {
          yield this.emit({ type: "reasoning", text: turnResp.reasoning });
        }

        const stepText = turnResp.text ?? deltas.join("");
        if (deltas.length > 0) {
          for (const td of deltas) yield this.emit({ type: "text", text: td });
        } else if (stepText) {
          yield this.emit({ type: "text", text: stepText });
        }
        if (stepText) finalText = stepText;

        const calls = turnResp.toolCalls ?? [];
        this.messages.push({
          role: "assistant",
          content: stepText,
          ...(turnResp.reasoning ? { reasoning: turnResp.reasoning } : {}),
          ...(calls.length ? { toolCalls: calls } : {}),
        });

        if (calls.length === 0) {
          // If a follow-up message is queued, continue into it before finishing the turn.
          if (this.followUpQueue.length > 0) {
            const nextPrompt = this.followUpQueue.shift()!;
            this.messages.push({ role: "user", content: nextPrompt });
            continue;
          }
          break;
        }

        const prepared: Array<{
          call: ServerlessToolCall;
          tool?: ServerlessTool;
          rejected?: { reason: string; message: string };
        }> = [];

        for (const call of calls) {
          if (toolCallsThisTurn >= this.maxToolCalls) {
            prepared.push({
              call,
              rejected: {
                reason: "budget",
                message: `max_tool_calls (${this.maxToolCalls}) exceeded`,
              },
            });
            continue;
          }
          const key = `${call.name}:${stableJson(call.input)}`;
          if (this.dedupeToolCalls && seenToolKeys.has(key)) {
            prepared.push({
              call,
              rejected: {
                reason: "duplicate",
                message: `duplicate tool call rejected: ${call.name}`,
              },
            });
            continue;
          }
          seenToolKeys.add(key);

          let effectiveInput = call.input;
          if (this.beforeToolCall) {
            const gate = await this.beforeToolCall({
              callId: call.id,
              name: call.name,
              input: call.input,
              step: apiCallsThisTurn,
              messages: this.messages,
            });
            if (gate?.block) {
              prepared.push({
                call,
                rejected: {
                  reason: "policy",
                  message: gate.reason ?? `tool call blocked by beforeToolCall: ${call.name}`,
                },
              });
              continue;
            }
            if (gate?.input) effectiveInput = gate.input;
          }

          const resolvedCall = { ...call, input: effectiveInput };
          const tool = activeToolMap.get(call.name);
          if (!tool) {
            prepared.push({
              call: resolvedCall,
              rejected: {
                reason: "unknown_tool",
                message: `unknown tool: ${call.name}`,
              },
            });
            continue;
          }
          toolCallsThisTurn += 1;
          prepared.push({ call: resolvedCall, tool });
        }

        const runOne = async (item: (typeof prepared)[number]) => {
          if (item.rejected) {
            return {
              call: item.call,
              rejected: item.rejected,
              output: item.rejected.message,
              isError: true,
              ms: 0,
            };
          }
          const t0 = Date.now();
          let output = "";
          let isError = false;
          try {
            const raw = await item.tool!.execute(item.call.input, {
              callId: item.call.id,
              signal: turnController.signal,
              workspace: this.workspace,
            });
            if (typeof raw === "string") {
              output = raw;
            } else {
              output = raw.output;
              isError = Boolean(raw.isError);
            }
          } catch (err) {
            output = err instanceof Error ? err.message : String(err);
            isError = true;
          }
          if (this.afterToolCall) {
            const post = await this.afterToolCall({
              callId: item.call.id,
              name: item.call.name,
              input: item.call.input,
              output,
              isError,
              step: apiCallsThisTurn,
            });
            if (post?.output !== undefined) output = post.output;
            if (post?.isError !== undefined) isError = post.isError;
          }
          return {
            call: item.call,
            output,
            isError,
            ms: Math.max(0, Date.now() - t0),
          };
        };

        for (const item of prepared) {
          if (!item.rejected) {
            yield this.emit({ type: "tool_call", name: item.call.name, input: item.call.input });
            yield this.emit({ type: "tool_call_started", name: item.call.name, input: item.call.input });
          }
        }

        const isMutating = (name: string) =>
          name === "write_file" || name === "edit_file" || name === "bash";

        this.mhStats.opsExecuted += prepared.length;
        if (prepared.length > 1) {
          this.mhStats.llmRoundTripsSaved += prepared.length - 1;
        }

        const executed = await (async () => {
          if (this.toolExecMode === "parallel") {
            if (prepared.length > 0) this.mhStats.wavesLaunched += 1;
            if (prepared.length > 1) this.mhStats.parallelOpsFused += prepared.length;
            return Promise.all(prepared.map(runOne));
          }
          if (this.toolExecMode === "wave") {
            const out = [];
            let i = 0;
            while (i < prepared.length) {
              if (isMutating(prepared[i].call.name)) {
                this.mhStats.wavesLaunched += 1;
                out.push(await runOne(prepared[i]));
                i += 1;
              } else {
                const wave = [];
                while (i < prepared.length && !isMutating(prepared[i].call.name)) {
                  wave.push(prepared[i]);
                  i += 1;
                }
                this.mhStats.wavesLaunched += 1;
                if (wave.length > 1) this.mhStats.parallelOpsFused += wave.length;
                out.push(...(await Promise.all(wave.map(runOne))));
              }
            }
            return out;
          }
          const list = [];
          for (const item of prepared) {
            this.mhStats.wavesLaunched += 1;
            list.push(await runOne(item));
          }
          return list;
        })();

        for (const res of executed) {
          if (res.rejected) {
            yield this.emit({
              type: "tool_rejected",
              name: res.call.name,
              reason: res.rejected.reason,
              input: res.call.input,
              message: res.rejected.message,
            });
          }
          yield this.emit({
            type: "tool_result",
            name: res.call.name,
            is_error: res.isError,
            text: res.output,
          });
          if (!res.rejected) {
            yield this.emit({
              type: "tool_call_finished",
              name: res.call.name,
              is_error: res.isError,
              ms: res.ms,
            });
          }
          this.messages.push({
            role: "tool",
            toolCallId: res.call.id,
            toolName: res.call.name,
            content: res.output,
            isError: res.isError,
          });
        }
      }

      const contextChars = this.messages.reduce((acc, m) => acc + (m.content?.length ?? 0), 0);
      const contextTokens = inputTokens > 0 ? inputTokens + outputTokens : Math.ceil(contextChars / 4);
      yield this.emit({ type: "finalizing" });
      yield this.emit({
        type: "turn",
        text: finalText,
        context_tokens: contextTokens,
        cost_usd: costUsd,
        input_tokens: inputTokens,
        uncached_input_tokens: uncachedInputTokens,
        cache_read_tokens: cacheReadTokens,
        output_tokens: outputTokens,
        api_calls: apiCallsThisTurn,
        subscription_calls: 0,
        unpriced_calls: costUsd === 0 && apiCallsThisTurn > 0 ? apiCallsThisTurn : 0,
        complete: true,
        metadata_complete: true,
        usage_complete: true,
        missing_usage_calls: 0,
        unreported_failed_attempts: 0,
      });
    } finally {
      if (savedReviewMessages) this.messages = savedReviewMessages;
      callerSignal?.removeEventListener("abort", onCallerAbort);
      this.activeAbort = undefined;
      release();
    }
  }

  async askResult(input: string | ChatOptions): Promise<AskResult> {
    let result: AskResult | null = null;
    for await (const ev of this.chat(input)) {
      if (ev.type === "turn") {
        result = {
          text: ev.text,
          contextTokens: ev.context_tokens,
          costUsd: ev.cost_usd,
          inputTokens: ev.input_tokens,
          uncachedInputTokens: ev.uncached_input_tokens,
          cacheReadTokens: ev.cache_read_tokens,
          outputTokens: ev.output_tokens,
          apiCalls: ev.api_calls,
          subscriptionCalls: ev.subscription_calls,
          unpricedCalls: ev.unpriced_calls,
          complete: ev.complete,
          metadataComplete: ev.metadata_complete,
          usageComplete: ev.usage_complete,
          missingUsageCalls: ev.missing_usage_calls,
          unreportedFailedAttempts: ev.unreported_failed_attempts,
        };
      }
      if (ev.type === "error") throw new Error(ev.message);
    }
    if (!result) throw new Error("turn ended without a terminal event");
    return result;
  }

  async ask(input: string | ChatOptions): Promise<string> {
    return (await this.askResult(input)).text;
  }

  review(input: string | ChatOptions): Promise<string> {
    const options = typeof input === "string" ? { prompt: input } : input;
    return this.ask({ ...options, review: true });
  }

  setModel(provider: ProviderId | string, model: ModelName | string): Promise<void> {
    return this.runOp(async () => {
      if (!provider || !model) throw new Error("provider and model are required");
      this.providerId = provider;
      this.modelName = model;
      this.emit({ type: "model", ok: true, provider, model, context: 200000, note: "" });
    });
  }

  setEffort(level: EffortLevel): Promise<void> {
    return this.runOp(async () => {
      this.effortLevel = level;
      this.emit({ type: "effort", ok: true, level, applies: true });
    });
  }

  setSystemPrompt(text: string, append = false): Promise<void> {
    return this.runOp(async () => {
      if (append) {
        this.appendedSystemPrompt = this.appendedSystemPrompt
          ? `${this.appendedSystemPrompt}\\n\\n${text}`
          : text;
      } else {
        this.baseSystemPrompt = text;
        this.appendedSystemPrompt = "";
      }
      this.emit({
        type: "system_prompt",
        ok: true,
        append,
        chars: this.effectiveSystemPrompt().length,
      });
    });
  }

  appendSystemPrompt(text: string): Promise<void> {
    return this.setSystemPrompt(text, true);
  }

  /** Compact in-memory conversation history by summarizing earlier turns into
   *  a compact handoff note while preserving the most recent turn verbatim. */
  compact(): Promise<void> {
    return this.runOp(async () => {
      if (this.messages.length <= 2) {
        const chars = this.messages.reduce((a, m) => a + m.content.length, 0);
        this.emit({ type: "compact", ok: true, chars });
        return;
      }
      const keepFrom = Math.max(1, this.messages.length - 2);
      const older = this.messages.slice(0, keepFrom);
      const recent = this.messages.slice(keepFrom);
      const summaryLines = older.map((m) => {
        const snippet = m.content.slice(0, 200).replace(/\\s+/g, " ");
        return `- [${m.role}${m.toolName ? `:${m.toolName}` : ""}] ${snippet}`;
      });
      const handoff: ServerlessMessage = {
        role: "user",
        content: `[compacted session summary (${older.length} earlier messages)]\\n${summaryLines.join("\\n")}`,
      };
      this.messages = [handoff, ...recent];
      const chars = this.messages.reduce((a, m) => a + m.content.length, 0);
      this.emit({ type: "compact", ok: true, chars });
    });
  }

  cancel(): void {
    this.activeAbort?.abort();
  }

  version(): string {
    return HARNESS_VERSION;
  }

  async close(): Promise<void> {
    this.closed = true;
    this.cancel();
  }

  dispose(): Promise<void> {
    return this.close();
  }
}

export interface RunAgentServerlessOptions extends ServerlessOptions {
  prompt: string;
  images?: ImageInput[];
}

/** Run a single serverless turn, streaming `Event`s, and close. */
export async function* runAgentServerless(opts: RunAgentServerlessOptions): AsyncGenerator<Event> {
  const h = new ServerlessHarness(opts);
  try {
    yield* h.chat({ prompt: opts.prompt, images: opts.images });
  } finally {
    await h.close();
  }
}

/** Create a serverless agent session with an in-memory or custom workspace
 *  (pi-coding-agent `createAgentSession` parity). */
export function createAgentSession(opts: ServerlessOptions = {}): {
  harness: ServerlessHarness;
  workspace: WorkspaceOperations;
} {
  const harness = new ServerlessHarness(opts);
  return { harness, workspace: harness.workspace };
}
"""

SERVERLESS_PY = """

# ── Serverless / In-Memory Agent Runtime (Stdlib-only, Lambda/Edge ready) ──

class InMemoryWorkspace:
    \"\"\"In-memory virtual workspace for serverless / stateless Python agent runs.
    Supports `read_file`, `write_file`, `delete_file`, `list_files`, `snapshot`,
    `restore`, and `diff` without touching the host filesystem.\"\"\"

    def __init__(self, initial_files: Optional[dict] = None, exec_fn=None):
        self._files: dict = {}
        for k, v in (initial_files or {}).items():
            self._files[self._norm(k)] = str(v)
        self.exec_fn = exec_fn

    @staticmethod
    def _norm(path: str) -> str:
        p = path.replace("\\\\", "/").lstrip("./")
        while p.startswith("/"):
            p = p[1:]
        return p.rstrip("/")

    def read_file(self, path: str) -> str:
        key = self._norm(path)
        if key not in self._files:
            raise FileNotFoundError(f"ENOENT: file not found: {path}")
        return self._files[key]

    def write_file(self, path: str, content: str) -> None:
        self._files[self._norm(path)] = str(content)

    def delete_file(self, path: str) -> None:
        key = self._norm(path)
        if key not in self._files:
            raise FileNotFoundError(f"ENOENT: file not found: {path}")
        del self._files[key]

    def list_files(self, prefix: str = "") -> List[str]:
        p = self._norm(prefix)
        return sorted(
            k for k in self._files.keys()
            if not p or k == p or k.startswith(p + "/")
        )

    def snapshot(self) -> dict:
        return {k: self._files[k] for k in sorted(self._files.keys())}

    def restore(self, files: dict) -> None:
        self._files.clear()
        for k, v in files.items():
            self._files[self._norm(k)] = str(v)

    def diff(self, baseline: Optional[dict] = None) -> List[dict]:
        base = {self._norm(k): str(v) for k, v in (baseline or {}).items()}
        keys = sorted(set(base.keys()) | set(self._files.keys()))
        out: List[dict] = []
        for k in keys:
            b = base.get(k)
            a = self._files.get(k)
            if b is None and a is not None:
                out.append({"path": k, "status": "added"})
            elif b is not None and a is None:
                out.append({"path": k, "status": "deleted"})
            elif b != a:
                out.append({"path": k, "status": "modified"})
        return out


def define_tool(name: str, description: str, parameters: dict, execute) -> dict:
    \"\"\"Define a tool for `ServerlessHarness`.\"\"\"
    return {
        "name": name,
        "description": description,
        "parameters": parameters,
        "execute": execute,
    }


def create_read_only_tools(workspace: InMemoryWorkspace) -> List[dict]:
    \"\"\"Create read-only coding tools (`read_file`, `list_dir`, `grep`) backed by `workspace`.\"\"\"
    def _read(inp: dict, _ctx: dict):
        content = workspace.read_file(str(inp.get("path", "")))
        lines = content.split("\\n")
        start = max(1, int(inp.get("start_line") or 1))
        end = min(len(lines), int(inp.get("end_line") or len(lines)))
        return "\\n".join(f"{start + i}: {line}" for i, line in enumerate(lines[start - 1:end]))

    def _list(inp: dict, _ctx: dict):
        files = workspace.list_files(str(inp.get("path", "")))
        return "\\n".join(files) if files else "(empty)"

    def _grep(inp: dict, _ctx: dict):
        pattern = str(inp.get("pattern", ""))
        rx = re.compile(pattern)
        matches = []
        for f in workspace.list_files(str(inp.get("path", ""))):
            for idx, line in enumerate(workspace.read_file(f).split("\\n"), 1):
                if rx.search(line):
                    matches.append(f"{f}:{idx}:{line}")
        return "\\n".join(matches) if matches else "No matches found."

    return [
        define_tool(
            "read_file",
            "Read the contents of a file in the workspace.",
            {"type": "object", "properties": {"path": {"type": "string"}, "start_line": {"type": "integer"}, "end_line": {"type": "integer"}}, "required": ["path"]},
            _read,
        ),
        define_tool(
            "list_dir",
            "List files in the workspace under an optional prefix.",
            {"type": "object", "properties": {"path": {"type": "string"}}},
            _list,
        ),
        define_tool(
            "grep",
            "Search files in the workspace for a regex pattern.",
            {"type": "object", "properties": {"pattern": {"type": "string"}, "path": {"type": "string"}}, "required": ["pattern"]},
            _grep,
        ),
    ]


def create_coding_tools(workspace: InMemoryWorkspace) -> List[dict]:
    \"\"\"Create coding tools (`read_file`, `write_file`, `edit_file`, `list_dir`, `grep`, and optional `bash`) backed by `workspace`.\"\"\"
    tools = list(create_read_only_tools(workspace))

    def _write(inp: dict, _ctx: dict):
        path = str(inp.get("path", ""))
        content = str(inp.get("content", ""))
        workspace.write_file(path, content)
        return f"Wrote {len(content)} bytes to {path}"

    def _edit(inp: dict, _ctx: dict):
        path = str(inp.get("path", ""))
        old_s = str(inp.get("old_str", ""))
        new_s = str(inp.get("new_str", ""))
        replace_all = bool(inp.get("replace_all", False))
        if not old_s:
            return {"output": "old_str must not be empty", "is_error": True}
        content = workspace.read_file(path)
        count = content.count(old_s)
        if count == 0:
            return {"output": f"old_str not found in {path}", "is_error": True}
        if count > 1 and not replace_all:
            return {"output": f"old_str appears {count} times in {path}", "is_error": True}
        updated = content.replace(old_s, new_s) if replace_all else content.replace(old_s, new_s, 1)
        workspace.write_file(path, updated)
        return f"Updated {path}"

    tools.append(define_tool(
        "write_file",
        "Create or overwrite a file in the workspace.",
        {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
        _write,
    ))
    tools.append(define_tool(
        "edit_file",
        "Replace an exact string in a file with a new string.",
        {"type": "object", "properties": {"path": {"type": "string"}, "old_str": {"type": "string"}, "new_str": {"type": "string"}, "replace_all": {"type": "boolean"}}, "required": ["path", "old_str", "new_str"]},
        _edit,
    ))
    if workspace.exec_fn is not None:
        def _bash(inp: dict, _ctx: dict):
            res = workspace.exec_fn(str(inp.get("command", "")))
            return {"output": res.get("output", ""), "is_error": res.get("exit_code", 0) != 0}
        tools.append(define_tool(
            "bash",
            "Execute a shell command in the workspace.",
            {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]},
            _bash,
        ))
    return tools


class ServerlessHarness:
    \"\"\"Zero-binary, stdlib-only Python agent session for AWS Lambda, Cloud
    Functions, and in-memory testing. Emits the same event dicts as `Harness`
    and `RemoteHarness`.\"\"\"

    def __init__(self, provider: str = "codegraff", model: str = "gpt-5.5",
                 api_key: Optional[str] = None, endpoint: Optional[str] = None,
                 system_prompt: Optional[str] = None,
                 append_system_prompt: Optional[str] = None,
                 workspace: Optional[Union[InMemoryWorkspace, dict]] = None,
                 coding_tools: Union[bool, str] = True,
                 tools: Optional[List[dict]] = None,
                 stream_fn=None, before_tool_call=None, after_tool_call=None,
                 transform_context=None, max_tool_calls: int = 32,
                 max_model_calls: int = 64, dedupe_tool_calls: bool = False,
                 session: Optional[dict] = None):
        if isinstance(workspace, InMemoryWorkspace):
            self.workspace = workspace
        else:
            self.workspace = InMemoryWorkspace(workspace if isinstance(workspace, dict) else {})
        if session and isinstance(session.get("files"), dict):
            self.workspace.restore(session["files"])
        self.session_id = (session or {}).get("session_id") or ("serverless-" + secrets.token_hex(4))
        self.provider = (session or {}).get("provider") or provider
        self.model = (session or {}).get("model") or model
        self.effort = (session or {}).get("effort") or "medium"
        self.base_system_prompt = (session or {}).get("system_prompt") or system_prompt or (
            "You are Graff, an autonomous coding agent. Use the provided tools to inspect, edit, and verify files before answering."
        )
        self.appended_system_prompt = append_system_prompt or ""
        self.last_seq = int((session or {}).get("seq") or 0)
        self.messages: List[dict] = list((session or {}).get("messages") or [])
        self.api_key = api_key
        self.endpoint = endpoint
        self.stream_fn = stream_fn
        self.before_tool_call = before_tool_call
        self.after_tool_call = after_tool_call
        self.transform_context = transform_context
        self.max_tool_calls = max_tool_calls
        self.max_model_calls = max_model_calls
        self.total_model_calls = 0
        self.dedupe_tool_calls = dedupe_tool_calls
        self._steer_queue: List[str] = []
        self._followup_queue: List[str] = []
        self._mh_stats: dict = {
            "waves_launched": 0,
            "ops_executed": 0,
            "parallel_ops_fused": 0,
            "llm_round_trips_saved": 0,
        }
        self._tool_map: dict = {}
        if coding_tools == "readonly":
            for t in create_read_only_tools(self.workspace):
                self._tool_map[t["name"]] = t
        elif coding_tools:
            for t in create_coding_tools(self.workspace):
                self._tool_map[t["name"]] = t
        for t in (tools or []):
            self._tool_map[t["name"]] = t

    def steer(self, text: str) -> None:
        if text.strip():
            self._steer_queue.append(text)

    def follow_up(self, text: str) -> None:
        if text.strip():
            self._followup_queue.append(text)

    def get_megaharness_stats(self) -> dict:
        return dict(self._mh_stats)

    def export_state(self) -> dict:
        return {
            "version": 1,
            "session_id": self.session_id,
            "provider": self.provider,
            "model": self.model,
            "effort": self.effort,
            "system_prompt": self._effective_system_prompt(),
            "seq": self.last_seq,
            "messages": json.loads(json.dumps(self.messages)),
            "files": self.workspace.snapshot(),
        }

    def import_state(self, snapshot: dict) -> None:
        self.provider = snapshot["provider"]
        self.model = snapshot["model"]
        self.effort = snapshot.get("effort", "medium")
        self.base_system_prompt = snapshot["system_prompt"]
        self.appended_system_prompt = ""
        self.last_seq = int(snapshot.get("seq", 0))
        self.messages = json.loads(json.dumps(snapshot.get("messages", [])))
        if isinstance(snapshot.get("files"), dict):
            self.workspace.restore(snapshot["files"])

    def _effective_system_prompt(self) -> str:
        if self.appended_system_prompt:
            return f"{self.base_system_prompt}\\n\\n{self.appended_system_prompt}"
        return self.base_system_prompt

    def _emit(self, payload: dict) -> dict:
        self.last_seq += 1
        return {"seq": self.last_seq, **payload}

    def chat(self, text: str, review: bool = False,
             images: Optional[List[ImageInput]] = None) -> Iterator[dict]:
        saved = json.loads(json.dumps(self.messages)) if review else None
        try:
            yield self._emit({"type": "started", "provider": self.provider, "model": self.model})
            user_msg: dict = {"role": "user", "content": text}
            if images:
                user_msg["images"] = images
            self.messages.append(user_msg)
            active_tools = create_read_only_tools(self.workspace) if review else list(self._tool_map.values())
            active_map = {t["name"]: t for t in active_tools}
            tool_calls_turn = 0
            api_calls_turn = 0
            in_tok = 0
            out_tok = 0
            final_text = ""
            seen_keys = set()

            while True:
                while self._steer_queue:
                    self.messages.append({"role": "user", "content": self._steer_queue.pop(0)})
                if self.total_model_calls >= self.max_model_calls:
                    yield self._emit({"type": "error", "message": f"max_model_calls ({self.max_model_calls}) exceeded"})
                    return
                ctx_msgs = self.transform_context(list(self.messages)) if self.transform_context else list(self.messages)
                self.total_model_calls += 1
                api_calls_turn += 1
                req_payload = {
                    "provider": self.provider,
                    "model": self.model,
                    "effort": self.effort,
                    "system_prompt": (
                        f"{self._effective_system_prompt()}\\n\\n[review mode: read-only inspection]"
                        if review else self._effective_system_prompt()
                    ),
                    "messages": ctx_msgs,
                    "tools": [{"name": t["name"], "description": t["description"], "parameters": t["parameters"]} for t in active_tools],
                }
                try:
                    resp = self.stream_fn(req_payload) if self.stream_fn is not None else self._call_http_provider(req_payload)
                except Exception as err:
                    yield self._emit({"type": "error", "message": str(err)})
                    return
                step_text = resp.get("text", "")
                in_tok += int(resp.get("input_tokens", 0))
                out_tok += int(resp.get("output_tokens", 0))
                if step_text:
                    final_text = step_text
                    yield self._emit({"type": "text", "text": step_text})
                calls = resp.get("tool_calls") or []
                self.messages.append({"role": "assistant", "content": step_text, "tool_calls": calls})
                if not calls:
                    if self._followup_queue:
                        self.messages.append({"role": "user", "content": self._followup_queue.pop(0)})
                        continue
                    break
                self._mh_stats["waves_launched"] += 1
                self._mh_stats["ops_executed"] += len(calls)
                if len(calls) > 1:
                    self._mh_stats["parallel_ops_fused"] += len(calls)
                    self._mh_stats["llm_round_trips_saved"] += len(calls) - 1
                for call in calls:
                    name = call.get("name", "")
                    inp = call.get("input") or {}
                    cid = call.get("id", "call_1")
                    if tool_calls_turn >= self.max_tool_calls:
                        msg = f"max_tool_calls ({self.max_tool_calls}) exceeded"
                        yield self._emit({"type": "tool_rejected", "name": name, "reason": "budget", "input": inp, "message": msg})
                        yield self._emit({"type": "tool_result", "name": name, "is_error": True, "text": msg})
                        self.messages.append({"role": "tool", "tool_call_id": cid, "tool_name": name, "content": msg, "is_error": True})
                        continue
                    k = f"{name}:{json.dumps(inp, sort_keys=True)}"
                    if self.dedupe_tool_calls and k in seen_keys:
                        msg = f"duplicate tool call rejected: {name}"
                        yield self._emit({"type": "tool_rejected", "name": name, "reason": "duplicate", "input": inp, "message": msg})
                        yield self._emit({"type": "tool_result", "name": name, "is_error": True, "text": msg})
                        self.messages.append({"role": "tool", "tool_call_id": cid, "tool_name": name, "content": msg, "is_error": True})
                        continue
                    seen_keys.add(k)
                    if self.before_tool_call:
                        gate = self.before_tool_call({"call_id": cid, "name": name, "input": inp, "step": api_calls_turn})
                        if isinstance(gate, dict) and gate.get("block"):
                            msg = gate.get("reason") or f"blocked: {name}"
                            yield self._emit({"type": "tool_rejected", "name": name, "reason": "policy", "input": inp, "message": msg})
                            yield self._emit({"type": "tool_result", "name": name, "is_error": True, "text": msg})
                            self.messages.append({"role": "tool", "tool_call_id": cid, "tool_name": name, "content": msg, "is_error": True})
                            continue
                    tool = active_map.get(name)
                    if tool is None:
                        msg = f"unknown tool: {name}"
                        yield self._emit({"type": "tool_result", "name": name, "is_error": True, "text": msg})
                        self.messages.append({"role": "tool", "tool_call_id": cid, "tool_name": name, "content": msg, "is_error": True})
                        continue
                    tool_calls_turn += 1
                    yield self._emit({"type": "tool_call", "name": name, "input": inp})
                    try:
                        raw = tool["execute"](inp, {"call_id": cid, "workspace": self.workspace})
                        if isinstance(raw, dict):
                            out_s = str(raw.get("output", ""))
                            is_err = bool(raw.get("is_error", False))
                        else:
                            out_s = str(raw)
                            is_err = False
                    except Exception as e:
                        out_s = str(e)
                        is_err = True
                    if self.after_tool_call:
                        post = self.after_tool_call({"call_id": cid, "name": name, "input": inp, "output": out_s, "is_error": is_err})
                        if isinstance(post, dict):
                            out_s = str(post.get("output", out_s))
                            is_err = bool(post.get("is_error", is_err))
                    yield self._emit({"type": "tool_result", "name": name, "is_error": is_err, "text": out_s})
                    self.messages.append({"role": "tool", "tool_call_id": cid, "tool_name": name, "content": out_s, "is_error": is_err})
            yield self._emit({
                "type": "turn",
                "text": final_text,
                "context_tokens": in_tok + out_tok,
                "cost_usd": 0.0,
                "input_tokens": in_tok,
                "uncached_input_tokens": in_tok,
                "cache_read_tokens": 0,
                "output_tokens": out_tok,
                "api_calls": api_calls_turn,
                "subscription_calls": 0,
                "unpriced_calls": api_calls_turn,
                "complete": True,
                "metadata_complete": True,
            })
        finally:
            if saved is not None:
                self.messages = saved

    def ask(self, text: str, images: Optional[List[ImageInput]] = None) -> str:
        final = ""
        for ev in self.chat(text, images=images):
            if ev.get("type") == "turn":
                final = ev["text"]
            elif ev.get("type") == "error":
                raise RuntimeError(ev["message"])
        return final

    def review(self, text: str, images: Optional[List[ImageInput]] = None) -> str:
        final = ""
        for ev in self.chat(text, review=True, images=images):
            if ev.get("type") == "turn":
                final = ev["text"]
            elif ev.get("type") == "error":
                raise RuntimeError(ev["message"])
        return final

    def set_model(self, provider: str, model: str) -> None:
        if not provider or not model:
            raise ValueError("provider and model are required")
        self.provider = provider
        self.model = model

    def set_effort(self, level: str) -> None:
        self.effort = level

    def set_system_prompt(self, text: str, append: bool = False) -> None:
        if append:
            self.appended_system_prompt = (
                f"{self.appended_system_prompt}\\n\\n{text}" if self.appended_system_prompt else text
            )
        else:
            self.base_system_prompt = text
            self.appended_system_prompt = ""

    def append_system_prompt(self, text: str) -> None:
        self.set_system_prompt(text, append=True)

    def compact(self) -> None:
        if len(self.messages) <= 2:
            return
        keep_from = max(1, len(self.messages) - 2)
        older = self.messages[:keep_from]
        recent = self.messages[keep_from:]
        lines = [f"- [{m.get('role')}]: {str(m.get('content', ''))[:200]}" for m in older]
        handoff = {
            "role": "user",
            "content": f"[compacted session summary ({len(older)} earlier messages)]\\n" + "\\n".join(lines),
        }
        self.messages = [handoff, *recent]

    def _call_http_provider(self, req: dict) -> dict:
        if not self.api_key and not self.endpoint:
            raise RuntimeError("ServerlessHarness requires stream_fn, api_key, or endpoint")
        if self.provider == "anthropic":
            url = (self.endpoint or "https://api.anthropic.com/v1").rstrip("/")
            if not url.endswith("/messages"):
                url += "/messages"
            headers = {
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
            }
            if self.api_key:
                headers["x-api-key"] = self.api_key
            body = json.dumps({
                "model": req["model"],
                "max_tokens": 8192,
                "system": req["system_prompt"],
                "messages": [{"role": "user" if m["role"] == "tool" else m["role"], "content": m.get("content", "")} for m in req["messages"]],
                "tools": [{"name": t["name"], "description": t["description"], "input_schema": t["parameters"]} for t in req["tools"]],
            }).encode()
            http_req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            data = json.loads(urllib.request.urlopen(http_req).read())
            text_parts = []
            tool_calls = []
            for b in data.get("content", []):
                if b.get("type") == "text":
                    text_parts.append(b.get("text", ""))
                elif b.get("type") == "tool_use":
                    tool_calls.append({"id": b.get("id", "call_1"), "name": b.get("name", ""), "input": b.get("input") or {}})
            usage = data.get("usage") or {}
            return {
                "text": "".join(text_parts),
                "tool_calls": tool_calls,
                "input_tokens": int(usage.get("input_tokens", 0)),
                "output_tokens": int(usage.get("output_tokens", 0)),
            }
        url = (self.endpoint or "https://api.openai.com/v1").rstrip("/")
        if not url.endswith("/chat/completions"):
            url += "/chat/completions"
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        oai_msgs = [{"role": "system", "content": req["system_prompt"]}]
        for m in req["messages"]:
            if m["role"] == "assistant" and m.get("tool_calls"):
                oai_msgs.append({
                    "role": "assistant",
                    "content": m.get("content") or None,
                    "tool_calls": [
                        {"id": tc.get("id", "call_1"), "type": "function", "function": {"name": tc.get("name", ""), "arguments": json.dumps(tc.get("input") or {})}}
                        for tc in m["tool_calls"]
                    ],
                })
            elif m["role"] == "tool":
                oai_msgs.append({
                    "role": "tool",
                    "tool_call_id": m.get("tool_call_id", "call_1"),
                    "content": m.get("content", ""),
                })
            else:
                oai_msgs.append({"role": m["role"], "content": m.get("content", "")})
        body = json.dumps({
            "model": req["model"],
            "messages": oai_msgs,
            "tools": [{"type": "function", "function": t} for t in req["tools"]] if req["tools"] else None,
        }).encode()
        http_req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        data = json.loads(urllib.request.urlopen(http_req).read())
        choice = (data.get("choices") or [{}])[0].get("message") or {}
        tool_calls = []
        for idx, tc in enumerate(choice.get("tool_calls") or []):
            fn = tc.get("function") or {}
            raw_args = fn.get("arguments") or "{}"
            try:
                parsed = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
            except Exception:
                parsed = {}
            tool_calls.append({"id": tc.get("id", f"call_{idx+1}"), "name": fn.get("name", ""), "input": parsed})
        usage = data.get("usage") or {}
        return {
            "text": choice.get("content") or "",
            "tool_calls": tool_calls,
            "input_tokens": int(usage.get("prompt_tokens", 0)),
            "output_tokens": int(usage.get("completion_tokens", 0)),
        }

    def close(self) -> None:
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def create_agent_session(**kwargs) -> dict:
    \"\"\"Create a serverless Python agent session (`{"harness": h, "workspace": h.workspace}`).\"\"\"
    h = ServerlessHarness(**kwargs)
    return {"harness": h, "workspace": h.workspace}


def run_agent_serverless(prompt: str, **kwargs) -> Iterator[dict]:
    \"\"\"Run a single serverless turn, yielding event dicts.\"\"\"
    with ServerlessHarness(**kwargs) as h:
        yield from h.chat(prompt)
"""
