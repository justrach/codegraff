// Transport: the codegraff GUI backend is a merjs/Zig HTTP server served by
// the native shell. Commands go over fetch POST /api/<command>; OS-level shell
// ops go through window.mer.invoke when that bridge exists. Push events arrive
// over a single SSE EventSource on /events.
import type { UnlistenFn } from "@tauri-apps/api/event";

import {
  SESSION_UPDATED_EVENT_NAME,
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

const QA_WORKSPACE_PATH = "/Users/pranavp/projects/harness/codegraff/gui";
const QA_CONVERSATION_ID = "qa-existing-chat";
// Browser-based visual QA cannot call Tauri commands, so this flag swaps the
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
        activeRequestIds: [],
        conversationId: activeConversationId ?? QA_CONVERSATION_ID,
        followup: null,
        messages: activeConversationId == null ? existingMessages : messages,
        requestAgentIds: {},
        todos: [],
        workspacePath: QA_WORKSPACE_PATH,
      },
    ],
    savedWorkspaces: [],
    uiError: null,
    visibleActiveRequestIds: [],
    visibleFollowup: null,
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
        contextLength: 200000n,
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
    availableOpenTargets: ["vscode", "terminal"],
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
      return { body: "| Field | Value |\n|---|---|\n| Workspace | Codegraff GUI |\n| Branch | qa/mock-browser |\n| Indexed nodes | 1,284 |", payload: { createdAt: "2026-06-03T00:00:00Z", kind: "workspaceInfo", lastUpdated: "2026-06-03T12:00:00Z", nodeCount: 1284n, relationCount: 642n, workingDir: QA_WORKSPACE_PATH, workspaceId: "qa-codegraff-gui", workspacePath: QA_WORKSPACE_PATH }, resultKind: "workspaceInfo", savedPath: null, snapshot: null, title };
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
      return Promise.resolve(createQaSnapshot(conversationId, [
        { id: `${conversationId}-user`, kind: "user", requestId: `${conversationId}-request`, text: input.prompt },
        { id: `${conversationId}-assistant`, kind: "assistant", requestId: `${conversationId}-request`, text: "QA mock response with a bullet list:\n\n- Markdown bullets align correctly.\n- `inline code` stays readable.\n\n```ts\nconst theme = 'clean-modern';\n```\n\n[Codegraff](https://github.com/justrach/codegraff)" },
      ]) as T);
    }
    case "read_workspace_file":
      return Promise.resolve("// QA mock file contents\nexport const value = 1;\n" as T);
    case "list_mcp_servers":
      return Promise.resolve({ servers: [] } as T);
    case "pick_workspace":
    case "pick_directory":
      return Promise.resolve(QA_WORKSPACE_PATH as T);
    default:
      return Promise.resolve(undefined as T);
  }
}

const NATIVE_COMMANDS: Record<string, string> = {
  pick_workspace: "dialog.pickDirectory",
  pick_directory: "dialog.pickDirectory",
  drain_pending_open: "drainPendingOpen",
  open_path_default: "open.path",
  open_path_for_edit: "open.path",
  open_in_target: "open.path",
  open_path_in_target: "open.path",
};

async function httpInvoke<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(`/api/${command}`, {
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
    throw new Error(`${command} failed: ${res.status} ${text}`);
  }
  return res.json() as Promise<T>;
}

async function merInvoke<T>(
  name: string,
  args?: Record<string, unknown>,
): Promise<T> {
  const w = window as unknown as {
    mer?: { invoke?: (n: string, a: unknown) => Promise<T> };
  };
  if (w.mer?.invoke) {
    try {
      return await w.mer.invoke(name, args ?? {});
    } catch (error) {
      if (name === "open.external") {
        const url = typeof args?.url === "string" ? args.url : null;
        if (url != null) {
          window.open(url, "_blank", "noopener,noreferrer");
        }
        return null as T;
      }
      if (name.startsWith("open.") || name === "drainPendingOpen") {
        return null as T;
      }
      throw error;
    }
  }
  if (name === "open.external") {
    const url = typeof args?.url === "string" ? args.url : null;
    if (url != null) {
      window.open(url, "_blank", "noopener,noreferrer");
    }
  }
  return null as T;
}

function invokeCommand<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  if (isQaMockMode) {
    return mockInvokeCommand<T>(command, args);
  }
  const nativeName = NATIVE_COMMANDS[command];
  if (nativeName) {
    return merInvoke<T>(nativeName, args);
  }
  return httpInvoke<T>(command, args);
}

let sessionEventSource: EventSource | null = null;
const sessionUpdatedHandlers = new Set<(payload: unknown) => void>();

function ensureSessionEventSource(): EventSource {
  if (sessionEventSource) {
    return sessionEventSource;
  }
  const es = new EventSource("/events");
  sessionEventSource = es;
  es.addEventListener("session-updated", (event: MessageEvent) => {
    try {
      const payload = JSON.parse(event.data);
      for (const handler of sessionUpdatedHandlers) {
        handler(payload);
      }
    } catch {
      // Ignore malformed frames; EventSource will continue reconnecting.
    }
  });
  return es;
}

async function listenEvent<T>(
  eventName: string,
  handler: (payload: T) => void,
): Promise<UnlistenFn> {
  if (isQaMockMode) {
    // Event streams are Tauri-only; visual QA drives state through mock command
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
      if (sessionUpdatedHandlers.size === 0 && sessionEventSource != null) {
        sessionEventSource.close();
        sessionEventSource = null;
      }
    };
  }

  void handler;
  return () => undefined;
}

export function pickWorkspace(): Promise<string | null> {
  return invokeCommand("pick_workspace");
}

export function pickDirectory(title?: string): Promise<string | null> {
  return invokeCommand("pick_directory", { title });
}

export function openWorkspace(path: string): Promise<SessionSnapshot> {
  return invokeCommand("open_workspace", { path });
}

// Drains a path passed to `codegraff <path>` before the app launched (cold start).
export function drainPendingOpen(): Promise<string | null> {
  return invokeCommand("drain_pending_open");
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
  return invokeCommand("open_in_target", { workspacePath, targetId });
}

export function openPathInTarget(
  workspacePath: string,
  targetId: string,
  path: string,
): Promise<void> {
  return invokeCommand("open_path_in_target", { workspacePath, targetId, path });
}

export function openExternalUrl(url: string): Promise<void> {
  return invokeCommand("open_external_url", { url });
}

export function openPathDefault(path: string): Promise<void> {
  return invokeCommand("open_path_default", { path });
}

export function openPathForEdit(path: string): Promise<void> {
  return invokeCommand("open_path_for_edit", { path });
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

export async function listenProviderOAuthCallback(
  handler: (payload: ProviderOAuthCallback) => void,
): Promise<UnlistenFn> {
  return listenEvent(PROVIDER_OAUTH_CALLBACK_EVENT_NAME, handler);
}

export async function listenTerminalOutput(
  terminalId: string,
  handler: (payload: TerminalOutputEvent) => void,
): Promise<UnlistenFn> {
  return listenEvent(
    TERMINAL_OUTPUT_EVENT_NAME,
    (payload: TerminalOutputEvent) => {
      if (payload.terminalId === terminalId) {
        handler(payload);
      }
    },
  );
}

export async function listenTerminalExit(
  terminalId: string,
  handler: (payload: TerminalExitEvent) => void,
): Promise<UnlistenFn> {
  return listenEvent(TERMINAL_EXIT_EVENT_NAME, (payload: TerminalExitEvent) => {
    if (payload.terminalId === terminalId) {
      handler(payload);
    }
  });
}

export async function listenTerminalErrors(
  terminalId: string,
  handler: (payload: TerminalErrorEvent) => void,
): Promise<UnlistenFn> {
  return listenEvent(
    TERMINAL_ERROR_EVENT_NAME,
    (payload: TerminalErrorEvent) => {
      if (payload.terminalId === terminalId) {
        handler(payload);
      }
    },
  );
}
