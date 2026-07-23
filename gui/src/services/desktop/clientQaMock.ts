import type {
  AgentsPayload,
  CommandDescriptor,
  CommandRunResult,
  PromptSettings,
  RuntimeStatus,
  SendPromptInput,
  SessionSnapshot,
  UpdatePromptSettingsInput,
} from "./types/contracts";

const QA_WORKSPACE_PATH = "/Users/pranavp/projects/harness/codegraff/gui";
const QA_CONVERSATION_ID = "qa-existing-chat";

export const isQaMockMode =
  import.meta.env.VITE_CODEGRAFF_QA_MOCK === "1";

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

export function mockInvokeCommand<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
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
