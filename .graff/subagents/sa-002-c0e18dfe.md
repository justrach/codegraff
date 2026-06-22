# subagent sa-002-c0e18dfe

- label: workflow progress mapping
- kind: workflow_task
- status: ok
- elapsed_ms: 535819
- tools: codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,bash!,bash!,bash!,bash!,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb

## task

Inspect whether the repo has structured workflow/ultracode progress events similar to a mappable task UI/progress card. Use codedb first. Search for workflow events, task progress, ChatWorkRow, activity/work rows, NDJSON events, and serve/json protocol handling. Report whether ultracode workflow progress is represented as structured events or only as tool calls/text/logs. Include file references. Do not modify files.

## report

## Bottom line

**Verified:** the repo has UI concepts that *could* display task/progress cards, but the actual `graff --json` / `graff serve` event protocol does **not** expose structured workflow/ultracode progress events such as phases, tasks, per-subagent lifecycle, or a live agent tree. Workflow/ultracode progress is represented primarily as:

1. generic `tool_call` / `tool_result` events,
2. assistant text / reasoning,
3. TUI/stderr/log/trace/telemetry documentation,
4. GUI-derived generic “work rows” grouped from tool start/end messages.

So: **not a first-class structured workflow progress stream suitable for directly mapping to a rich task UI/progress card.**

---

## What I verified

### 1. The SDK / serve event protocol is generic, not workflow-progress structured

The TypeScript SDK defines the full event union as `text`, `tool_call`, `ask_user`, `tool_result`, `turn`, `system_prompt`, `score`, and `error`; there is no `workflow_started`, `workflow_phase`, `task_started`, `task_completed`, `subagent_started`, or similar event type. `workflow` exists only as a tool name in the tool list, not as a distinct event model. `sdk/ts/harness.ts:14`, `sdk/ts/harness.ts:17-31`

The remote HTTP client uses the same contract: it says serve streams the same `--json` contract as NDJSON, and its event union is the same generic set. `sdk/ts/remote.ts:3-8`, `sdk/ts/remote.ts:16-28`

The remote client parses each NDJSON line as an `Event`, and a chat terminates only on `turn` or `error`; unknown events pass through but are not modeled. `sdk/ts/remote.ts:69-89`, `sdk/ts/remote.ts:149-157`

The Python SDK README also summarizes the protocol as JSONL events: `text`, `tool_call`, `ask_user`, `tool_result`, `turn`, and `error`; no workflow-progress event types are documented. `sdk/README.md:101-107`

`graff serve` is documented as putting the same protocol on HTTP: each session is a `graff --json` child, one non-answer POST is one protocol request, and the response streams NDJSON events until the terminal event. `README.md:739-744`

**Conclusion:** serve/NDJSON protocol handling is structured at the generic agent-event level, but **not at workflow/ultracode progress-card granularity**.

---

### 2. `ultracode` is documented as prompt steering + trace/logging, not a structured event stream

The README describes `ultracode` as a codeword: if present in a message, the harness prints a banner, records an `ultracode` trace event, and asks the model to fan work out through the `workflow` tool. `README.md:550-556`

Architecture docs say the same thing more explicitly: `main()` scans user input for `ultracode`, prints a banner, emits an `ultracode` trace note, and appends steering text telling the model to use `workflow`; it is “pure prompt-augmentation” with “no new control flow.” `architecture.md:356-363`

**Conclusion:** ultracode is not represented as a dedicated protocol event in the SDK/serve contract; it is a per-turn prompt augmentation plus trace/log signal.

---

### 3. Workflow exists as a tool, not as structured progress events

The README’s tools table lists `workflow` as a built-in tool: “phases of parallel subagents; `{{prev}}` carries results forward.” `README.md:465-467`

The workflow docs describe the model calling the `workflow` tool with a JSON plan: up to five sequential phases, each with up to eight parallel tasks, with previous phase results carried into later tasks. `README.md:558-564`

The architecture docs describe `workflow` as a built-in tool executed through the same tool machinery as other built-ins. `architecture.md:160-168`

In the GUI adapter’s protocol mapping, a `tool_call` named `"workflow"` is converted into a generic `ToolCallDetailDto::Task` with `label: "workflow"` and empty `agent_id`; no phases/tasks/progress fields are extracted. `gui/src-tauri/src/runtime/simple.rs:2736-2743`

**Conclusion:** the repo knows about the workflow tool, but the GUI mapping collapses it to a generic “task/tool” row rather than a structured workflow graph/progress model.

---

### 4. The Tauri GUI has generic work/activity rows, but they are built from transcript tool messages

The chat thread model has a `request_work` item with `activities`, `isRunning`, `hasError`, and `failedStepCount`. `gui/src/components/chat/types/chatThread.ts:44-58`

Each activity has `summary`, `operations`, `isRunning`, `isThinking`, `hasError`, and optional reasoning text. `gui/src/components/chat/types/chatThread.ts:21-31`

`buildChatThreadItems` constructs these work rows from transcript messages by grouping `reasoning`, `tool_start`, `status`, `status_output`, and `tool_end` messages. `gui/src/components/chat/utils/chatThread.ts:164-294`

The resulting work item is only created when there are activities or an active request, and its failure/running state is derived from grouped activity rows. `gui/src/components/chat/utils/chatThread.ts:313-331`

`ChatWorkRow` renders a collapsible work group with a spinner if running and a failed-step count via its label logic. `gui/src/components/chat/ChatWorkRow.tsx:14-33`, `gui/src/components/chat/ChatWorkRow.tsx:37-75`

`ChatActivityRow` renders each grouped activity with icons for generic operation kinds including file reads, shell commands, search, fetch, task, todo, etc. `gui/src/components/chat/ChatActivityRow.tsx:66-98`, `gui/src/components/chat/ChatActivityRow.tsx:180-260`

The summary builder counts operations and reports broad categories such as “N subagents,” “Explored N files,” “Ran N commands,” etc.; it does not model workflow phases or node dependencies. `gui/src/components/chat/utils/chatThread.ts:546-605`

**Conclusion:** the GUI has a **generic mappable activity/work-row UI**, but it is reconstructed from generic transcript messages, not from dedicated workflow progress events.

---

### 5. Tauri backend translates JSONL events into generic transcript messages only

The Tauri runtime sends a user line to the persistent `graff --json` session as `{"type":"user","text":prompt}`. `gui/src-tauri/src/runtime/simple.rs:572-586`

It reads stdout line by line, parses JSON, and matches on `event.type`. `gui/src-tauri/src/runtime/simple.rs:595-621`

Handled event types include `text`, `reasoning`, `tool_call`, `ask_user`, `tool_result`, `turn`, and `error`. `gui/src-tauri/src/runtime/simple.rs:621-855`

For `tool_call`, it creates a `SessionMessageDto::ToolStart` with a `ToolCallDetailDto`. `gui/src-tauri/src/runtime/simple.rs:704-758`

For `tool_result`, it creates a `SessionMessageDto::ToolEnd` with optional text result detail. `gui/src-tauri/src/runtime/simple.rs:796-832`

For unrecognized events and `system_prompt` / `score` acks, it ignores them. `gui/src-tauri/src/runtime/simple.rs:853-854`

The session message enum itself has only generic variants: user, assistant, reasoning, status, status output, tool start, tool end, and error. `gui/src-tauri/src/dto/session.rs:13-79`

**Conclusion:** the desktop GUI backend would currently ignore any unknown future workflow-specific event unless explicitly added, and today it only translates workflow into generic tool start/end messages.

---

### 6. There is a task/todo UI shape, but it is not wired to live workflow progress in the Tauri backend

The session DTO includes todo types: `SessionTodoStatusDto` with `Pending`, `InProgress`, `Completed`, and `Cancelled`, and `SessionTodoDto` with `id`, `content`, and `status`. `gui/src-tauri/src/dto/session.rs:81-98`

The snapshot DTO includes `visible_todos`, and each conversation view includes `todos`. `gui/src-tauri/src/dto/session.rs:120-131`, `gui/src-tauri/src/dto/session.rs:173-188`

However, the runtime snapshot currently sets `visible_todos: vec![]`. `gui/src-tauri/src/runtime/simple.rs:1935-1948`

Each conversation view also sets `todos: vec![]`. `gui/src-tauri/src/runtime/simple.rs:2265-2276`

The React `SessionTodoDock` can render a task-plan card, with active/busy state, completed counts, and todo status icons. `gui/src/components/conversation-panel/SessionTodoDock.tsx:36-56`, `gui/src/components/conversation-panel/SessionTodoDock.tsx:79-118`, `gui/src/components/conversation-panel/SessionTodoDock.tsx:124-150`

But its summary is derived from supplied todos, and the backend currently supplies none. `gui/src/components/conversation-panel/utils/sessionTodo.ts:5-29`, `gui/src-tauri/src/runtime/simple.rs:1947`, `gui/src-tauri/src/runtime/simple.rs:2275`

**Conclusion:** the GUI has a task-plan card component, but live Tauri snapshots do not populate it from workflow/todo events.

---

### 7. The iOS app has a visible “Task progress” card, but it is app-state/static, not driven by structured workflow events

The iOS `ChatView` always renders `TaskProgressCard(session:)` above messages. `apps/ios/Graff/Sources/ChatView.swift:13-17`

`TaskProgressCard` displays `session.progress.done/total` and iterates `session.todos`, with in-progress pulse animation. `apps/ios/Graff/Sources/ChatView.swift:106-133`

The iOS serve client decodes NDJSON into `GraffEvent` cases: `reasoning`, `text`, `toolCall(name:)`, `turn`, `error`, and `other`; no workflow phase/task progress cases exist. `apps/ios/Graff/Sources/GraffServeClient.swift:3-11`, `apps/ios/Graff/Sources/GraffServeClient.swift:82-95`

During streaming, iOS appends reasoning/text and final turn text; it explicitly ignores `.toolCall` and `.other`. `apps/ios/Graff/Sources/ChatView.swift:83-95`

**Conclusion:** iOS has a progress-card UI, but serve events do not drive it; tool calls are ignored in the current live stream handler.

---

### 8. Workflow draft/review is structured, but that is a slash-command modal, not runtime progress

The command DTO has a structured `WorkflowDraftPayloadDto` with `goal`, `summary`, `nodes`, `export_text`, `approved_prompt`, and `trace`. `gui/src-tauri/src/dto/command.rs:279-296`

The command result payload enum includes `WorkflowDraft`. `gui/src-tauri/src/dto/command.rs:352-373`

The command dialog renders workflow draft nodes as cards and provides an approve button. `gui/src/components/CommandResultDialog.tsx:33-36`, `gui/src/components/CommandResultDialog.tsx:64-73`, `gui/src/components/CommandResultDialog.tsx:131-150`

But the Tauri runtime’s `build_workflow_draft` is a placeholder returning empty nodes and a stub summary. `gui/src-tauri/src/runtime/simple.rs:1251-1263`

**Conclusion:** there is structured workflow-*draft* UI data, but it is not live ultracode/workflow execution progress.

---

## What I infer

1. **A progress-card UI could be built on top of the existing generic ChatWorkRow/ChatActivityRow system**, because it already groups tool calls, reasoning, running state, and errors. But today that grouping is lossy for workflow: `workflow` becomes a generic `task` operation with label `"workflow"`, not a phase/task tree. Evidence: generic grouping in `buildChatThreadItems`; workflow mapping to `ToolCallDetailDto::Task`. `gui/src/components/chat/utils/chatThread.ts:164-331`, `gui/src-tauri/src/runtime/simple.rs:2740-2743`

2. **To support a mappable ultracode/workflow progress card, the protocol would need new structured events or richer `tool_call`/`tool_result` payload conventions** for workflow phase/task lifecycle. Today the protocol event union has no such events. `sdk/ts/harness.ts:23-31`, `sdk/ts/remote.ts:20-28`

3. **The intended source of truth appears to be the TUI harness / `graff --json` protocol, not separate GUI-only state.** AGENTS.md says the TUI harness is the source of truth and the GUI/app should consume the same events. `AGENTS.md:26-36`

---

## Answer to the core question

**Does the repo have structured workflow/ultracode progress events similar to a mappable task UI/progress card?**

**No, not in the current verified protocol/GUI path.**

It has:

- generic `tool_call` / `tool_result` / `text` / `reasoning` events, not workflow-specific progress events. `sdk/ts/harness.ts:23-31`, `sdk/ts/remote.ts:20-28`
- a `workflow` tool name and documentation for multi-agent phases/tasks, but not a structured event model for those phases/tasks. `README.md:558-564`, `architecture.md:160-168`
- generic GUI work/activity rows reconstructed from transcript messages. `gui/src/components/chat/utils/chatThread.ts:164-331`
- a task/todo dock component and iOS progress card UI, but Tauri snapshots currently provide empty todos and iOS ignores live tool calls. `gui/src-tauri/src/runtime/simple.rs:1947`, `gui/src-tauri/src/runtime/simple.rs:2275`, `apps/ios/Graff/Sources/ChatView.swift:83-95`

So workflow/ultracode progress is currently represented as **tool calls, text/reasoning, logs/trace/telemetry**, and generic activity rows — **not as first-class structured progress events**.

---

## 3 most load-bearing facts

1. The event protocol union has no workflow/task-progress event types; it only defines generic events like `text`, `tool_call`, `tool_result`, `turn`, and `error. `sdk/ts/harness.ts:23-31`

2. The Tauri runtime converts JSONL `tool_call` / `tool_result` into generic `ToolStart` / `ToolEnd` transcript messages and ignores unrecognized event types. `gui/src-tauri/src/runtime/simple.rs:704-758`, `gui/src-tauri/src/runtime/simple.rs:796-854`

3. The GUI’s todo/task-plan data path is present but currently unpopulated by the runtime: `visible_todos` and conversation `todos` are both `vec![]`. `gui/src-tauri/src/runtime/simple.rs:1935-1948`, `gui/src-tauri/src/runtime/simple.rs:2265-2276`

## Open question

The docs reference `src/main.zig` as the harness source of truth and mention per-subagent TUI rendering, but the indexed repo tree only shows `src/mcp.zig`; the current checked/indexed contents do not let me verify whether `src/main.zig` already emits richer workflow/subagent events on another branch or in an unindexed/missing file.
