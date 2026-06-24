// Transport: the codegraff GUI backend is a merjs/Zig HTTP server served by
// the native shell. Commands go over fetch POST /api/<command>; OS-level shell
// ops go through window.mer.invoke when that bridge exists. Push events arrive
// over a single SSE EventSource on /events.
import {
  SESSION_UPDATED_EVENT_NAME,
  MESSAGE_DELTA_EVENT_NAME,
  REQUEST_CANCELLED_EVENT_NAME,
  REQUEST_FINISHED_EVENT_NAME,
  TERMINAL_ERROR_EVENT_NAME,
  TERMINAL_EXIT_EVENT_NAME,
  TERMINAL_OUTPUT_EVENT_NAME,
  PROVIDER_OAUTH_CALLBACK_EVENT_NAME,
} from "./constants/events";
import type {
  AgentsPayload,
  HandoffChatInput,
  CheckoutGitBranchInput,
  ChatBinding,
  CloneRepositoryInput,
  CompleteProviderAuthInput,
  CommandDescriptor,
  CommandRunResult,
  CommitGitChangesInput,
  CreateSavedWorkspaceInput,
  CreateGitBranchInput,
  FollowupResponse,
  McpImportInput,
  McpServerActionInput,
  McpSettingsPayload,
  ProviderAuthSession,
  ProviderOAuthCallback,
  ProviderSummary,
  PromptSettings,
  QuickStartProjectInput,
  RemoveProviderInput,
  RuntimeStatus,
  SavedWorkspaceDetail,
  SaveConversationLayoutInput,
  SendPromptInput,
  SessionSnapshot,
  TerminalCloseInput,
  TerminalErrorEvent,
  TerminalExitEvent,
  TerminalOpenInput,
  TerminalOutputEvent,
  TerminalResizeInput,
  TerminalSession,
  TerminalWriteInput,
  UpdateSavedWorkspaceLayoutInput,
  StartProviderAuthInput,
  UpdatePromptSettingsInput,
  WorkflowDraftInput,
  WorkflowDraftPayload,
  WorkspaceQueryInput,
  WorkspaceSearchPayload,
  WorkspaceSyncPayload,
} from "./types/contracts";

type UnlistenFn = () => void;

export type MessageDeltaEvent = {
  conversationId: string;
  workspacePath: string;
  requestId: string;
  messageId: string;
  kind: "assistant" | "reasoning";
  text: string;
};

export type RequestLifecycleEvent = {
  conversationId: string;
  workspacePath: string;
  requestId: string;
};

const QA_WORKSPACE_PATH = "/Users/pranavp/projects/harness/codegraff/gui";
const QA_CONVERSATION_ID = "qa-existing-chat";
// Browser-based visual QA cannot call native commands, so this flag swaps the
// desktop boundary for deterministic fixtures while leaving production calls untouched.
const isQaMockMode = import.meta.env.VITE_CODEGRAFF_QA_MOCK === "1";

let qaActiveAgentId = "forge";
let qaReasoningEffort: string | null = "medium";

const qaCommandRows: Array<[
  string,
  string,
  string | null,
  CommandDescriptor["resultKind"],
]> = [
  ["help", "Show available slash commands.", null, "text"],
  ["agent", "Show active agent and available agents.", null, "agents"],
  ["bash", "Run a shell command in the workspace.", "<command>", "text"],
  ["sage", "Switch to Sage.", null, "agents"],
  ["reasoning-effort", "Update reasoning effort.", "<low|medium|high>", "text"],
  ["goal", "Set/show the current objective.", "<objective|clear>", "text"],
  ["loop", "Run an autonomous plan→act→verify pass.", "<prompt>", "snapshot"],
  ["workspace-info", "Show indexed workspace metadata.", null, "workspaceInfo"],
  ["workspace-status", "Show workspace file status.", null, "workspaceStatus"],
  ["workspace-query", "Search the workspace semantically.", "<query>", "workspaceSearch"],
  ["mcp", "Show MCP server status.", "list", "mcp"],
  ["workflow", "Draft a reviewable workflow.", "<goal>", "workflowDraft"],
];

const qaCommands: CommandDescriptor[] = qaCommandRows.map(
  ([name, usage, argumentHint, resultKind]) =>
    ({
      aliases:
        name === "workspace-query"
          ? ["workspace-search"]
          : name === "sage"
            ? ["plan"]
            : [],
      argumentHint,
      executionKind: resultKind === "workflowDraft" ? "modal" : "runnable",
      isAgentSwitch: name === "sage",
      kind:
        resultKind === "workflowDraft"
          ? "workflow"
          : name === "sage"
            ? "agent"
            : "builtin",
      name,
      requiresConversation: false,
      requiresWorkspace: name === "bash" || name.startsWith("workspace-"),
      resultKind,
      usage,
      value: name === "sage" ? "sage" : null,
    }) as CommandDescriptor,
);

function createQaSnapshot(
  activeConversationId: string | null = null,
  messages: SessionSnapshot["visibleMessages"] = [],
  followup: SessionSnapshot["visibleFollowup"] = null,
): SessionSnapshot {
  const existingMessages: SessionSnapshot["visibleMessages"] = [
    {
      id: "qa-user-1",
      kind: "user",
      requestId: "qa-request-1",
      text: "Can you explain how slash command routing works?",
    },
    {
      id: "qa-assistant-1",
      kind: "assistant",
      requestId: "qa-request-1",
      text: "Slash commands are detected in the composer and rendered inline when they return informational output.",
    },
  ];

  return {
    activeConversationId,
    activeWorkspacePath: QA_WORKSPACE_PATH,
    conversationViews: [
      {
        activeRequestIds: followup != null ? [followup.requestId] : [],
        conversationId: activeConversationId ?? QA_CONVERSATION_ID,
        followup,
        messages: activeConversationId == null ? existingMessages : messages,
        requestAgentIds: {},
        todos: [],
        workspacePath: QA_WORKSPACE_PATH,
      },
    ],
    savedWorkspaces: [],
    uiError: null,
    visibleActiveRequestIds: followup != null ? [followup.requestId] : [],
    visibleFollowup: followup,
    visibleMessages: messages,
    visibleRequestAgentIds: {},
    visibleTodos: [],
    workspaces: [
      {
        configurationError: null,
        configured: true,
        conversations: [
          {
            conversationId: QA_CONVERSATION_ID,
            hasPendingFollowup: false,
            isDraft: false,
            isRunning: false,
            title: "Existing QA chat",
            updatedAt: "2026-06-03T00:00:00Z",
          },
        ],
        kind: "project",
        selectedConversationId: activeConversationId,
        workspaceName: "Codegraff GUI",
        workspacePath: QA_WORKSPACE_PATH,
      },
    ],
  };
}

function qaPromptSettings(): PromptSettings {
  return {
    availableModels: [
      {
        contextLength: 200000,
        modelId: "claude-sonnet-4",
        modelName: "Claude Sonnet 4",
        providerId: "anthropic",
        providerName: "Anthropic",
        reasoningEfforts: ["low", "medium", "high"],
        supportsReasoning: true,
      },
    ],
    selectedModelId: "claude-sonnet-4",
    selectedProviderId: "anthropic",
    selectedReasoningEffort: qaReasoningEffort,
    fastEnabled: false,
    fastApplies: false,
  };
}

function qaRuntimeStatus(): RuntimeStatus {
  return {
    availableOpenTargets: ["file-manager"],
    configurationError: null,
    configured: true,
    gitBranchName: "qa/mock-browser",
    gitBranches: ["main", "qa/mock-browser"],
    gitMainWorkspacePath: QA_WORKSPACE_PATH,
    gitRepoName: "codegraff",
    gitWorkspaceKind: "local",
    workspaceName: "Codegraff GUI",
    workspacePath: QA_WORKSPACE_PATH,
  };
}

function qaAgentsPayload(): AgentsPayload {
  return {
    activeAgentId: qaActiveAgentId,
    agents: [
      { description: "Implementation assistant for focused coding tasks.", id: "forge", isActive: qaActiveAgentId === "forge", modelId: "claude-sonnet-4", title: "Forge" },
      { description: "Research assistant for deeper analysis.", id: "sage", isActive: qaActiveAgentId === "sage", modelId: "claude-sonnet-4", title: "Sage" },
    ],
    selectedModelId: "claude-sonnet-4",
    selectedProviderId: "anthropic",
    selectedReasoningEffort: qaReasoningEffort,
  };
}

function qaCommandResult(input: {
  name: string;
  args: string[];
  workspacePath?: string | null;
  conversationId?: string | null;
}): CommandRunResult {
  const title = `/${input.name}${input.args.length > 0 ? ` ${input.args.join(" ")}` : ""}`;

  switch (input.name) {
    case "help":
      return { body: "| Command | What it does | UI expectation |\n|---|---|---|\n| `/help` | Lists commands | Inline table |\n| `/agent` | Shows current agent | Inline cards |\n| `/bash <command>` | Runs a workspace shell command | Inline text |\n| `/workspace-info` | Shows metadata | Inline markdown/table |\n| `/workflow <goal>` | Builds a workflow draft | Review modal |", payload: null, resultKind: "text", savedPath: null, snapshot: null, title: "/help" };
    case "agent":
      return { body: "Current agent status.", payload: { kind: "agents", ...qaAgentsPayload() }, resultKind: "agents", savedPath: null, snapshot: null, title };
    case "bash": {
      const command = input.args.join(" ").trim();
      return { body: command.length > 0 ? `QA mock did not execute shell command:\n\n$ ${command}` : "usage: /bash <command>", payload: null, resultKind: "text", savedPath: null, snapshot: null, title: command.length > 0 ? `/bash ${command}` : "/bash" };
    }
    case "sage":
      qaActiveAgentId = "sage";
      return { body: "Switched active agent to Sage.", payload: { kind: "agents", ...qaAgentsPayload() }, resultKind: "agents", savedPath: null, snapshot: null, title };
    case "reasoning-effort":
      qaReasoningEffort = input.args[0] ?? qaReasoningEffort;
      return { body: `Reasoning effort is now **${qaReasoningEffort ?? "default"}**.`, payload: null, resultKind: "text", savedPath: null, snapshot: null, title };
    case "goal":
      return { body: input.args.length > 0 ? `Goal set: **${input.args.join(" ")}**.` : "No active goal. Set one with `/goal <objective>`.", payload: null, resultKind: "text", savedPath: null, snapshot: null, title };
    case "loop":
      return { body: "Started an autonomous plan→act→verify pass.", payload: null, resultKind: "snapshot", savedPath: null, snapshot: createQaSnapshot(input.conversationId ?? QA_CONVERSATION_ID, [{ id: "qa-loop-user", kind: "user", requestId: "qa-loop-request", text: `/loop ${input.args.join(" ")}` }, { id: "qa-loop-assistant", kind: "assistant", requestId: "qa-loop-request", text: "Loop pass complete: planned, acted, and verified the requested change." }]), title };
    case "workspace-info":
      return { body: "| Field | Value |\n|---|---|\n| Workspace | Codegraff GUI |\n| Branch | qa/mock-browser |\n| Indexed nodes | 1,284 |", payload: { createdAt: "2026-06-03T00:00:00Z", kind: "workspaceInfo", lastUpdated: "2026-06-03T12:00:00Z", nodeCount: 1284, relationCount: 642, workingDir: QA_WORKSPACE_PATH, workspaceId: "qa-codegraff-gui", workspacePath: QA_WORKSPACE_PATH }, resultKind: "workspaceInfo", savedPath: null, snapshot: null, title };
    case "workspace-status":
      return { body: "Workspace has 2 modified files and no conflicts.", payload: { files: [{ path: "src/hooks/useCommandRouter.ts", status: "modified" }, { path: "src/components/chat/ChatCommandResultRow.tsx", status: "modified" }, { path: "src/components/PromptInputCard.tsx", status: "clean" }], kind: "workspaceStatus", workspacePath: QA_WORKSPACE_PATH }, resultKind: "workspaceStatus", savedPath: null, snapshot: null, title };
    case "workspace-query":
      return { body: `Found 2 results for **${input.args.join(" ") || "command routing"}**.`, payload: { kind: "workspaceSearch", query: input.args.join(" "), results: [{ distance: 0.12, endLine: 99, kind: "function", nodeId: "router", path: "src/hooks/useCommandRouter.ts", preview: "publishCommandResult sends command output into the chat thread.", relevance: 0.91, startLine: 70 }, { distance: 0.18, endLine: 35, kind: "component", nodeId: "result-row", path: "src/components/chat/ChatCommandResultRow.tsx", preview: "ChatCommandResultRow renders markdown and structured payload cards.", relevance: 0.84, startLine: 16 }], workspacePath: QA_WORKSPACE_PATH }, resultKind: "workspaceSearch", savedPath: null, snapshot: null, title };
    case "mcp":
      return { body: "No MCP servers are configured in this QA workspace.", payload: { kind: "mcp", servers: [] }, resultKind: "mcp", savedPath: null, snapshot: null, title };
    case "workflow":
      return { body: "Review the generated workflow before approving.", payload: { approvedPrompt: `Execute workflow: ${input.args.join(" ")}`, exportText: "goal: test a small change\nnodes:\n  - inspect\n  - verify", goal: input.args.join(" ") || "test a small change", kind: "workflowDraft", nodes: [{ access: [], artifact: "findings", dependencies: [], name: "inspect", stopCondition: "UI issues identified", task: "Inspect the slash command UI.", worker: "sage" }, { access: ["inspect"], artifact: "fixes", dependencies: ["inspect"], name: "verify", stopCondition: "QA pass complete", task: "Verify fixes in the browser.", worker: "forge" }], summary: "Two-step QA workflow for slash command behavior.", trace: ["Created QA workflow draft"] }, resultKind: "workflowDraft", savedPath: null, snapshot: null, title };
    default:
      return { body: `Unknown command: /${input.name}`, payload: null, resultKind: "text", savedPath: null, snapshot: null, title: "Command failed" };
  }
}

function mockInvokeCommand<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  // Keep the mock at the invoke boundary so the rest of the app exercises the
  // same service functions, stores, and component flows used by the desktop app.
  switch (command) {
    case "get_session_snapshot":
    case "create_managed_chat":
    case "start_new_chat":
      return Promise.resolve(createQaSnapshot() as T);
    case "select_conversation":
    case "ensure_conversation_view":
      return Promise.resolve(createQaSnapshot(QA_CONVERSATION_ID, createQaSnapshot().conversationViews[0]?.messages ?? []) as T);
    case "get_runtime_status":
      return Promise.resolve(qaRuntimeStatus() as T);
    case "get_prompt_settings":
      return Promise.resolve(qaPromptSettings() as T);
    case "update_prompt_settings":
      qaReasoningEffort = (args?.input as UpdatePromptSettingsInput | undefined)?.reasoningEffort ?? qaReasoningEffort;
      return Promise.resolve(qaPromptSettings() as T);
    case "list_commands":
      return Promise.resolve(qaCommands as T);
    case "run_slash_command":
      return Promise.resolve(qaCommandResult(args as Parameters<typeof qaCommandResult>[0]) as T);
    case "send_prompt": {
      const input = args?.input as SendPromptInput;
      const conversationId = input.conversationId ?? "qa-new-chat";
      const requestId = `${conversationId}-request`;
      // A "ask" prompt surfaces a pending ask_user followup with suggested
      // options — exercises the redesigned FollowupComposer (highlightable
      // options above a Notes box, Enter to send option + notes).
      if (/\bask\b/i.test(input.prompt)) {
        const followup = {
          conversationId,
          followupId: `${requestId}-followup`,
          kind: "single" as const,
          options: [
            { id: "opt-1", label: "Refactor the routing module" },
            { id: "opt-2", label: "Add a regression test first" },
            { id: "opt-3", label: "Investigate the root cause deeper" },
          ],
          question:
            "I found two possible approaches before changing the routing logic. Which direction should I take?",
          requestId,
          workspacePath: QA_WORKSPACE_PATH,
        };
        return Promise.resolve(
          createQaSnapshot(conversationId, [
            { id: `${conversationId}-user`, kind: "user", requestId, text: input.prompt },
            {
              id: `${conversationId}-assistant-1`,
              kind: "assistant",
              requestId,
              text: "Before I change the routing logic, I want to confirm the direction with you.",
            },
          ], followup) as T,
        );
      }
      // Showcase transcript that exercises chronological tool/text interleaving
      // (tools→text→tools→text), a reasoning/thinking block, and a final
      // markdown answer — so visual QA can verify the ordering + answer panel.
      return Promise.resolve(createQaSnapshot(conversationId, [
        { id: `${conversationId}-user`, kind: "user", requestId, text: input.prompt },
        { id: `${conversationId}-reasoning`, kind: "reasoning", requestId, text: "Let me look at the project structure first, then narrow down where the change needs to go." },
        { id: `${conversationId}-assistant-1`, kind: "assistant", requestId, text: "I'll start by listing the source files." },
        { id: `${conversationId}-tool-start-1`, kind: "tool_start", requestId, name: "shell", callId: `${conversationId}-call-1`, detail: { kind: "shell", command: "rg --files src", cwd: null, description: null } },
        { id: `${conversationId}-tool-end-1`, kind: "tool_end", requestId, name: "shell", callId: `${conversationId}-call-1`, summary: "Listed 12 source files", isError: false, detail: { kind: "text", text: "src/main.ts\nsrc/utils.ts\nsrc/config.ts" } },
        { id: `${conversationId}-assistant-2`, kind: "assistant", requestId, text: "Found the relevant module. Let me read it and apply the fix." },
        { id: `${conversationId}-tool-start-2`, kind: "tool_start", requestId, name: "tool", callId: `${conversationId}-call-2`, detail: { kind: "file_read", path: "src/utils.ts", startLine: null, endLine: null } },
        { id: `${conversationId}-tool-end-2`, kind: "tool_end", requestId, name: "tool", callId: `${conversationId}-call-2`, summary: null, isError: false, detail: null },
        { id: `${conversationId}-tool-start-3`, kind: "tool_start", requestId, name: "tool", callId: `${conversationId}-call-3`, detail: { kind: "file_update", path: "src/utils.ts", operation: "replace" } },
        { id: `${conversationId}-tool-end-3`, kind: "tool_end", requestId, name: "tool", callId: `${conversationId}-call-3`, summary: "Updated src/utils.ts", isError: false, detail: { kind: "file_diff", path: "src/utils.ts", patch: "diff --git a/src/utils.ts b/src/utils.ts\n-export const old = 1;\n+export const value = 42;" } },
        { id: `${conversationId}-assistant-3`, kind: "assistant", requestId, text: "Done. Here's the summary:\n\n- Explored `src/` and read `src/utils.ts`.\n- Updated the exported constant.\n\n```ts\nexport const value = 42;\n```\n\n[Codegraff](https://github.com/justrach/codegraff)" },
      ]) as T);
    }
    case "read_workspace_file":
      return Promise.resolve("// QA mock file contents\nexport const value = 1;\n" as T);
    case "save_attachment_file": {
      const input = args?.input as { name?: string } | undefined;
      return Promise.resolve(`/tmp/${input?.name ?? "attachment.txt"}` as T);
    }
    case "terminal_open": {
      const input = args?.input as TerminalOpenInput | undefined;
      return Promise.resolve({
        terminalId: input?.terminalId ?? "qa-terminal",
        workspacePath: input?.workspacePath ?? QA_WORKSPACE_PATH,
        shell: "browser-qa",
        cols: input?.cols ?? 80,
        rows: input?.rows ?? 24,
      } as T);
    }
    case "terminal_write":
    case "terminal_resize":
    case "terminal_close":
      return Promise.resolve(undefined as T);
    case "list_mcp_servers":
      return Promise.resolve({ servers: [] } as T);
    case "respond_followup": {
      // QA mock: clear the followup and echo the answer as a user message so
      // the composer dismisses and the thread reflects the reply.
      return Promise.resolve(
        createQaSnapshot(QA_CONVERSATION_ID, [
          {
            id: "qa-followup-user",
            kind: "user",
            requestId: "qa-request-1",
            text: "follow-up reply (QA mock)",
          },
        ]) as T,
      );
    }
    default:
      return Promise.resolve(undefined as T);
  }
}

const FILE_MANAGER_TARGET_ID = "file-manager";

type MerInvokeFunction = <T>(name: string, args: unknown) => Promise<T>;

function getMerInvoke(): MerInvokeFunction | null {
  if (typeof window === "undefined") {
    return null;
  }
  const w = window as unknown as {
    mer?: { invoke?: (name: string, args: unknown) => Promise<unknown> };
  };
  if (typeof w.mer?.invoke !== "function") {
    return null;
  }
  const invoke = w.mer.invoke;
  return async <T>(name: string, args: unknown): Promise<T> =>
    (await invoke(name, args)) as T;
}

function apiRoute(command: string): string {
  return `/api/${command}`;
}

function apiFailureMessage(command: string, res: Response, body: string): string {
  const snippet = body.replace(/\s+/g, " ").trim().slice(0, 180);
  const route = apiRoute(command);
  if (res.status === 404 && command.startsWith("terminal_")) {
    return `${command} failed: ${res.status} at ${route}. The GUI backend serving this window does not expose terminal routes; rebuild/restart the native app so gui/routes.zig is current.`;
  }
  return `${command} failed: ${res.status} at ${route}${snippet.length > 0 ? ` — ${snippet}` : ""}`;
}

async function httpInvoke<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(apiRoute(command), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: args ? JSON.stringify(args) : "{}",
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    let parsedError: string | null = null;
    try {
      const parsed = JSON.parse(text) as { error?: unknown };
      if (typeof parsed.error === "string" && parsed.error.length > 0) {
        parsedError = parsed.error;
      }
    } catch {
      // Fall through to the raw HTTP message for non-JSON responses.
    }
    if (parsedError != null) {
      throw new Error(parsedError);
    }
    throw new Error(apiFailureMessage(command, res, text));
  }
  return res.json() as Promise<T>;
}

async function merInvoke<T>(
  name: string,
  args?: Record<string, unknown>,
): Promise<T> {
  const invoke = getMerInvoke();
  if (invoke == null) {
    throw new Error("Native bridge is unavailable");
  }
  return invoke<T>(name, args ?? {});
}

function hasMerInvoke(): boolean {
  return getMerInvoke() != null;
}

export function isNativeBridgeAvailable(): boolean {
  return hasMerInvoke();
}

function openExternalInBrowser(url: string): void {
  window.open(url, "_blank", "noopener,noreferrer");
}

function getBrowserClipboard(): Clipboard | null {
  if (typeof navigator === "undefined") {
    return null;
  }
  return navigator.clipboard ?? null;
}

function isAbsoluteNativePath(path: string): boolean {
  return path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path);
}

function resolveWorkspacePath(workspacePath: string, path: string): string {
  if (path.length === 0) {
    throw new Error("Path is required");
  }
  if (isAbsoluteNativePath(path)) {
    return path;
  }
  const relative = path.replace(/^\.\/+/, "");
  const root = workspacePath.replace(/\/+$/, "");
  if (root.length === 0) {
    throw new Error("Workspace path is required");
  }
  if (relative.length === 0 || relative === ".") {
    return root;
  }
  return `${root}/${relative}`;
}

function unsupportedOpenTargetError(targetId: string): Error {
  return new Error(`Open target is not supported by this build: ${targetId}`);
}

async function invokeCommand<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  if (isQaMockMode) {
    return mockInvokeCommand<T>(command, args);
  }
  return httpInvoke<T>(command, args);
}

let sessionEventSource: EventSource | null = null;
const sessionUpdatedHandlers = new Set<(payload: unknown) => void>();
const nativeEventHandlers = new Map<string, Set<(payload: unknown) => void>>();

function nativeEventType(eventName: string): string {
  if (eventName === SESSION_UPDATED_EVENT_NAME) return "session-updated";
  if (eventName === MESSAGE_DELTA_EVENT_NAME) return "message-delta";
  if (eventName === REQUEST_FINISHED_EVENT_NAME) return "request-finished";
  if (eventName === REQUEST_CANCELLED_EVENT_NAME) return "request-cancelled";
  if (eventName === TERMINAL_OUTPUT_EVENT_NAME) return "terminal-output";
  if (eventName === TERMINAL_EXIT_EVENT_NAME) return "terminal-exit";
  if (eventName === TERMINAL_ERROR_EVENT_NAME) return "terminal-error";
  if (eventName === PROVIDER_OAUTH_CALLBACK_EVENT_NAME) {
    return "provider-oauth-callback";
  }
  return eventName.replace(/^codegraff:\/\//, "");
}

function dispatchNativeEvent(eventName: string, event: MessageEvent) {
  try {
    const payload = JSON.parse(event.data);
    const handlers = nativeEventHandlers.get(eventName);
    if (handlers != null) {
      for (const handler of handlers) {
        handler(payload);
      }
    }
    if (eventName === SESSION_UPDATED_EVENT_NAME) {
      for (const handler of sessionUpdatedHandlers) {
        handler(payload);
      }
    }
  } catch {
    // Ignore malformed frames; EventSource will continue reconnecting.
  }
}

function ensureSessionEventSource(): EventSource {
  if (sessionEventSource) {
    return sessionEventSource;
  }
  const es = new EventSource("/events");
  sessionEventSource = es;
  for (const eventName of [
    SESSION_UPDATED_EVENT_NAME,
    MESSAGE_DELTA_EVENT_NAME,
    REQUEST_FINISHED_EVENT_NAME,
    REQUEST_CANCELLED_EVENT_NAME,
    TERMINAL_OUTPUT_EVENT_NAME,
    TERMINAL_EXIT_EVENT_NAME,
    TERMINAL_ERROR_EVENT_NAME,
    PROVIDER_OAUTH_CALLBACK_EVENT_NAME,
  ]) {
    es.addEventListener(nativeEventType(eventName), (event: MessageEvent) => {
      dispatchNativeEvent(eventName, event);
    });
  }
  return es;
}

function closeNativeEventSourceIfIdle() {
  if (
    sessionUpdatedHandlers.size === 0 &&
    nativeEventHandlers.size === 0 &&
    sessionEventSource != null
  ) {
    sessionEventSource.close();
    sessionEventSource = null;
  }
}

async function listenEvent<T>(
  eventName: string,
  handler: (payload: T) => void,
): Promise<UnlistenFn> {
  if (isQaMockMode) {
    // Native event streams are unavailable in visual QA; tests drive state through mock command
    // responses instead, so listeners become no-op unlisteners in browser mode.
    void eventName;
    void handler;
    return () => undefined;
  }

  if (eventName === SESSION_UPDATED_EVENT_NAME) {
    ensureSessionEventSource();
    const wrapped = (payload: unknown) => handler(payload as T);
    sessionUpdatedHandlers.add(wrapped);
    return () => {
      sessionUpdatedHandlers.delete(wrapped);
      closeNativeEventSourceIfIdle();
    };
  }

  ensureSessionEventSource();
  const wrapped = (payload: unknown) => handler(payload as T);
  const handlers = nativeEventHandlers.get(eventName) ?? new Set();
  handlers.add(wrapped);
  nativeEventHandlers.set(eventName, handlers);
  return () => {
    const current = nativeEventHandlers.get(eventName);
    if (current == null) {
      return;
    }
    current.delete(wrapped);
    if (current.size === 0) {
      nativeEventHandlers.delete(eventName);
    }
    closeNativeEventSourceIfIdle();
  };
}

export function pickWorkspace(): Promise<string | null> {
  if (isQaMockMode) {
    return Promise.resolve(QA_WORKSPACE_PATH);
  }
  if (!hasMerInvoke()) {
    return Promise.resolve(null);
  }
  return merInvoke("dialog.pickDirectory", {
    title: "Open project",
    canCreateDirectories: true,
  });
}

export function pickDirectory(title?: string): Promise<string | null> {
  if (isQaMockMode) {
    void title;
    return Promise.resolve(QA_WORKSPACE_PATH);
  }
  if (!hasMerInvoke()) {
    return Promise.resolve(null);
  }
  return merInvoke(
    "dialog.pickDirectory",
    title != null && title.length > 0 ? { title } : {},
  );
}

export function openWorkspace(path: string): Promise<SessionSnapshot> {
  return invokeCommand("open_workspace", { path });
}

// Drains a path passed to `codegraff <path>` before the app launched (cold start).
export function drainPendingOpen(): Promise<string | null> {
  if (isQaMockMode) {
    return invokeCommand("drain_pending_open");
  }
  if (!hasMerInvoke()) {
    return Promise.resolve(null);
  }
  return merInvoke<string | null>("drainPendingOpen").catch(() => null);
}

// Fires when a second `codegraff <path>` invocation forwards a path to this
// already-running instance (single-instance plugin).
export function onOpenWorkspacePath(
  handler: (path: string) => void,
): Promise<UnlistenFn> {
  return listenEvent<string>("open-workspace-path", handler);
}

export function getRuntimeStatus(
  workspacePath?: string | null,
): Promise<RuntimeStatus> {
  return invokeCommand("get_runtime_status", {
    workspacePath: workspacePath ?? null,
  });
}

export function getSessionSnapshot(): Promise<SessionSnapshot> {
  return invokeCommand("get_session_snapshot");
}

export function getPromptSettings(
  workspacePath?: string | null,
): Promise<PromptSettings> {
  return invokeCommand("get_prompt_settings", {
    workspacePath: workspacePath ?? null,
  });
}

export function listProviders(
  workspacePath?: string | null,
): Promise<ProviderSummary[]> {
  return invokeCommand("list_providers", {
    workspacePath: workspacePath ?? null,
  });
}

export function listCommands(
  workspacePath?: string | null,
): Promise<CommandDescriptor[]> {
  return invokeCommand("list_commands", {
    workspacePath: workspacePath ?? null,
  });
}

export function selectConversation(
  workspacePath: string,
  conversationId: string,
): Promise<SessionSnapshot> {
  return invokeCommand("select_conversation", {
    workspacePath,
    conversationId,
  });
}

export function ensureConversationView(
  workspacePath: string,
  conversationId: string,
): Promise<SessionSnapshot> {
  return invokeCommand("ensure_conversation_view", {
    workspacePath,
    conversationId,
  });
}

export function startNewChat(workspacePath: string): Promise<SessionSnapshot> {
  return invokeCommand("start_new_chat", { workspacePath });
}

export function createManagedChat(): Promise<SessionSnapshot> {
  return invokeCommand("create_managed_chat");
}

export function handoffChat(input: HandoffChatInput): Promise<SessionSnapshot> {
  return invokeCommand("handoff_chat", { input });
}

export function sendPrompt(input: SendPromptInput): Promise<SessionSnapshot> {
  return invokeCommand("send_prompt", { input });
}

export function stopPrompt(input: ChatBinding): Promise<void> {
  return invokeCommand("stop_prompt", { input });
}

export function compactConversation(
  input: ChatBinding,
): Promise<SessionSnapshot> {
  return invokeCommand("compact_conversation", { input });
}

export function runSlashCommand(input: {
  name: string;
  args: string[];
  workspacePath?: string | null;
  conversationId?: string | null;
}): Promise<CommandRunResult> {
  return invokeCommand("run_slash_command", {
    name: input.name,
    args: input.args,
    workspacePath: input.workspacePath ?? null,
    conversationId: input.conversationId ?? null,
  });
}

export function workspaceSync(
  workspacePath: string,
): Promise<WorkspaceSyncPayload> {
  return invokeCommand("workspace_sync", { workspacePath });
}

export function workspaceQuery(
  input: WorkspaceQueryInput,
): Promise<WorkspaceSearchPayload> {
  return invokeCommand("workspace_query", { input });
}

export function buildWorkflowDraft(
  input: WorkflowDraftInput,
): Promise<WorkflowDraftPayload> {
  return invokeCommand("build_workflow_draft", { input });
}

export function exportWorkflowDraft(
  draft: WorkflowDraftPayload,
): Promise<string> {
  return invokeCommand("export_workflow_draft", { draft });
}

export function setActiveAgent(
  agentId: string,
  workspacePath?: string | null,
): Promise<AgentsPayload> {
  return invokeCommand("set_active_agent", {
    agentId,
    workspacePath: workspacePath ?? null,
  });
}

export function setEffort(
  level: "low" | "medium" | "high",
  workspacePath?: string | null,
): Promise<void> {
  return invokeCommand("set_effort", {
    level,
    workspacePath: workspacePath ?? null,
  });
}

export function setFast(
  on: boolean,
  workspacePath?: string | null,
): Promise<void> {
  return invokeCommand("set_fast", {
    on,
    workspacePath: workspacePath ?? null,
  });
}

/** Writes a clipboard-pasted image to a temp file and returns its path. */
export function savePastedImage(
  data: number[],
  ext: string,
): Promise<string> {
  return invokeCommand("save_pasted_image", { data, ext });
}

export function saveAttachmentFile(input: {
  name: string;
  dataBase64: string;
}): Promise<string> {
  return invokeCommand("save_attachment_file", { input });
}

export function readClipboardText(): Promise<string> {
  if (isQaMockMode) {
    return Promise.resolve("");
  }
  if (hasMerInvoke()) {
    return merInvoke("clipboard.read");
  }
  const clipboard = getBrowserClipboard();
  if (clipboard?.readText != null) {
    return clipboard.readText();
  }
  return Promise.reject(new Error("Clipboard read is unavailable"));
}

export function writeClipboardText(text: string): Promise<void> {
  if (isQaMockMode) {
    void text;
    return Promise.resolve();
  }
  if (hasMerInvoke()) {
    return merInvoke("clipboard.write", { text });
  }
  const clipboard = getBrowserClipboard();
  if (clipboard?.writeText != null) {
    return clipboard.writeText(text);
  }
  return Promise.reject(new Error("Clipboard write is unavailable"));
}

/** Returns a compressed JPEG thumbnail of an image file as a data URL. */
export function imageThumbnail(
  path: string,
  maxDim?: number,
): Promise<string> {
  return invokeCommand("image_thumbnail", { path, maxDim: maxDim ?? null });
}

export function listMcpServers(
  workspacePath?: string | null,
): Promise<McpSettingsPayload> {
  return invokeCommand("list_mcp_servers", {
    workspacePath: workspacePath ?? null,
  });
}

export function importMcpConfig(
  input: McpImportInput,
): Promise<McpSettingsPayload> {
  return invokeCommand("import_mcp_config", { input });
}

export function removeMcpServer(
  input: McpServerActionInput,
): Promise<McpSettingsPayload> {
  return invokeCommand("remove_mcp_server", { input });
}

export function reloadMcpServers(
  workspacePath?: string | null,
): Promise<McpSettingsPayload> {
  return invokeCommand("reload_mcp_servers", {
    workspacePath: workspacePath ?? null,
  });
}

export function loginMcpServer(
  input: McpServerActionInput,
): Promise<McpSettingsPayload> {
  return invokeCommand("login_mcp_server", { input });
}

export function logoutMcpServer(
  input: McpServerActionInput,
): Promise<McpSettingsPayload> {
  return invokeCommand("logout_mcp_server", { input });
}

export function updatePromptSettings(
  input: UpdatePromptSettingsInput,
): Promise<PromptSettings> {
  return invokeCommand("update_prompt_settings", { input });
}

export function startProviderAuth(
  input: StartProviderAuthInput,
): Promise<ProviderAuthSession> {
  return invokeCommand("start_provider_auth", { input });
}

export function completeProviderAuth(
  input: CompleteProviderAuthInput,
): Promise<ProviderSummary> {
  return invokeCommand("complete_provider_auth", { input });
}

export function removeProvider(
  input: RemoveProviderInput,
): Promise<ProviderSummary> {
  return invokeCommand("remove_provider", { input });
}

export function respondFollowup(
  response: FollowupResponse,
): Promise<SessionSnapshot> {
  return invokeCommand("respond_followup", { response });
}

export function archiveConversation(
  workspacePath: string,
  conversationId: string,
): Promise<SessionSnapshot> {
  return invokeCommand("archive_conversation", {
    workspacePath,
    conversationId,
  });
}

export function archiveWorkspace(
  workspacePath: string,
): Promise<SessionSnapshot> {
  return invokeCommand("archive_workspace", { workspacePath });
}

export function renameWorkspace(
  workspacePath: string,
  displayName?: string | null,
): Promise<SessionSnapshot> {
  return invokeCommand("rename_workspace", {
    workspacePath,
    displayName: displayName ?? null,
  });
}

export function cloneRepository(input: CloneRepositoryInput): Promise<string> {
  return invokeCommand("clone_repository", { input });
}

export function quickStartProject(
  input: QuickStartProjectInput,
): Promise<string> {
  return invokeCommand("quick_start_project", { input });
}

export function checkoutGitBranch(
  input: CheckoutGitBranchInput,
): Promise<RuntimeStatus> {
  return invokeCommand("checkout_git_branch", { input });
}

export function createGitBranch(
  input: CreateGitBranchInput,
): Promise<RuntimeStatus> {
  return invokeCommand("create_git_branch", { input });
}

export function commitGitChanges(
  input: CommitGitChangesInput,
): Promise<RuntimeStatus> {
  return invokeCommand("commit_git_changes", { input });
}

export function pushGitBranch(workspacePath: string): Promise<RuntimeStatus> {
  return invokeCommand("push_git_branch", { workspacePath });
}

export function openInTarget(
  workspacePath: string,
  targetId: string,
): Promise<void> {
  if (targetId !== FILE_MANAGER_TARGET_ID) {
    return Promise.reject(unsupportedOpenTargetError(targetId));
  }
  if (isQaMockMode) {
    void workspacePath;
    return Promise.resolve();
  }
  return merInvoke("open.path", { path: workspacePath });
}

export function openPathInTarget(
  workspacePath: string,
  targetId: string,
  path: string,
): Promise<void> {
  if (targetId !== FILE_MANAGER_TARGET_ID) {
    return Promise.reject(unsupportedOpenTargetError(targetId));
  }
  const resolvedPath = resolveWorkspacePath(workspacePath, path);
  if (isQaMockMode) {
    void resolvedPath;
    return Promise.resolve();
  }
  return merInvoke("open.path", { path: resolvedPath });
}

export function openExternalUrl(url: string): Promise<void> {
  if (isQaMockMode) {
    void url;
    return Promise.resolve();
  }
  if (!hasMerInvoke()) {
    openExternalInBrowser(url);
    return Promise.resolve();
  }
  return merInvoke("open.external", { url });
}

export function openPathDefault(path: string): Promise<void> {
  if (isQaMockMode) {
    void path;
    return Promise.resolve();
  }
  return merInvoke("open.path", { path });
}

export function openPathForEdit(path: string): Promise<void> {
  if (isQaMockMode) {
    void path;
    return Promise.resolve();
  }
  return merInvoke("open.path", { path });
}


export function closeWindow(): Promise<void> {
  if (isQaMockMode) {
    return Promise.resolve();
  }
  if (!hasMerInvoke()) {
    window.close();
    return Promise.resolve();
  }
  return merInvoke("window.close", {});
}

export function setWindowTitle(title: string): Promise<void> {
  if (isQaMockMode) {
    if (typeof document !== "undefined") {
      document.title = title;
    }
    return Promise.resolve();
  }
  if (!hasMerInvoke()) {
    if (typeof document !== "undefined") {
      document.title = title;
    }
    return Promise.resolve();
  }
  return merInvoke("window.setTitle", { title });
}

export function readWorkspaceFile(
  workspacePath: string,
  path: string,
): Promise<string> {
  return invokeCommand("read_workspace_file", { workspacePath, path });
}

export function saveConversationLayout(
  input: SaveConversationLayoutInput,
): Promise<void> {
  return invokeCommand("save_conversation_layout", { input });
}

export function getConversationLayout(
  conversationId: string,
): Promise<string | null> {
  return invokeCommand("get_conversation_layout", { conversationId });
}

export function createSavedWorkspace(
  input: CreateSavedWorkspaceInput,
): Promise<SavedWorkspaceDetail> {
  return invokeCommand("create_saved_workspace", { input });
}

export function updateSavedWorkspaceLayout(
  input: UpdateSavedWorkspaceLayoutInput,
): Promise<SavedWorkspaceDetail> {
  return invokeCommand("update_saved_workspace_layout", { input });
}

export function getSavedWorkspace(
  workspaceId: string,
): Promise<SavedWorkspaceDetail | null> {
  return invokeCommand("get_saved_workspace", { workspaceId });
}

export function renameSavedWorkspace(
  workspaceId: string,
  name: string,
): Promise<SessionSnapshot> {
  return invokeCommand("rename_saved_workspace", { workspaceId, name });
}

export function deleteSavedWorkspace(
  workspaceId: string,
): Promise<SessionSnapshot> {
  return invokeCommand("delete_saved_workspace", { workspaceId });
}

export function openTerminal(
  input: TerminalOpenInput,
): Promise<TerminalSession> {
  return invokeCommand("terminal_open", { input });
}

export function writeTerminal(input: TerminalWriteInput): Promise<void> {
  return invokeCommand("terminal_write", { input });
}

export function resizeTerminal(input: TerminalResizeInput): Promise<void> {
  return invokeCommand("terminal_resize", { input });
}

export function closeTerminal(input: TerminalCloseInput): Promise<void> {
  return invokeCommand("terminal_close", { input });
}

export async function listenSessionUpdates(
  handler: (payload: SessionSnapshot) => void,
): Promise<UnlistenFn> {
  return listenEvent(SESSION_UPDATED_EVENT_NAME, handler);
}

export async function listenMessageDeltas(
  handler: (payload: MessageDeltaEvent) => void,
): Promise<UnlistenFn> {
  return listenEvent(MESSAGE_DELTA_EVENT_NAME, handler);
}

export async function listenRequestFinished(
  handler: (payload: RequestLifecycleEvent) => void,
): Promise<UnlistenFn> {
  return listenEvent(REQUEST_FINISHED_EVENT_NAME, handler);
}

export async function listenRequestCancelled(
  handler: (payload: RequestLifecycleEvent) => void,
): Promise<UnlistenFn> {
  return listenEvent(REQUEST_CANCELLED_EVENT_NAME, handler);
}

export async function listenProviderOAuthCallback(
  handler: (payload: ProviderOAuthCallback) => void,
): Promise<UnlistenFn> {
  return listenEvent(PROVIDER_OAUTH_CALLBACK_EVENT_NAME, handler);
}

function matchesTerminalEvent(
  payload: { terminalId: string; terminalInstanceId?: string },
  terminalId: string,
  terminalInstanceId?: string | null,
): boolean {
  if (payload.terminalId !== terminalId) return false;
  if (terminalInstanceId == null) return true;
  return payload.terminalInstanceId === terminalInstanceId;
}

export async function listenTerminalOutput(
  terminalId: string,
  handler: (payload: TerminalOutputEvent) => void,
  terminalInstanceId?: string | null,
): Promise<UnlistenFn> {
  return listenEvent(
    TERMINAL_OUTPUT_EVENT_NAME,
    (payload: TerminalOutputEvent) => {
      if (matchesTerminalEvent(payload, terminalId, terminalInstanceId)) {
        handler(payload);
      }
    },
  );
}

export async function listenTerminalExit(
  terminalId: string,
  handler: (payload: TerminalExitEvent) => void,
  terminalInstanceId?: string | null,
): Promise<UnlistenFn> {
  return listenEvent(TERMINAL_EXIT_EVENT_NAME, (payload: TerminalExitEvent) => {
    if (matchesTerminalEvent(payload, terminalId, terminalInstanceId)) {
      handler(payload);
    }
  });
}

export async function listenTerminalErrors(
  terminalId: string,
  handler: (payload: TerminalErrorEvent) => void,
  terminalInstanceId?: string | null,
): Promise<UnlistenFn> {
  return listenEvent(
    TERMINAL_ERROR_EVENT_NAME,
    (payload: TerminalErrorEvent) => {
      if (matchesTerminalEvent(payload, terminalId, terminalInstanceId)) {
        handler(payload);
      }
    },
  );
}
