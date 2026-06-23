const std = @import("std");
const builtin = @import("builtin");
const mer = @import("mer");
const mer_runtime = @import("runtime");
const pty = @import("pty");

const log = std.log.scoped(.backend);
const Value = std.json.Value;
const default_reasoning_effort = "medium";
const session_ext = ".session.json";
const terminal_scrollback_limit = 1024 * 1024;
const sse_event_replay_limit = 1000;
const session_scan_cache_ttl_ms = 10_000;
const runtime_status_cache_ttl_ms = 10_000;
const protocol_warning_limit_per_turn = 5;

pub var instance: ?*Runtime = null;

const Message = struct {
    kind: Kind,
    id: []const u8,
    request_id: []const u8,
    text: []const u8 = "",
    name: []const u8 = "",
    call_id: ?[]const u8 = null,
    question: []const u8 = "",
    summary: ?[]const u8 = null,
    title: []const u8 = "",
    subtitle: ?[]const u8 = null,
    category: []const u8 = "info",
    is_error: bool = false,
    error_message: []const u8 = "",
    tool_detail_json: ?[]const u8 = null,
    result_detail_json: ?[]const u8 = null,

    const Kind = enum {
        user,
        context_compacted,
        assistant,
        reasoning,
        status,
        status_output,
        tool_start,
        tool_end,
        @"error",
    };
};

const Conversation = struct {
    workspace_path: []const u8,
    conversation_id: []const u8,
    session_name: []const u8,
    title: []const u8,
    messages: std.ArrayList(Message) = .empty,
    active_request_ids: std.ArrayList([]const u8) = .empty,
    active_agent_id: ?[]const u8 = null,
    plan_mode: bool = false,
    goal: ?[]const u8 = null,
    updated_at: i64 = 0,
    followup: ?Followup = null,
    session_provider: ?[]const u8 = null,
    session_model: ?[]const u8 = null,
    session_strict: bool = false,
    session_ultracode_mode: bool = false,
    cli_messages_json: ?[]const u8 = null,
};

const FollowupOption = struct {
    id: []const u8,
    label: []const u8,
};

const Followup = struct {
    followup_id: []const u8,
    workspace_path: []const u8,
    conversation_id: []const u8,
    request_id: []const u8,
    kind: []const u8 = "text",
    question: []const u8,
    options: []const FollowupOption = &.{},
    call_id: ?[]const u8,
};

const Workspace = struct {
    path: []const u8,
    kind: []const u8 = "project",
    display_name: ?[]const u8 = null,
};

const PromptSettings = struct {
    selected_provider: ?[]const u8 = null,
    selected_model: ?[]const u8 = null,
    selected_effort: ?[]const u8 = null,
    fast_enabled: bool = false,
};

const TerminalSessionState = struct {
    terminal_id: []const u8,
    instance_id: []const u8,
    workspace_path: []const u8,
    cwd: []const u8,
    shell: []const u8,
    cols: u16,
    rows: u16,
    proc: pty.PtyProcess,
    scrollback: std.ArrayList(u8) = .empty,
    scrollback_truncated: bool = false,
    output_seq: u64 = 0,
    utf8_pending: [4]u8 = undefined,
    utf8_pending_len: usize = 0,
    io_mutex: std.Io.Mutex = .init,
    closing: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
};

const GraffSession = struct {
    conversation_id: []const u8,
    workspace_path: []const u8,
    session_name: []const u8,
    desired_provider: ?[]const u8 = null,
    desired_model: ?[]const u8 = null,
    acked_provider: ?[]const u8 = null,
    acked_model: ?[]const u8 = null,
    acked_effort: ?[]const u8 = null,
    acked_fast: ?bool = null,
    acked_agent: ?[]const u8 = null,
    acked_mode: ?[]const u8 = null,
    child: *std.process.Child,
    yolo_enabled: bool = false,
    stdin_mutex: std.Io.Mutex = .init,
};

const SseEvent = struct {
    seq: u64,
    name: []const u8,
    data: []const u8,
};

const RuntimeStatusCacheEntry = struct {
    json: []const u8,
    expires_ms: i64,
};

const SessionScanCacheEntry = struct {
    scanned_ms: i64,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    version: std.atomic.Value(u64) = .init(1),
    workspaces: std.ArrayList(Workspace) = .empty,
    conversations: std.StringHashMap(*Conversation),
    selected_by_workspace: std.StringHashMap([]const u8),
    terminals: std.StringHashMap(*TerminalSessionState),
    active_children: std.StringHashMap(*std.process.Child),
    graff_sessions: std.StringHashMap(*GraffSession),
    runtime_status_cache: std.StringHashMap(RuntimeStatusCacheEntry),
    runtime_status_generation: u64 = 0,
    session_scan_cache: std.StringHashMap(SessionScanCacheEntry),
    event_mutex: std.Io.Mutex = .init,
    events: std.ArrayList(SseEvent) = .empty,
    next_event_seq: u64 = 1,
    active_workspace_path: ?[]const u8 = null,
    active_conversation_id: ?[]const u8 = null,
    active_agent_id: []const u8 = "forge",
    gui_state_loaded: bool = false,
    settings_loaded: bool = false,
    settings: PromptSettings = .{},
    schema_loaded: bool = false,
    schema_raw: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) !*Runtime {
        const rt = try allocator.create(Runtime);
        rt.* = .{
            .allocator = allocator,
            .arena_state = .init(allocator),
            .arena = undefined,
            .conversations = std.StringHashMap(*Conversation).init(allocator),
            .selected_by_workspace = std.StringHashMap([]const u8).init(allocator),
            .terminals = std.StringHashMap(*TerminalSessionState).init(allocator),
            .active_children = std.StringHashMap(*std.process.Child).init(allocator),
            .graff_sessions = std.StringHashMap(*GraffSession).init(allocator),
            .runtime_status_cache = std.StringHashMap(RuntimeStatusCacheEntry).init(allocator),
            .session_scan_cache = std.StringHashMap(SessionScanCacheEntry).init(allocator),
        };
        rt.arena = rt.arena_state.allocator();
        instance = rt;
        log.info("backend runtime initialized", .{});
        return rt;
    }

    pub fn deinit(self: *Runtime) void {
        var it = self.terminals.valueIterator();
        while (it.next()) |session| closeTerminalSession(session.*);
        self.terminals.deinit();
        var graff_it = self.graff_sessions.valueIterator();
        while (graff_it.next()) |session| self.closeGraffSession(session.*);
        self.graff_sessions.deinit();
        self.active_children.deinit();
        var cache_it = self.runtime_status_cache.iterator();
        while (cache_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.json);
        }
        self.runtime_status_cache.deinit();
        var scan_it = self.session_scan_cache.iterator();
        while (scan_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.session_scan_cache.deinit();
        for (self.events.items) |event| self.freeSseEvent(event);
        self.events.deinit(self.allocator);
        self.conversations.deinit();
        self.selected_by_workspace.deinit();
        self.arena_state.deinit();
        self.allocator.destroy(self);
        instance = null;
    }

    pub fn handleApi(self: *Runtime, req: mer.Request) mer.Response {
        if (req.method != .POST) return mer.Response.init(.method_not_allowed, .json, "{\"error\":\"method not allowed\"}");
        self.ensureGuiStateLoaded();
        const cmd = commandName(req.path);

        if (std.mem.eql(u8, cmd, "get_session_snapshot")) {
            self.mutex.lockUncancelable(mer_runtime.io);
            self.refreshWorkspaceSessionsLocked(false);
            self.mutex.unlock(mer_runtime.io);
            return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
        }
        if (std.mem.eql(u8, cmd, "open_workspace")) return self.openWorkspace(req);
        if (std.mem.eql(u8, cmd, "get_runtime_status")) return self.getRuntimeStatus(req);
        if (std.mem.eql(u8, cmd, "get_prompt_settings")) return self.getPromptSettings(req);
        if (std.mem.eql(u8, cmd, "update_prompt_settings")) return self.updatePromptSettings(req);
        if (std.mem.eql(u8, cmd, "get_theme_settings")) return self.getThemeSettings(req);
        if (std.mem.eql(u8, cmd, "update_theme_settings")) return self.updateThemeSettings(req);
        if (std.mem.eql(u8, cmd, "list_providers")) return self.listProviders(req);
        if (std.mem.eql(u8, cmd, "list_commands")) return mer.json(commands_json);
        if (std.mem.eql(u8, cmd, "select_conversation") or std.mem.eql(u8, cmd, "ensure_conversation_view")) return self.selectConversation(req);
        if (std.mem.eql(u8, cmd, "start_new_chat")) return self.startNewChat(req);
        if (std.mem.eql(u8, cmd, "create_managed_chat")) return self.createManagedChat(req);
        if (std.mem.eql(u8, cmd, "handoff_chat")) return self.handoffChat(req);
        if (std.mem.eql(u8, cmd, "send_prompt")) return self.sendPrompt(req);
        if (std.mem.eql(u8, cmd, "stop_prompt")) return self.stopPrompt(req);
        if (std.mem.eql(u8, cmd, "compact_conversation")) return self.compactConversation(req);
        if (std.mem.eql(u8, cmd, "respond_followup")) return self.respondFollowup(req);
        if (std.mem.eql(u8, cmd, "archive_conversation")) return self.archiveConversation(req);
        if (std.mem.eql(u8, cmd, "archive_workspace")) return self.archiveWorkspace(req);
        if (std.mem.eql(u8, cmd, "rename_workspace")) return self.renameWorkspace(req);
        if (std.mem.eql(u8, cmd, "run_slash_command")) return self.runSlashCommand(req);
        if (std.mem.eql(u8, cmd, "workspace_sync")) return self.workspaceSync(req);
        if (std.mem.eql(u8, cmd, "workspace_query")) return self.workspaceQuery(req);
        if (std.mem.eql(u8, cmd, "build_workflow_draft")) return self.buildWorkflowDraft(req);
        if (std.mem.eql(u8, cmd, "export_workflow_draft")) return self.exportWorkflowDraft(req);
        if (std.mem.eql(u8, cmd, "set_active_agent")) return self.setActiveAgent(req);
        if (std.mem.eql(u8, cmd, "set_effort")) return self.setEffort(req);
        if (std.mem.eql(u8, cmd, "set_fast")) return self.setFast(req);
        if (std.mem.eql(u8, cmd, "list_mcp_servers") or std.mem.eql(u8, cmd, "reload_mcp_servers")) return self.listMcpServers(req);
        if (std.mem.eql(u8, cmd, "import_mcp_config")) return self.importMcpConfig(req);
        if (std.mem.eql(u8, cmd, "remove_mcp_server")) return self.removeMcpServer(req);
        if (std.mem.eql(u8, cmd, "login_mcp_server") or std.mem.eql(u8, cmd, "logout_mcp_server")) return mer.Response.init(.bad_request, .json, "{\"error\":\"graff runs stdio MCP servers only; OAuth login/logout does not apply\"}");
        if (std.mem.eql(u8, cmd, "start_provider_auth")) return self.startProviderAuth(req);
        if (std.mem.eql(u8, cmd, "complete_provider_auth")) return self.completeProviderAuth(req);
        if (std.mem.eql(u8, cmd, "remove_provider")) return self.removeProvider(req);
        if (std.mem.eql(u8, cmd, "read_workspace_file")) return self.readWorkspaceFile(req);
        if (std.mem.eql(u8, cmd, "save_pasted_image")) return self.savePastedImage(req);
        if (std.mem.eql(u8, cmd, "save_attachment_file")) return self.saveAttachmentFile(req);
        if (std.mem.eql(u8, cmd, "image_thumbnail")) return mer.Response.init(.bad_request, .json, "{\"error\":\"image thumbnails are not supported by the Zig backend yet\"}");
        if (std.mem.eql(u8, cmd, "terminal_open")) return self.terminalOpen(req);
        if (std.mem.eql(u8, cmd, "terminal_write")) return self.terminalWrite(req);
        if (std.mem.eql(u8, cmd, "terminal_resize")) return self.terminalResize(req);
        if (std.mem.eql(u8, cmd, "terminal_close")) return self.terminalClose(req);
        if (std.mem.eql(u8, cmd, "save_conversation_layout")) return self.saveConversationLayout(req);
        if (std.mem.eql(u8, cmd, "get_conversation_layout")) return mer.json("null");
        if (std.mem.eql(u8, cmd, "create_saved_workspace")) return self.createSavedWorkspace(req);
        if (std.mem.eql(u8, cmd, "update_saved_workspace_layout")) return self.createSavedWorkspace(req);
        if (std.mem.eql(u8, cmd, "get_saved_workspace")) return mer.json("null");
        if (std.mem.eql(u8, cmd, "rename_saved_workspace") or std.mem.eql(u8, cmd, "delete_saved_workspace")) return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
        if (std.mem.eql(u8, cmd, "checkout_git_branch") or std.mem.eql(u8, cmd, "create_git_branch") or std.mem.eql(u8, cmd, "commit_git_changes") or std.mem.eql(u8, cmd, "push_git_branch")) return self.gitMutation(req, cmd);
        if (std.mem.eql(u8, cmd, "clone_repository") or std.mem.eql(u8, cmd, "quick_start_project")) return mer.Response.init(.bad_request, .json, "{\"error\":\"repository creation is not implemented in the Zig backend yet\"}");

        return mer.Response.init(.not_found, .json, "{\"error\":\"unknown api command\"}");
    }

    fn jsonResponse(_: *Runtime, _: mer.Request, body: []const u8) mer.Response {
        return mer.Response.init(.ok, .json, body);
    }

    fn openWorkspace(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const path = stringField(root, "path") orelse return bad(req, "missing path");
        self.mutex.lockUncancelable(mer_runtime.io);
        const owned = self.dupe(path);
        self.activateWorkspaceLocked(owned);
        self.scanWorkspaceSessionsLocked(owned, true);
        self.ensureWorkspaceSelectionLocked(owned);
        self.active_conversation_id = self.selected_by_workspace.get(owned);
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn getRuntimeStatus(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch null;
        const requested = if (root) |v| stringField(v, "workspacePath") else null;
        self.mutex.lockUncancelable(mer_runtime.io);
        const path = requested orelse self.active_workspace_path;
        self.mutex.unlock(mer_runtime.io);
        return self.runtimeStatusJson(req.allocator, path) catch oom();
    }

    fn getPromptSettings(self: *Runtime, req: mer.Request) mer.Response {
        self.ensurePromptSettingsLoaded();
        return self.jsonResponse(req, self.promptSettingsJson(req.allocator) catch return oom());
    }

    fn updatePromptSettings(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        self.ensurePromptSettingsLoaded();
        self.mutex.lockUncancelable(mer_runtime.io);
        if (stringField(input, "providerId")) |v| self.settings.selected_provider = self.dupe(v);
        if (stringField(input, "modelId")) |v| self.settings.selected_model = self.dupe(v);
        if (input == .object) {
            if (input.object.get("reasoningEffort")) |v| switch (v) {
                .string => |s| self.settings.selected_effort = if (validReasoningEffort(s)) self.dupe(s) else null,
                .null => self.settings.selected_effort = null,
                else => {},
            };
        }
        self.bumpLocked();
        self.savePromptSettingsLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.promptSettingsJson(req.allocator) catch return oom());
    }

    fn getThemeSettings(_: *Runtime, req: mer.Request) mer.Response {
        return mer.json(readThemeSettings(req.allocator) catch "{\"mode\":null,\"preset\":null}");
    }

    fn updateThemeSettings(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const mode = stringField(input, "mode") orelse return bad(req, "missing mode");
        const preset = stringField(input, "preset") orelse return bad(req, "missing preset");
        if (!validThemeMode(mode) or !validThemePreset(preset)) return bad(req, "invalid theme settings");
        writeThemeSettings(req.allocator, mode, preset) catch return bad(req, "failed to persist theme settings");
        return mer.json(readThemeSettings(req.allocator) catch "{\"mode\":null,\"preset\":null}");
    }

    fn listProviders(self: *Runtime, req: mer.Request) mer.Response {
        const schema = self.cachedSchemaValue(req.allocator);
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        const w = &out.writer;
        if (!writeProviderSummariesFromSchema(w, schema)) {
            writeFallbackProviderSummaries(w) catch return oom();
        }
        return self.jsonResponse(req, out.written());
    }

    fn selectConversation(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse return bad(req, "missing workspacePath");
        const conv_id = stringField(root, "conversationId") orelse return bad(req, "missing conversationId");
        self.mutex.lockUncancelable(mer_runtime.io);
        const wpath = self.dupe(workspace);
        if (self.conversations.get(conv_id)) |conversation| {
            if (!std.mem.eql(u8, conversation.workspace_path, wpath)) {
                self.mutex.unlock(mer_runtime.io);
                return bad(req, "conversation does not belong to workspace");
            }
        }
        self.setActiveWorkspaceLocked(wpath);
        if (self.conversations.get(conv_id)) |conversation| {
            self.active_conversation_id = conversation.conversation_id;
            self.selected_by_workspace.put(wpath, conversation.conversation_id) catch {};
        }
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn startNewChat(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse return bad(req, "missing workspacePath");
        self.mutex.lockUncancelable(mer_runtime.io);
        const cid = self.uniqueId("chat");
        const conversation = self.createConversationLocked(workspace, cid, "New chat");
        self.active_conversation_id = conversation.conversation_id;
        self.selected_by_workspace.put(conversation.workspace_path, conversation.conversation_id) catch {};
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn handoffChat(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse return bad(req, "missing input");
        const source_workspace = stringField(input, "sourceWorkspacePath") orelse return bad(req, "missing sourceWorkspacePath");
        const target = stringField(input, "target") orelse return bad(req, "missing target");
        const branch_name = stringField(input, "branchName");
        const source_conversation_id = stringField(input, "conversationId");

        const target_workspace = if (std.mem.eql(u8, target, "local")) blk: {
            const git = gitRuntimeStatus(req.allocator, source_workspace);
            const local_workspace = git.root_path orelse source_workspace;
            if (branch_name) |branch| {
                _ = gitOutput(req.allocator, local_workspace, &.{ "git", "checkout", "-B", branch }) catch return bad(req, "failed to switch local branch");
            }
            break :blk local_workspace;
        } else if (std.mem.eql(u8, target, "worktree")) blk: {
            const branch = branch_name orelse return bad(req, "missing branchName");
            const git = gitRuntimeStatus(req.allocator, source_workspace);
            const main_workspace = git.root_path orelse source_workspace;
            const worktree_path = worktreePathForBranch(req.allocator, main_workspace, branch) catch return oom();
            if (!fileExists(worktree_path)) {
                _ = gitOutput(req.allocator, main_workspace, &.{ "git", "worktree", "add", "-B", branch, worktree_path }) catch return bad(req, "failed to create git worktree");
            }
            break :blk worktree_path;
        } else return bad(req, "invalid handoff target");

        self.mutex.lockUncancelable(mer_runtime.io);
        const owned_workspace = self.dupe(target_workspace);
        self.invalidateRuntimeStatusLocked(source_workspace);
        self.invalidateRuntimeStatusLocked(owned_workspace);
        self.activateWorkspaceLocked(owned_workspace);
        const conversation = if (source_conversation_id) |cid| conv: {
            if (self.conversations.get(cid)) |existing| {
                self.dropGraffSession(cid);
                existing.workspace_path = owned_workspace;
                existing.updated_at = nowMillis();
                break :conv existing;
            }
            break :conv self.createConversationLocked(owned_workspace, cid, "New chat");
        } else conv: {
            const cid = self.uniqueId("chat");
            break :conv self.createConversationLocked(owned_workspace, cid, "New chat");
        };
        self.active_conversation_id = conversation.conversation_id;
        self.selected_by_workspace.put(conversation.workspace_path, conversation.conversation_id) catch {};
        self.writeConversationSessionFileLocked(conversation);
        self.invalidateSessionScanLocked(owned_workspace);
        self.scanWorkspaceSessionsLocked(owned_workspace, true);
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn createManagedChat(self: *Runtime, req: mer.Request) mer.Response {
        const path = self.createManagedChatPath();
        ensureDirectory(req.allocator, path) catch return bad(req, "failed to create managed chat workspace");
        self.mutex.lockUncancelable(mer_runtime.io);
        const owned = self.dupe(path);
        self.activateWorkspaceLocked(owned);
        if (self.workspaceIndexLocked(owned)) |idx| {
            self.workspaces.items[idx].kind = "managed_chat";
            self.workspaces.items[idx].display_name = "New chat";
        }
        const cid = self.uniqueId("chat");
        const conversation = self.createConversationLocked(owned, cid, "New chat");
        self.active_conversation_id = conversation.conversation_id;
        self.selected_by_workspace.put(conversation.workspace_path, conversation.conversation_id) catch {};
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn sendPrompt(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse return bad(req, "missing input");
        const workspace = stringField(input, "workspacePath") orelse return bad(req, "missing workspacePath");
        const prompt = stringField(input, "prompt") orelse return bad(req, "missing prompt");
        const provided_conversation = stringField(input, "conversationId");
        const agent_id = stringField(input, "agentId");

        if (!fileExists(workspace)) {
            if (isGeneratedManagedChatPath(req.allocator, workspace)) {
                ensureDirectory(req.allocator, workspace) catch return bad(req, "failed to create managed chat workspace");
            } else {
                return bad(req, "workspace path does not exist");
            }
        }

        const request_id = self.uniqueId("request");
        var conversation_id: []const u8 = undefined;
        var session_name: []const u8 = undefined;
        var workspace_for_thread: []const u8 = undefined;
        var agent_for_thread: []const u8 = undefined;
        var plan_mode_for_thread = false;

        self.mutex.lockUncancelable(mer_runtime.io);
        {
            const cid = provided_conversation orelse self.uniqueId("chat");
            const existing = self.conversations.get(cid);
            if (existing) |conv| {
                if (!std.mem.eql(u8, conv.workspace_path, workspace)) {
                    self.mutex.unlock(mer_runtime.io);
                    return bad(req, "conversation does not belong to workspace");
                }
            }
            const conv = existing orelse self.createConversationLocked(workspace, cid, titleFromPrompt(self.arena, prompt));
            if (conv.active_request_ids.items.len > 0) {
                self.mutex.unlock(mer_runtime.io);
                return bad(req, "conversation already has an active prompt");
            }
            conversation_id = conv.conversation_id;
            session_name = conv.session_name;
            workspace_for_thread = conv.workspace_path;
            self.setActiveWorkspaceLocked(conv.workspace_path);
            self.active_conversation_id = conv.conversation_id;
            self.selected_by_workspace.put(conv.workspace_path, conv.conversation_id) catch {};
            self.ensureConversationSessionFileLocked(conv);
            if (shouldAutoTitleConversation(conv)) {
                conv.title = titleFromPrompt(self.arena, prompt);
                self.renameManagedChatWorkspaceLocked(conv.workspace_path, conv.title);
            }
            const effective_agent = agent_id orelse conv.active_agent_id orelse self.active_agent_id;
            agent_for_thread = self.dupe(effective_agent);
            plan_mode_for_thread = guiAgentReadOnly(effective_agent);
            conv.plan_mode = plan_mode_for_thread;
            conv.active_agent_id = agent_for_thread;
            conv.updated_at = nowMillis();
            conv.messages.append(self.arena, .{
                .kind = .user,
                .id = self.fmt("{s}-user", .{request_id}),
                .request_id = request_id,
                .text = self.dupe(prompt),
            }) catch {};
            conv.active_request_ids.append(self.arena, request_id) catch {};
            self.writeConversationSessionFileLocked(conv);
            self.bumpLocked();
            self.saveGuiStateLocked();
        }
        self.mutex.unlock(mer_runtime.io);

        const prompt_owned = self.dupe(prompt);
        const thread = std.Thread.spawn(.{}, graffTurnThread, .{ self, conversation_id, request_id, session_name, workspace_for_thread, prompt_owned, agent_for_thread, plan_mode_for_thread }) catch |err| {
            self.mutex.lockUncancelable(mer_runtime.io);
            if (self.conversations.get(conversation_id)) |conv| {
                removeString(&conv.active_request_ids, request_id);
                conv.messages.append(self.arena, .{
                    .kind = .@"error",
                    .id = self.fmt("{s}-error", .{request_id}),
                    .request_id = request_id,
                    .error_message = self.fmt("Failed to start graff thread: {s}", .{@errorName(err)}),
                }) catch {};
                self.writeConversationSessionFileLocked(conv);
                self.emitRequestEventLocked("request-finished", conv, request_id);
            }
            self.bumpLocked();
            self.mutex.unlock(mer_runtime.io);
            return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
        };
        thread.detach();

        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn stopPrompt(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const cid = stringField(input, "conversationId") orelse return mer.json("{}");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            for (conv.active_request_ids.items) |rid| {
                if (self.active_children.get(rid)) |child| {
                    child.kill(mer_runtime.io);
                    _ = self.active_children.remove(rid);
                }
                self.emitRequestEventLocked("request-cancelled", conv, rid);
            }
            self.dropGraffSession(cid);
            conv.active_request_ids.clearRetainingCapacity();
            conv.followup = null;
            self.writeConversationSessionFileLocked(conv);
        }
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return mer.json("{}");
    }

    fn compactConversation(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const cid = stringField(input, "conversationId") orelse return bad(req, "missing conversationId");
        self.performConversationCompaction(req.allocator, cid) catch |err| {
            return bad(req, switch (err) {
                error.ConversationNotFound => "conversation not found",
                error.CompactFailed => "compaction failed",
                else => "failed to compact conversation",
            });
        };
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn performConversationCompaction(self: *Runtime, alloc: std.mem.Allocator, cid: []const u8) !void {
        var workspace: []const u8 = undefined;
        var session_name: []const u8 = undefined;
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            if (conv.active_request_ids.items.len > 0) {
                self.mutex.unlock(mer_runtime.io);
                return error.CompactFailed;
            }
            workspace = self.dupe(conv.workspace_path);
            session_name = self.dupe(conv.session_name);
            self.writeConversationSessionFileLocked(conv);
            self.dropGraffSession(cid);
        } else {
            self.mutex.unlock(mer_runtime.io);
            return error.ConversationNotFound;
        }
        self.mutex.unlock(mer_runtime.io);

        try self.runGraffCompact(alloc, workspace, session_name);

        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            const path = sessionFilePath(self.allocator, workspace, session_name) catch null;
            if (path) |p| {
                self.importSessionFileLocked(workspace, session_name, p);
                self.allocator.free(p);
            }
            const rid = self.uniqueId("compact");
            conv.messages.append(self.arena, .{
                .kind = .context_compacted,
                .id = rid,
                .request_id = rid,
                .text = "Conversation compacted. Future turns resume the compacted graff session.",
            }) catch {};
            conv.updated_at = nowMillis();
            self.writeConversationSessionFileLocked(conv);
            self.bumpLocked();
        }
        self.mutex.unlock(mer_runtime.io);
    }

    fn runGraffCompact(self: *Runtime, alloc: std.mem.Allocator, workspace: []const u8, session_name: []const u8) !void {
        if (session_name.len == 0 or std.mem.indexOfAny(u8, session_name, "/\\") != null) return error.CompactFailed;
        const bin = self.codegraffBinary();
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.append(alloc, "/usr/bin/env");
        try argv.append(alloc, try std.fmt.allocPrint(alloc, "HOME={s}", .{homeDir()}));
        try argv.append(alloc, try std.fmt.allocPrint(alloc, "PATH={s}/bin:{s}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", .{ homeDir(), homeDir() }));
        try argv.append(alloc, bin);
        try argv.append(alloc, "--json");
        try argv.append(alloc, "--resume");
        try argv.append(alloc, session_name);

        var child = try std.process.spawn(mer_runtime.io, .{
            .argv = argv.items,
            .cwd = .{ .path = workspace },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        defer child.kill(mer_runtime.io);

        {
            var wbuf: [1024]u8 = undefined;
            var cw = child.stdin.?.writerStreaming(mer_runtime.io, &wbuf);
            try cw.interface.writeAll("{\"type\":\"compact\"}\n");
            try cw.interface.flush();
            child.stdin.?.close(mer_runtime.io);
            child.stdin = null;
        }

        var rbuf: [16 * 1024]u8 = undefined;
        var rdr = child.stdout.?.readerStreaming(mer_runtime.io, &rbuf);
        var saw_ok = false;
        while (true) {
            const ev_line = rdr.interface.takeDelimiter('\n') catch break orelse break;
            const line = std.mem.trim(u8, ev_line, " \t\r\n");
            if (line.len == 0) continue;
            var tmp = std.heap.ArenaAllocator.init(alloc);
            defer tmp.deinit();
            const event = std.json.parseFromSliceLeaky(Value, tmp.allocator(), line, .{}) catch continue;
            const ty = stringField(event, "type") orelse continue;
            if (std.mem.eql(u8, ty, "compact")) {
                if (boolField(event, "ok") orelse false) saw_ok = true;
            } else if (std.mem.eql(u8, ty, "error")) {
                return error.CompactFailed;
            }
        }
        const term = child.wait(mer_runtime.io) catch return error.CompactFailed;
        if (!saw_ok or term != .exited or term.exited != 0) return error.CompactFailed;
    }

    fn respondFollowup(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const response = objectField(root, "response") orelse root;
        const followup_id = stringField(response, "followupId") orelse return bad(req, "missing followupId");
        const cancelled = boolField(response, "cancelled") orelse false;
        const notes = stringField(response, "text") orelse "";
        const selected_ids = arrayField(response, "selectedOptionIds");

        var line: ?[]const u8 = null;
        var write_failed = false;
        self.mutex.lockUncancelable(mer_runtime.io);
        var target_child: ?*std.process.Child = null;
        var it = self.conversations.iterator();
        while (it.next()) |entry| {
            const conv = entry.value_ptr.*;
            const f = conv.followup orelse continue;
            if (!std.mem.eql(u8, f.followup_id, followup_id)) continue;

            const rid = f.request_id;
            if (cancelled) {
                if (self.active_children.get(rid)) |child| {
                    child.kill(mer_runtime.io);
                    _ = self.active_children.remove(rid);
                }
                self.dropGraffSession(conv.conversation_id);
                removeString(&conv.active_request_ids, rid);
                conv.followup = null;
                self.writeConversationSessionFileLocked(conv);
                self.emitRequestEventLocked("request-cancelled", conv, rid);
            } else {
                target_child = self.active_children.get(rid);
                line = answerLineJson(req.allocator, f, notes, selected_ids, false) catch null;
                conv.followup = null;
                self.writeConversationSessionFileLocked(conv);
            }
            break;
        }
        if (!cancelled) if (line) |answer_line| {
            if (target_child) |child| {
                writeAnswerLine(child, answer_line) catch {
                    write_failed = true;
                };
            } else write_failed = true;
        };
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);

        if (write_failed) return bad(req, "followup request is no longer active");
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn archiveConversation(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const cid = stringField(root, "conversationId") orelse return bad(req, "missing conversationId");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            self.dropGraffSession(cid);
            self.deleteConversationSessionFileLocked(conv);
            _ = self.conversations.remove(cid);
            if (self.active_conversation_id != null and std.mem.eql(u8, self.active_conversation_id.?, conv.conversation_id)) self.active_conversation_id = null;
        }
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn archiveWorkspace(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse return bad(req, "missing workspacePath");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.workspaceIndexLocked(workspace)) |idx| _ = self.workspaces.swapRemove(idx);
        _ = self.selected_by_workspace.remove(workspace);
        if (self.active_workspace_path != null and std.mem.eql(u8, self.active_workspace_path.?, workspace)) {
            self.active_workspace_path = null;
            self.active_conversation_id = null;
        }
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn renameWorkspace(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse return bad(req, "missing workspacePath");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.workspaceIndexLocked(workspace)) |idx| {
            self.workspaces.items[idx].display_name = if (stringField(root, "displayName")) |name| self.dupe(name) else null;
        }
        self.bumpLocked();
        self.saveGuiStateLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn runSlashCommand(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const name = stringField(root, "name") orelse "help";
        const args_text = joinArgs(req.allocator, root) catch return oom();
        if (std.mem.eql(u8, name, "help")) return mer.json("{\"title\":\"/help\",\"body\":\"Available commands: /help, /agent, /goal, /loop, /bash <command>, /compact, /workspace-status, /workspace-info, /workspace-query <query>, /workflow <goal>, /reasoning-effort <low|medium|high>, /mcp.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"text\",\"payload\":null}");
        if (std.mem.eql(u8, name, "agent")) return self.agentCommand(req);
        if (std.mem.eql(u8, name, "bash")) {
            var out: std.Io.Writer.Allocating = .init(req.allocator);
            out.writer.writeAll("{\"title\":") catch return oom();
            writeString(&out.writer, if (args_text.len > 0) self.fmt("/bash {s}", .{args_text}) else "/bash") catch return oom();
            out.writer.writeAll(",\"body\":") catch return oom();
            writeString(&out.writer, if (args_text.len > 0) self.fmt("Zig backend did not execute shell command yet:\\n\\n$ {s}", .{args_text}) else "usage: /bash <command>") catch return oom();
            out.writer.writeAll(",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"text\",\"payload\":null}") catch return oom();
            return mer.json(out.written());
        }
        if (std.mem.eql(u8, name, "goal")) return self.goalCommand(req, root, args_text);
        if (std.mem.eql(u8, name, "loop")) return self.loopCommand(req, root, args_text);
        if (std.mem.eql(u8, name, "compact")) {
            const cid = stringField(root, "conversationId") orelse return bad(req, "missing conversationId");
            self.performConversationCompaction(req.allocator, cid) catch |err| {
                return commandText(req, "/compact", switch (err) {
                    error.ConversationNotFound => "Conversation not found.",
                    error.CompactFailed => "Compaction failed; history was left unchanged.",
                    else => "Failed to compact conversation.",
                });
            };
            const snap = self.snapshotJson(req.allocator) catch return oom();
            var out: std.Io.Writer.Allocating = .init(req.allocator);
            out.writer.writeAll("{\"title\":\"/compact\",\"body\":\"Conversation compacted. Future turns resume the compacted session.\",\"snapshot\":") catch return oom();
            out.writer.writeAll(snap) catch return oom();
            out.writer.writeAll(",\"savedPath\":null,\"resultKind\":\"snapshot\",\"payload\":null}") catch return oom();
            return mer.json(out.written());
        }
        if (std.mem.eql(u8, name, "reasoning-effort") or std.mem.eql(u8, name, "effort") or std.mem.eql(u8, name, "reasoning")) return self.reasoningEffortCommand(req, args_text);
        if (std.mem.eql(u8, name, "workflow")) return self.workflowCommand(req, args_text);
        if (std.mem.eql(u8, name, "workspace-query") or std.mem.eql(u8, name, "workspace-search")) return self.workspaceQueryCommand(req, root, args_text);
        if (std.mem.eql(u8, name, "workspace-info")) return self.workspaceInfoCommand(req, root);
        if (std.mem.eql(u8, name, "mcp")) return self.mcpCommand(req, root);
        if (std.mem.eql(u8, name, "workspace-status")) return self.workspaceStatusCommand(req, root);
        return commandText(req, "Command failed", self.fmt("Unknown command: /{s}. Run /help for the list.", .{name}));
    }

    fn goalCommand(self: *Runtime, req: mer.Request, root: Value, args_text: []const u8) mer.Response {
        const cid = stringField(root, "conversationId");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (cid) |conversation_id| {
            if (self.conversations.get(conversation_id)) |conv| {
                if (args_text.len == 0) {
                    const body = if (conv.goal) |goal| self.fmt("Current goal: {s}\n\nClear it with /goal clear.", .{goal}) else "No active goal. Set one with /goal <objective>.";
                    self.mutex.unlock(mer_runtime.io);
                    return commandText(req, "/goal", body);
                }
                if (std.mem.eql(u8, args_text, "clear") or std.mem.eql(u8, args_text, "off")) {
                    conv.goal = null;
                    conv.updated_at = nowMillis();
                    self.writeConversationSessionFileLocked(conv);
                    self.bumpLocked();
                    self.mutex.unlock(mer_runtime.io);
                    return commandText(req, "/goal", "Goal cleared. Future turns will not get goal steering.");
                }
                conv.goal = self.dupe(args_text);
                conv.updated_at = nowMillis();
                self.writeConversationSessionFileLocked(conv);
                self.bumpLocked();
                const body = self.fmt("Goal set: {s}", .{args_text});
                self.mutex.unlock(mer_runtime.io);
                return commandText(req, "/goal", body);
            }
        }
        self.mutex.unlock(mer_runtime.io);
        return commandText(req, "/goal", "No active conversation. Open a chat before setting a goal.");
    }

    fn loopCommand(self: *Runtime, req: mer.Request, root: Value, args_text: []const u8) mer.Response {
        const workspace = stringField(root, "workspacePath") orelse self.active_workspace_path orelse "";
        if (workspace.len == 0) return commandText(req, "/loop", "Open a workspace before running /loop.");
        var prompt = args_text;
        if (prompt.len == 0) prompt = "Run an autonomous plan-act-verify pass.";
        const request_id = self.uniqueId("loop");
        self.mutex.lockUncancelable(mer_runtime.io);
        const cid = stringField(root, "conversationId") orelse self.uniqueId("chat");
        const conv = self.conversations.get(cid) orelse self.createConversationLocked(workspace, cid, titleFromPrompt(self.arena, prompt));
        self.setActiveWorkspaceLocked(conv.workspace_path);
        self.active_conversation_id = conv.conversation_id;
        self.selected_by_workspace.put(conv.workspace_path, conv.conversation_id) catch {};
        conv.messages.append(self.arena, .{ .kind = .user, .id = self.fmt("{s}-user", .{request_id}), .request_id = request_id, .text = self.fmt("/loop {s}", .{prompt}) }) catch {};
        conv.messages.append(self.arena, .{ .kind = .assistant, .id = self.fmt("{s}-assistant", .{request_id}), .request_id = request_id, .text = "Loop mode is not fully implemented in the Zig backend yet. This placeholder keeps the release UI flow active." }) catch {};
        conv.updated_at = nowMillis();
        self.writeConversationSessionFileLocked(conv);
        self.saveGuiStateLocked();
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);

        const snap = self.snapshotJson(req.allocator) catch return oom();
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/loop\",\"body\":\"Started an autonomous plan-act-verify pass.\",\"snapshot\":") catch return oom();
        out.writer.writeAll(snap) catch return oom();
        out.writer.writeAll(",\"savedPath\":null,\"resultKind\":\"snapshot\",\"payload\":null}") catch return oom();
        return mer.json(out.written());
    }

    fn reasoningEffortCommand(self: *Runtime, req: mer.Request, args_text: []const u8) mer.Response {
        self.ensurePromptSettingsLoaded();
        const level = std.mem.trim(u8, args_text, " \t\r\n");
        if (level.len == 0) {
            const current = self.settings.selected_effort orelse default_reasoning_effort;
            return commandText(req, "/reasoning-effort", self.fmt("Reasoning effort is **{s}**. Set it with /reasoning-effort <low|medium|high>.", .{current}));
        }
        if (!validReasoningEffort(level)) return commandText(req, "/reasoning-effort", "Usage: /reasoning-effort <low|medium|high>");
        self.mutex.lockUncancelable(mer_runtime.io);
        self.settings.selected_effort = self.dupe(level);
        self.savePromptSettingsLocked();
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return commandText(req, "/reasoning-effort", self.fmt("Reasoning effort is now **{s}**.", .{level}));
    }

    fn workflowCommand(_: *Runtime, req: mer.Request, args_text: []const u8) mer.Response {
        const goal = if (args_text.len > 0) args_text else "Draft a workflow.";
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/workflow\",\"body\":\"Review the generated workflow before approving.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"workflowDraft\",\"payload\":{\"kind\":\"workflowDraft\",\"goal\":") catch return oom();
        writeString(&out.writer, goal) catch return oom();
        out.writer.writeAll(",\"summary\":\"Zig backend workflow draft placeholder.\",\"nodes\":[],\"exportText\":") catch return oom();
        writeString(&out.writer, std.fmt.allocPrint(req.allocator, "goal: {s}\nnodes: []", .{goal}) catch "nodes: []") catch return oom();
        out.writer.writeAll(",\"approvedPrompt\":") catch return oom();
        writeString(&out.writer, goal) catch return oom();
        out.writer.writeAll(",\"trace\":[\"Created workflow draft in the Zig backend\"]}}") catch return oom();
        return mer.json(out.written());
    }

    fn workspaceQueryCommand(_: *Runtime, req: mer.Request, root: Value, args_text: []const u8) mer.Response {
        const workspace = stringField(root, "workspacePath") orelse "";
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/workspace-query\",\"body\":\"Workspace semantic search is not indexed by the Zig backend yet.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"workspaceSearch\",\"payload\":{\"kind\":\"workspaceSearch\",\"workspacePath\":") catch return oom();
        writeString(&out.writer, workspace) catch return oom();
        out.writer.writeAll(",\"query\":") catch return oom();
        writeString(&out.writer, args_text) catch return oom();
        out.writer.writeAll(",\"results\":[]}}") catch return oom();
        return mer.json(out.written());
    }

    fn workspaceInfoCommand(_: *Runtime, req: mer.Request, root: Value) mer.Response {
        const workspace = stringField(root, "workspacePath") orelse "";
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/workspace-info\",\"body\":\"Workspace metadata loaded.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"workspaceInfo\",\"payload\":{\"kind\":\"workspaceInfo\",\"workspacePath\":") catch return oom();
        writeString(&out.writer, workspace) catch return oom();
        out.writer.writeAll(",\"workspaceId\":null,\"workingDir\":") catch return oom();
        writeNullableString(&out.writer, if (workspace.len == 0) null else workspace) catch return oom();
        out.writer.writeAll(",\"nodeCount\":null,\"relationCount\":null,\"lastUpdated\":null,\"createdAt\":null}}") catch return oom();
        return mer.json(out.written());
    }

    fn writeAgentsPayload(self: *Runtime, w: *std.Io.Writer, include_kind: bool) !void {
        self.ensurePromptSettingsLoaded();
        const provider = self.settings.selected_provider orelse "codegraff";
        const model = self.settings.selected_model orelse "default";
        const effort = effectiveReasoningEffort(provider, model, self.settings.selected_effort);
        const active = self.active_agent_id;
        if (include_kind) try w.writeAll("{\"kind\":\"agents\",") else try w.writeByte('{');
        try w.writeAll("\"activeAgentId\":");
        try writeString(w, active);
        try w.writeAll(",\"selectedProviderId\":");
        try writeString(w, provider);
        try w.writeAll(",\"selectedModelId\":");
        try writeString(w, model);
        try w.writeAll(",\"selectedReasoningEffort\":");
        try writeNullableString(w, effort);
        try w.writeAll(",\"agents\":[");
        inline for (.{ .{ "forge", "Forge", "Implementation assistant for coding tasks." }, .{ "muse", "Muse", "Planning assistant for read-only analysis." }, .{ "sage", "Sage", "Research assistant for deeper analysis." } }, 0..) |agent, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try writeString(w, agent[0]);
            try w.writeAll(",\"title\":");
            try writeString(w, agent[1]);
            try w.writeAll(",\"description\":");
            try writeString(w, agent[2]);
            try w.writeAll(",\"isActive\":");
            try w.writeAll(if (std.mem.eql(u8, active, agent[0])) "true" else "false");
            try w.writeAll(",\"modelId\":");
            try writeString(w, model);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }

    fn agentCommand(self: *Runtime, req: mer.Request) mer.Response {
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/agent\",\"body\":\"Active agent status.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"agents\",\"payload\":") catch return oom();
        self.writeAgentsPayload(&out.writer, true) catch return oom();
        out.writer.writeByte('}') catch return oom();
        return mer.json(out.written());
    }

    fn workspaceSync(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse "";
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"workspacePath\":") catch return oom();
        writeString(&out.writer, workspace) catch return oom();
        out.writer.writeAll(",\"events\":[\"Zig-native GUI MVP does not maintain a workspace index yet.\"]}") catch return oom();
        return mer.json(out.written());
    }

    fn workspaceQuery(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const workspace = stringField(input, "workspacePath") orelse "";
        const query = stringField(input, "query") orelse "";
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"workspacePath\":") catch return oom();
        writeString(&out.writer, workspace) catch return oom();
        out.writer.writeAll(",\"query\":") catch return oom();
        writeString(&out.writer, query) catch return oom();
        out.writer.writeAll(",\"results\":[]}") catch return oom();
        return mer.json(out.written());
    }

    fn buildWorkflowDraft(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const goal = stringField(input, "goal") orelse "";
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"goal\":") catch return oom();
        writeString(&out.writer, goal) catch return oom();
        out.writer.writeAll(",\"summary\":\"Workflow drafting is stubbed in the Zig-native GUI MVP.\",\"nodes\":[],\"exportText\":") catch return oom();
        writeString(&out.writer, std.fmt.allocPrint(req.allocator, "goal: {s}\nnodes: []", .{goal}) catch "") catch return oom();
        out.writer.writeAll(",\"approvedPrompt\":") catch return oom();
        writeString(&out.writer, goal) catch return oom();
        out.writer.writeAll(",\"trace\":[]}") catch return oom();
        return mer.json(out.written());
    }

    fn exportWorkflowDraft(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const draft = objectField(root, "draft") orelse root;
        const text = stringField(draft, "exportText") orelse "";
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        writeString(&out.writer, text) catch return oom();
        return mer.json(out.written());
    }

    fn setActiveAgent(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const agent = stringField(root, "agentId") orelse "forge";
        self.mutex.lockUncancelable(mer_runtime.io);
        self.active_agent_id = self.dupe(agent);
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        self.writeAgentsPayload(&out.writer, false) catch return oom();
        return mer.json(out.written());
    }

    fn setEffort(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const level = stringField(root, "level") orelse return bad(req, "missing level");
        if (!validReasoningEffort(level)) return bad(req, "invalid reasoning effort");
        self.ensurePromptSettingsLoaded();
        self.mutex.lockUncancelable(mer_runtime.io);
        self.settings.selected_effort = self.dupe(level);
        self.savePromptSettingsLocked();
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return mer.json("{}");
    }

    fn setFast(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        self.ensurePromptSettingsLoaded();
        self.mutex.lockUncancelable(mer_runtime.io);
        self.settings.fast_enabled = boolField(root, "on") orelse false;
        self.savePromptSettingsLocked();
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return mer.json("{}");
    }

    fn listMcpServers(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch null;
        const workspace = self.workspaceFromRequest(root);
        return self.mcpSettingsResponse(req, workspace) catch return oom();
    }

    fn importMcpConfig(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const scope = stringField(input, "scope") orelse "local";
        if (!std.mem.eql(u8, scope, "local")) return bad(req, "only local workspace MCP config is supported");
        const json_text = stringField(input, "json") orelse return bad(req, "missing MCP config JSON");
        if (json_text.len > 1024 * 1024) return bad(req, "MCP config is too large");
        var tmp = std.heap.ArenaAllocator.init(req.allocator);
        defer tmp.deinit();
        const parsed = std.json.parseFromSliceLeaky(Value, tmp.allocator(), json_text, .{ .allocate = .alloc_always }) catch return bad(req, "invalid MCP config JSON");
        if (parsed != .object or objectField(parsed, "mcpServers") == null) return bad(req, "MCP config must contain an mcpServers object");
        const workspace = self.workspaceFromRequest(root) orelse return bad(req, "open a workspace before importing local MCP config");
        writeMcpConfig(req.allocator, workspace, json_text) catch return bad(req, "failed to write MCP config");
        return self.mcpSettingsResponse(req, workspace) catch return oom();
    }

    fn removeMcpServer(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const scope = stringField(input, "scope") orelse "local";
        if (!std.mem.eql(u8, scope, "local")) return bad(req, "only local workspace MCP config is supported");
        const name = stringField(input, "name") orelse return bad(req, "missing MCP server name");
        const workspace = self.workspaceFromRequest(root) orelse return bad(req, "open a workspace before editing local MCP config");
        removeMcpServerFromConfig(req.allocator, workspace, name) catch |err| {
            return bad(req, switch (err) {
                error.McpConfigNotFound => "MCP config not found",
                error.McpServerNotFound => "MCP server not found",
                else => "failed to update MCP config",
            });
        };
        return self.mcpSettingsResponse(req, workspace) catch return oom();
    }

    fn mcpCommand(self: *Runtime, req: mer.Request, root: Value) mer.Response {
        const workspace = stringField(root, "workspacePath") orelse self.active_workspace_path;
        const payload = renderMcpSettingsJson(req.allocator, workspace) catch return oom();
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/mcp\",\"body\":\"Workspace MCP configuration loaded. Servers are shown from .mcp.json without executing them.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"mcp\",\"payload\":{\"kind\":\"mcp\",") catch return oom();
        out.writer.writeAll(payload[1 .. payload.len - 1]) catch return oom();
        out.writer.writeAll("}}") catch return oom();
        return mer.json(out.written());
    }

    fn mcpSettingsResponse(self: *Runtime, req: mer.Request, workspace: ?[]const u8) !mer.Response {
        _ = self;
        return mer.json(try renderMcpSettingsJson(req.allocator, workspace));
    }

    fn workspaceFromRequest(self: *Runtime, root: ?Value) ?[]const u8 {
        if (root) |value| {
            if (stringField(value, "workspacePath")) |workspace| return workspace;
            if (objectField(value, "input")) |input| if (stringField(input, "workspacePath")) |workspace| return workspace;
        }
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        return self.active_workspace_path;
    }

    fn startProviderAuth(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const provider = stringField(input, "providerId") orelse "codegraff";
        const method = stringField(input, "authMethod") orelse "api_key";

        if (std.mem.eql(u8, method, "codegraff_device")) {
            const started = startCodegraffDevice(req.allocator) catch |err| {
                return bad(req, authErrorMessage(err));
            };
            return deviceAuthResponse(req, provider, started);
        }
        if (std.mem.eql(u8, method, "kimi_device")) {
            const started = startKimiDevice(req.allocator) catch |err| {
                return bad(req, authErrorMessage(err));
            };
            return deviceAuthResponse(req, provider, started);
        }

        var out: std.Io.Writer.Allocating = .init(req.allocator);
        const kind =
            if (std.mem.eql(u8, method, "api_key")) "api_key" else if (std.mem.eql(u8, method, "o_auth_code")) "o_auth_code" else if (std.mem.eql(u8, method, "o_auth_device")) "device_code" else if (std.mem.eql(u8, method, "codex_device")) "cli_login" else "cli_login";
        const requires_api_key = std.mem.eql(u8, kind, "api_key") and !std.mem.eql(u8, method, "google_adc");
        const sid = std.fmt.allocPrint(req.allocator, "codegraff-provider:{s}", .{provider}) catch provider;
        out.writer.writeAll("{\"kind\":") catch return oom();
        writeString(&out.writer, kind) catch return oom();
        out.writer.writeAll(",\"authSessionId\":") catch return oom();
        writeString(&out.writer, sid) catch return oom();
        out.writer.writeAll(",\"requiresApiKey\":") catch return oom();
        out.writer.writeAll(if (requires_api_key) "true" else "false") catch return oom();
        out.writer.writeAll(",\"apiKeyHint\":") catch return oom();
        const cli_hint =
            if (std.mem.eql(u8, method, "codex_device"))
                "Codex uses the shared Codex CLI login. Run `codex login` in your terminal if needed, then finish setup here."
            else
                "Complete the provider login in your terminal, then finish setup here.";
        writeNullableString(&out.writer, if (std.mem.eql(u8, kind, "cli_login")) cli_hint else "Paste an API key for this provider.") catch return oom();
        out.writer.writeAll(",\"urlParameters\":[],\"verificationUri\":") catch return oom();
        writeNullableString(&out.writer, null) catch return oom();
        out.writer.writeAll(",\"verificationUriComplete\":") catch return oom();
        writeNullableString(&out.writer, null) catch return oom();
        out.writer.writeAll(",\"userCode\":") catch return oom();
        writeNullableString(&out.writer, null) catch return oom();
        out.writer.writeAll(",\"expiresInSeconds\":null,\"authorizationUrl\":") catch return oom();
        writeNullableString(&out.writer, if (std.mem.eql(u8, kind, "o_auth_code")) "https://codegraff.dev/oauth" else null) catch return oom();
        out.writer.writeAll("}") catch return oom();
        return mer.json(out.written());
    }

    fn completeProviderAuth(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const sid = stringField(input, "authSessionId") orelse "codegraff-provider:codegraff";
        if (std.mem.startsWith(u8, sid, "codegraff-device:")) {
            completeCodegraffDevice(req.allocator, sid["codegraff-device:".len..]) catch |err| {
                return bad(req, authErrorMessage(err));
            };
            return providerSummaryResponse(req, "codegraff");
        }
        if (std.mem.startsWith(u8, sid, "kimi-device:")) {
            completeKimiDevice(req.allocator, sid["kimi-device:".len..]) catch |err| {
                return bad(req, authErrorMessage(err));
            };
            return providerSummaryResponse(req, "kimi");
        }
        const provider = std.mem.trim(u8, if (std.mem.startsWith(u8, sid, "codegraff-provider:")) sid["codegraff-provider:".len..] else sid, " ");
        if (stringField(input, "apiKey")) |key| {
            if (key.len == 0) return bad(req, "missing API key");
            storeProviderKey(req.allocator, provider, key) catch |err| {
                return bad(req, authErrorMessage(err));
            };
        }
        if (std.mem.eql(u8, provider, "codex") and !providerConfiguredById("codex", null)) {
            return bad(req, "Codex is not logged in. Run `codex login` in your terminal, then click Finish setup again.");
        }
        return providerSummaryResponse(req, provider);
    }

    fn removeProvider(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const provider = stringField(input, "providerId") orelse "codegraff";
        const info = providerInfo(provider);
        if (providerConfigured(info.env_key)) {
            const env_key = info.env_key orelse "the provider environment variable";
            var msg: std.Io.Writer.Allocating = .init(req.allocator);
            msg.writer.print("credential removed from Codegraff's local store, but ${s} is still inherited by the running Codegraff app, so it is still being used.", .{env_key}) catch return oom();
            return bad(req, msg.written());
        }
        removeStoredProvider(req.allocator, provider) catch {};
        return providerSummaryResponse(req, provider);
    }

    fn readWorkspaceFile(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse return bad(req, "missing workspacePath");
        const rel = stringField(root, "path") orelse return bad(req, "missing path");
        if (workspace.len == 0 or rel.len == 0 or std.fs.path.isAbsolute(rel) or hasParentPathComponent(rel)) return bad(req, "path is outside the workspace");
        const joined = std.fs.path.join(req.allocator, &.{ workspace, rel }) catch return oom();
        defer req.allocator.free(joined);
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = std.Io.Dir.cwd().realPathFile(mer_runtime.io, workspace, &root_buf) catch return bad(req, "workspace path does not exist");
        const target_len = std.Io.Dir.cwd().realPathFile(mer_runtime.io, joined, &target_buf) catch return bad(req, "failed to read file");
        const root_real = root_buf[0..root_len];
        const target_real = target_buf[0..target_len];
        if (!pathIsWithinRoot(root_real, target_real)) return bad(req, "path is outside the workspace");
        const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, target_real, req.allocator, .limited(512 * 1024)) catch return bad(req, "failed to read file");
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        writeString(&out.writer, data) catch return oom();
        return mer.json(out.written());
    }

    fn savePastedImage(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const ext = stringField(root, "ext") orelse "png";
        const safe_ext = if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg") or std.mem.eql(u8, ext, "gif") or std.mem.eql(u8, ext, "bmp")) ext else "png";
        const path = std.fmt.allocPrint(req.allocator, "/tmp/codegraff-paste-{d}.{s}", .{ nowMillis(), safe_ext }) catch return oom();
        if (arrayField(root, "data")) |arr| {
            var bytes = req.allocator.alloc(u8, arr.items.len) catch return oom();
            for (arr.items, 0..) |item, i| bytes[i] = if (item == .integer) @intCast(@max(0, @min(255, item.integer))) else 0;
            std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = bytes }) catch return bad(req, "failed to write image");
        }
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        writeString(&out.writer, path) catch return oom();
        return mer.json(out.written());
    }

    fn saveAttachmentFile(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const name = stringField(input, "name") orelse "attachment.txt";
        const raw_data = stringField(input, "dataBase64") orelse return bad(req, "missing dataBase64");
        const data = stripDataUrlBase64(raw_data);
        if (data.len > 96 * 1024 * 1024) return bad(req, "attachment is too large");

        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(data) catch return bad(req, "invalid attachment data");
        if (decoded_len > 64 * 1024 * 1024) return bad(req, "attachment is too large");

        const bytes = req.allocator.alloc(u8, decoded_len) catch return oom();
        decoder.decode(bytes, data) catch return bad(req, "invalid attachment data");

        const safe_name = safeAttachmentFileName(req.allocator, name) catch return oom();
        const path = std.fmt.allocPrint(req.allocator, "/tmp/codegraff-attachment-{d}-{s}", .{ nowMillis(), safe_name }) catch return oom();
        std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = bytes }) catch return bad(req, "failed to write attachment");

        var out: std.Io.Writer.Allocating = .init(req.allocator);
        writeString(&out.writer, path) catch return oom();
        return mer.json(out.written());
    }

    fn saveConversationLayout(_: *Runtime, req: mer.Request) mer.Response {
        _ = parse(req) catch return badJson(req);
        return mer.json("{}");
    }

    fn createSavedWorkspace(_: *Runtime, req: mer.Request) mer.Response {
        const id = std.fmt.allocPrint(req.allocator, "workspace-{d}", .{nowMillis()}) catch return oom();
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"id\":") catch return oom();
        writeString(&out.writer, id) catch return oom();
        out.writer.writeAll(",\"name\":\"Saved workspace\",\"layoutJson\":\"{}\",\"updatedAt\":") catch return oom();
        out.writer.print("{d}", .{nowSeconds()}) catch return oom();
        out.writer.writeAll("}") catch return oom();
        return mer.json(out.written());
    }

    fn gitMutation(self: *Runtime, req: mer.Request, cmd: []const u8) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const workspace = stringField(input, "workspacePath") orelse stringField(root, "workspacePath") orelse "";
        if (workspace.len == 0) return bad(req, "missing workspacePath");
        self.mutex.lockUncancelable(mer_runtime.io);
        runGitMutation(req.allocator, workspace, cmd, input) catch |err| {
            self.mutex.unlock(mer_runtime.io);
            return bad(req, gitMutationErrorMessage(err));
        };
        self.invalidateRuntimeStatusLocked(workspace);
        self.mutex.unlock(mer_runtime.io);
        return self.runtimeStatusJson(req.allocator, workspace) catch oom();
    }

    fn terminalOpen(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        const workspace = stringField(input, "workspacePath") orelse return bad(req, "missing workspacePath");
        const cols = clampTerminalSize(intField(input, "cols", 80), 80);
        const rows = clampTerminalSize(intField(input, "rows", 24), 24);
        if (!fileExists(workspace)) return bad(req, "workspace path does not exist");

        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.terminals.get(terminal_id)) |existing| {
            if (!std.mem.eql(u8, existing.workspace_path, workspace)) {
                self.mutex.unlock(mer_runtime.io);
                return bad(req, "terminal id belongs to a different workspace");
            }
            existing.cols = cols;
            existing.rows = rows;
            existing.proc.resize(cols, rows) catch {};
            const shell = existing.shell;
            const instance_id = existing.instance_id;
            const stored_workspace = existing.workspace_path;
            const scrollback = req.allocator.dupe(u8, existing.scrollback.items) catch {
                self.mutex.unlock(mer_runtime.io);
                return oom();
            };
            const truncated = existing.scrollback_truncated;
            const scrollback_seq = existing.output_seq;
            self.mutex.unlock(mer_runtime.io);
            return terminalSessionJson(req.allocator, terminal_id, instance_id, stored_workspace, shell, cols, rows, scrollback, truncated, scrollback_seq);
        }
        self.mutex.unlock(mer_runtime.io);

        const shell = resolveShell();
        const proc = pty.spawnShell(self.arena, .{
            .shell = shell,
            .cwd = workspace,
            .cols = cols,
            .rows = rows,
        }) catch |err| {
            log.err("failed to spawn PTY shell for terminal {s}: {}", .{ terminal_id, err });
            return mer.Response.init(.internal_server_error, .json, "{\"error\":\"failed to open terminal PTY\"}");
        };

        const session = self.arena.create(TerminalSessionState) catch return oom();
        session.* = .{
            .terminal_id = self.dupe(terminal_id),
            .instance_id = self.uniqueId("terminal-instance"),
            .workspace_path = self.dupe(workspace),
            .cwd = self.dupe(workspace),
            .shell = shell,
            .cols = cols,
            .rows = rows,
            .proc = proc,
        };

        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.terminals.get(terminal_id)) |winner| {
            if (!std.mem.eql(u8, winner.workspace_path, workspace)) {
                self.mutex.unlock(mer_runtime.io);
                closeTerminalSession(session);
                return bad(req, "terminal id belongs to a different workspace");
            }
            const winner_terminal_id = winner.terminal_id;
            const winner_instance_id = winner.instance_id;
            const winner_workspace = winner.workspace_path;
            const winner_shell = winner.shell;
            const winner_cols = winner.cols;
            const winner_rows = winner.rows;
            const winner_scrollback = req.allocator.dupe(u8, winner.scrollback.items) catch {
                self.mutex.unlock(mer_runtime.io);
                closeTerminalSession(session);
                return oom();
            };
            const winner_truncated = winner.scrollback_truncated;
            const winner_scrollback_seq = winner.output_seq;
            self.mutex.unlock(mer_runtime.io);
            closeTerminalSession(session);
            return terminalSessionJson(req.allocator, winner_terminal_id, winner_instance_id, winner_workspace, winner_shell, winner_cols, winner_rows, winner_scrollback, winner_truncated, winner_scrollback_seq);
        }
        self.terminals.put(session.terminal_id, session) catch {
            self.mutex.unlock(mer_runtime.io);
            closeTerminalSession(session);
            return oom();
        };
        self.mutex.unlock(mer_runtime.io);

        const thread = std.Thread.spawn(.{}, terminalReaderMain, .{ self, session }) catch |err| {
            log.err("failed to start PTY reader for terminal {s}: {}", .{ terminal_id, err });
            self.mutex.lockUncancelable(mer_runtime.io);
            _ = self.terminals.remove(session.terminal_id);
            self.mutex.unlock(mer_runtime.io);
            closeTerminalSession(session);
            return mer.Response.init(.internal_server_error, .json, "{\"error\":\"failed to start terminal reader\"}");
        };
        thread.detach();

        return terminalSessionJson(req.allocator, terminal_id, session.instance_id, workspace, shell, cols, rows, "", false, 0);
    }

    fn terminalWrite(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        const terminal_instance_id = stringField(input, "terminalInstanceId") orelse return bad(req, "missing terminalInstanceId");
        const data = stringField(input, "data") orelse "";

        self.mutex.lockUncancelable(mer_runtime.io);
        const session = self.terminals.get(terminal_id) orelse {
            self.mutex.unlock(mer_runtime.io);
            return bad(req, "terminal session not found");
        };
        if (!self.terminalInstanceMatches(session, terminal_instance_id)) {
            self.mutex.unlock(mer_runtime.io);
            return bad(req, "terminal session instance is no longer active");
        }
        self.mutex.unlock(mer_runtime.io);
        session.io_mutex.lockUncancelable(mer_runtime.io);
        defer session.io_mutex.unlock(mer_runtime.io);
        if (session.closing.load(.acquire)) return bad(req, "terminal session is closing");
        session.proc.writeAll(data) catch {
            self.emitTerminalError(session, "terminal write failed");
            return mer.Response.init(.internal_server_error, .json, "{\"error\":\"terminal write failed\"}");
        };
        return mer.json("null");
    }

    fn terminalResize(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        const terminal_instance_id = stringField(input, "terminalInstanceId") orelse return bad(req, "missing terminalInstanceId");
        const cols = clampTerminalSize(intField(input, "cols", 80), 80);
        const rows = clampTerminalSize(intField(input, "rows", 24), 24);
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.terminals.get(terminal_id)) |session| {
            if (!self.terminalInstanceMatches(session, terminal_instance_id)) {
                self.mutex.unlock(mer_runtime.io);
                return bad(req, "terminal session instance is no longer active");
            }
            session.cols = cols;
            session.rows = rows;
            session.io_mutex.lockUncancelable(mer_runtime.io);
            session.proc.resize(cols, rows) catch self.emitTerminalError(session, "terminal resize failed");
            session.io_mutex.unlock(mer_runtime.io);
        }
        self.mutex.unlock(mer_runtime.io);
        return mer.json("null");
    }

    fn terminalClose(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        const terminal_instance_id = stringField(input, "terminalInstanceId") orelse return bad(req, "missing terminalInstanceId");
        self.mutex.lockUncancelable(mer_runtime.io);
        const session = self.terminals.get(terminal_id);
        if (session) |s| {
            if (!self.terminalInstanceMatches(s, terminal_instance_id)) {
                self.mutex.unlock(mer_runtime.io);
                return mer.json("null");
            }
        }
        _ = self.terminals.remove(terminal_id);
        self.mutex.unlock(mer_runtime.io);
        if (session) |s| closeTerminalSession(s);
        return mer.json("null");
    }

    fn emitTerminalOutput(self: *Runtime, session: *TerminalSessionState, data: []const u8) void {
        const seq = self.appendTerminalScrollback(session, data);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"terminalId\":") catch return;
        writeString(&out.writer, session.terminal_id) catch return;
        out.writer.writeAll(",\"terminalInstanceId\":") catch return;
        writeString(&out.writer, session.instance_id) catch return;
        out.writer.writeAll(",\"terminalOutputSeq\":") catch return;
        out.writer.print("{d}", .{seq}) catch return;
        out.writer.writeAll(",\"data\":") catch return;
        writeString(&out.writer, data) catch return;
        out.writer.writeAll("}") catch return;
        self.emitSseEvent("terminal-output", out.written());
    }

    fn emitTerminalExit(self: *Runtime, session: *TerminalSessionState, exit_code: i64) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"terminalId\":") catch return;
        writeString(&out.writer, session.terminal_id) catch return;
        out.writer.writeAll(",\"terminalInstanceId\":") catch return;
        writeString(&out.writer, session.instance_id) catch return;
        out.writer.print(",\"exitCode\":{d},\"signal\":null}}", .{exit_code}) catch return;
        self.emitSseEvent("terminal-exit", out.written());
    }

    fn emitTerminalError(self: *Runtime, session: *TerminalSessionState, message: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"terminalId\":") catch return;
        writeString(&out.writer, session.terminal_id) catch return;
        out.writer.writeAll(",\"terminalInstanceId\":") catch return;
        writeString(&out.writer, session.instance_id) catch return;
        out.writer.writeAll(",\"message\":") catch return;
        writeString(&out.writer, message) catch return;
        out.writer.writeAll("}") catch return;
        self.emitSseEvent("terminal-error", out.written());
    }

    fn appendTerminalScrollback(self: *Runtime, session: *TerminalSessionState, data: []const u8) u64 {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        session.output_seq += 1;
        const seq = session.output_seq;
        session.scrollback.appendSlice(self.allocator, data) catch return seq;
        if (session.scrollback.items.len > terminal_scrollback_limit) {
            const drop = session.scrollback.items.len - terminal_scrollback_limit;
            std.mem.copyForwards(u8, session.scrollback.items[0..terminal_scrollback_limit], session.scrollback.items[drop..]);
            session.scrollback.items.len = terminal_scrollback_limit;
            session.scrollback_truncated = true;
        }
        return seq;
    }

    fn emitSseEvent(self: *Runtime, name: []const u8, data: []const u8) void {
        const owned_name = self.allocator.dupe(u8, name) catch return;
        const owned_data = self.allocator.dupe(u8, data) catch {
            self.allocator.free(owned_name);
            return;
        };

        self.event_mutex.lockUncancelable(mer_runtime.io);
        defer self.event_mutex.unlock(mer_runtime.io);
        self.events.append(self.allocator, .{
            .seq = self.next_event_seq,
            .name = owned_name,
            .data = owned_data,
        }) catch {
            self.allocator.free(owned_name);
            self.allocator.free(owned_data);
            return;
        };
        self.next_event_seq += 1;
        if (self.events.items.len > sse_event_replay_limit) {
            const drop = self.events.items.len - sse_event_replay_limit;
            for (self.events.items[0..drop]) |event| self.freeSseEvent(event);
            std.mem.copyForwards(SseEvent, self.events.items[0..sse_event_replay_limit], self.events.items[drop..]);
            self.events.items.len = sse_event_replay_limit;
        }
    }

    fn freeSseEvent(self: *Runtime, event: SseEvent) void {
        self.allocator.free(event.name);
        self.allocator.free(event.data);
    }

    fn newestEventSeqLocked(self: *Runtime) u64 {
        return if (self.next_event_seq > 0) self.next_event_seq - 1 else 0;
    }

    fn clampRequestedEventSeqLocked(self: *Runtime, requested: u64) u64 {
        const newest = self.newestEventSeqLocked();
        if (self.events.items.len == 0) return if (requested > newest) newest else requested;
        const oldest = self.events.items[0].seq;
        const replay_from = if (oldest > 0) oldest - 1 else 0;
        if (requested > newest) return replay_from;
        if (requested < replay_from) return replay_from;
        return requested;
    }

    fn terminalInstanceMatches(_: *Runtime, session: *TerminalSessionState, requested: ?[]const u8) bool {
        return requested == null or std.mem.eql(u8, session.instance_id, requested.?);
    }

    fn requestActiveLocked(self: *Runtime, cid: []const u8, rid: []const u8) bool {
        const conv = self.conversations.get(cid) orelse return false;
        for (conv.active_request_ids.items) |active| {
            if (std.mem.eql(u8, active, rid)) return true;
        }
        return false;
    }

    fn requestHasMessageKind(self: *Runtime, cid: []const u8, rid: []const u8, kind: Message.Kind) bool {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        const conv = self.conversations.get(cid) orelse return false;
        for (conv.messages.items) |message| {
            if (message.kind == kind and std.mem.eql(u8, message.request_id, rid)) return true;
        }
        return false;
    }

    fn workspaceStatusCommand(self: *Runtime, req: mer.Request, root: Value) mer.Response {
        _ = self;
        const workspace = stringField(root, "workspacePath") orelse "";
        const files = gitStatusFiles(req.allocator, workspace) catch &.{};
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/workspace-status\",\"body\":\"Workspace status loaded.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"workspaceStatus\",\"payload\":{\"kind\":\"workspaceStatus\",\"workspacePath\":") catch return oom();
        writeString(&out.writer, workspace) catch return oom();
        out.writer.writeAll(",\"files\":[") catch return oom();
        for (files, 0..) |file, i| {
            if (i > 0) out.writer.writeByte(',') catch return oom();
            out.writer.writeAll("{\"path\":") catch return oom();
            writeString(&out.writer, file.path) catch return oom();
            out.writer.writeAll(",\"status\":") catch return oom();
            writeString(&out.writer, file.status) catch return oom();
            out.writer.writeAll("}") catch return oom();
        }
        out.writer.writeAll("]}}") catch return oom();
        return mer.json(out.written());
    }

    fn ensureGraffSession(self: *Runtime, conversation_id: []const u8, session_name: []const u8, workspace: []const u8, agent_id: []const u8, plan_mode: bool, provider: ?[]const u8, model: ?[]const u8) !*GraffSession {
        const io = mer_runtime.io;
        const desired_yolo = !plan_mode and std.mem.eql(u8, agent_id, "forge");
        self.mutex.lockUncancelable(io);
        if (self.graff_sessions.get(conversation_id)) |session| {
            if (session.yolo_enabled == desired_yolo and std.mem.eql(u8, session.workspace_path, workspace) and std.mem.eql(u8, session.session_name, session_name) and optionalStringEql(session.desired_provider, provider) and optionalStringEql(session.desired_model, model)) {
                self.mutex.unlock(io);
                return session;
            }
            if (self.graff_sessions.fetchRemove(conversation_id)) |entry| self.closeGraffSession(entry.value);
        }
        self.mutex.unlock(io);

        const bin = self.codegraffBinary();
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, "/usr/bin/env");
        try argv.append(self.allocator, try std.fmt.allocPrint(self.allocator, "HOME={s}", .{homeDir()}));
        try argv.append(self.allocator, try std.fmt.allocPrint(self.allocator, "PATH={s}/bin:{s}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", .{ homeDir(), homeDir() }));
        try argv.append(self.allocator, bin);
        try argv.append(self.allocator, "--json");
        if (desired_yolo) try argv.append(self.allocator, "--yolo");
        if (session_name.len > 0 and std.mem.indexOfAny(u8, session_name, "/\\") == null) {
            try argv.append(self.allocator, "--resume");
            try argv.append(self.allocator, session_name);
        }

        const child = try self.allocator.create(std.process.Child);
        errdefer self.allocator.destroy(child);
        child.* = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = workspace },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const session = try self.allocator.create(GraffSession);
        errdefer {
            child.kill(io);
            self.allocator.destroy(session);
        }
        session.* = .{
            .conversation_id = self.dupe(conversation_id),
            .workspace_path = self.dupe(workspace),
            .session_name = self.dupe(session_name),
            .desired_provider = if (provider) |p| self.dupe(p) else null,
            .desired_model = if (model) |m| self.dupe(m) else null,
            .child = child,
            .yolo_enabled = desired_yolo,
        };

        self.mutex.lockUncancelable(io);
        if (self.graff_sessions.get(conversation_id)) |_| {
            self.mutex.unlock(io);
            self.closeGraffSession(session);
            return error.SessionRace;
        }
        self.graff_sessions.put(session.conversation_id, session) catch {
            self.mutex.unlock(io);
            self.closeGraffSession(session);
            return error.OutOfMemory;
        };
        self.mutex.unlock(io);
        return session;
    }

    fn dropGraffSession(self: *Runtime, conversation_id: []const u8) void {
        if (self.graff_sessions.fetchRemove(conversation_id)) |entry| self.closeGraffSession(entry.value);
    }

    fn dropGraffSessionIfCurrent(self: *Runtime, conversation_id: []const u8, session: *GraffSession) void {
        const current = self.graff_sessions.get(conversation_id) orelse return;
        if (current == session) {
            if (self.graff_sessions.fetchRemove(conversation_id)) |entry| self.closeGraffSession(entry.value);
        }
    }

    fn closeGraffSession(self: *Runtime, session: *GraffSession) void {
        _ = self;
        // Turn threads may still hold the session pointer while a stop/cancel
        // unblocks their stdout read. Kill immediately, but leave reclamation to
        // process teardown rather than risking use-after-free across threads.
        session.child.kill(mer_runtime.io);
    }

    fn retryGraffTurnAfterSetupFailure(self: *Runtime, conversation_id: []const u8, request_id: []const u8, session: *GraffSession, session_name: []const u8, workspace: []const u8, prompt: []const u8, agent_id: []const u8, plan_mode: bool) anyerror!void {
        self.mutex.lockUncancelable(mer_runtime.io);
        self.dropGraffSessionIfCurrent(conversation_id, session);
        self.mutex.unlock(mer_runtime.io);
        return self.streamGraffTurn(conversation_id, request_id, session_name, workspace, prompt, agent_id, plan_mode, false);
    }

    fn streamGraffTurn(self: *Runtime, conversation_id: []const u8, request_id: []const u8, session_name: []const u8, workspace: []const u8, prompt: []const u8, agent_id: []const u8, plan_mode: bool, retry_on_setup_failure: bool) anyerror!void {
        const io = mer_runtime.io;
        self.ensurePromptSettingsLoaded();
        const prompt_selection = self.turnPromptSelectionLocked(conversation_id);
        const model = prompt_selection.model;
        const provider = prompt_selection.provider;
        const effort = prompt_selection.effort;
        const fast_enabled = prompt_selection.fast_enabled;

        const session = try self.ensureGraffSession(conversation_id, session_name, workspace, agent_id, plan_mode, provider, model);
        self.mutex.lockUncancelable(io);
        self.active_children.put(request_id, session.child) catch {};
        const active_after_spawn = self.requestActiveLocked(conversation_id, request_id);
        self.mutex.unlock(io);
        defer {
            self.mutex.lockUncancelable(io);
            if (self.active_children.get(request_id) == session.child) _ = self.active_children.remove(request_id);
            self.mutex.unlock(io);
        }
        if (!active_after_spawn) {
            self.mutex.lockUncancelable(io);
            self.dropGraffSessionIfCurrent(conversation_id, session);
            self.mutex.unlock(io);
            return;
        }
        var drop_session_on_return = false;
        defer if (drop_session_on_return) {
            self.mutex.lockUncancelable(io);
            self.dropGraffSessionIfCurrent(conversation_id, session);
            self.mutex.unlock(io);
        };
        errdefer {
            self.mutex.lockUncancelable(io);
            self.dropGraffSessionIfCurrent(conversation_id, session);
            self.mutex.unlock(io);
        }

        var wbuf: [4096]u8 = undefined;
        var cw = session.child.stdin.?.writerStreaming(io, &wbuf);
        const rbuf = try self.allocator.alloc(u8, 1024 * 1024);
        defer self.allocator.free(rbuf);
        var rdr = session.child.stdout.?.readerStreaming(io, rbuf);
        var protocol_warning_count: usize = 0;

        if (prompt_selection.send_model_control) if (provider) |p| if (model) |m| {
            if (p.len > 0 and m.len > 0 and !std.mem.eql(u8, m, "default") and (!optionalStringEql(session.acked_provider, provider) or !optionalStringEql(session.acked_model, model))) {
                var control: std.Io.Writer.Allocating = .init(self.allocator);
                defer control.deinit();
                try control.writer.writeAll("{\"type\":\"set_model\",\"name\":");
                try writeString(&control.writer, self.fmt("{s}/{s}", .{ p, m }));
                try control.writer.writeByte('}');
                if (!try self.sendControlAndWait(&rdr, &cw, conversation_id, request_id, control.written(), "model", &protocol_warning_count, retry_on_setup_failure, true)) {
                    if (retry_on_setup_failure and !self.requestHasMessageKind(conversation_id, request_id, .@"error")) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
                    drop_session_on_return = true;
                    return;
                }
                session.acked_provider = self.dupe(p);
                session.acked_model = self.dupe(m);
            }
        };
        if (effort) |level| {
            if (!optionalStringEql(session.acked_effort, effort)) {
                var control: std.Io.Writer.Allocating = .init(self.allocator);
                defer control.deinit();
                try control.writer.writeAll("{\"type\":\"set_effort\",\"level\":");
                try writeString(&control.writer, level);
                try control.writer.writeByte('}');
                if (!try self.sendControlAndWait(&rdr, &cw, conversation_id, request_id, control.written(), "effort", &protocol_warning_count, retry_on_setup_failure, true)) {
                    if (retry_on_setup_failure and !self.requestHasMessageKind(conversation_id, request_id, .@"error")) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
                    drop_session_on_return = true;
                    return;
                }
                session.acked_effort = self.dupe(level);
            }
        }
        if (session.acked_fast == null or session.acked_fast.? != fast_enabled) {
            if (!try self.sendControlAndWait(&rdr, &cw, conversation_id, request_id, if (fast_enabled) "{\"type\":\"set_fast\",\"on\":true}" else "{\"type\":\"set_fast\",\"on\":false}", "fast", &protocol_warning_count, retry_on_setup_failure, true)) {
                if (retry_on_setup_failure and !self.requestHasMessageKind(conversation_id, request_id, .@"error")) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
                drop_session_on_return = true;
                return;
            }
            session.acked_fast = fast_enabled;
        }
        const core_agent = guiAgentCoreAgent(agent_id) orelse "";
        if (!optionalStringEql(session.acked_agent, core_agent)) {
            var control: std.Io.Writer.Allocating = .init(self.allocator);
            defer control.deinit();
            try control.writer.writeAll("{\"type\":\"set_agent\",\"id\":");
            try writeString(&control.writer, core_agent);
            try control.writer.writeByte('}');
            if (!try self.sendControlAndWait(&rdr, &cw, conversation_id, request_id, control.written(), "agent", &protocol_warning_count, retry_on_setup_failure, true)) {
                if (retry_on_setup_failure and !self.requestHasMessageKind(conversation_id, request_id, .@"error")) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
                drop_session_on_return = true;
                return;
            }
            session.acked_agent = self.dupe(core_agent);
        }
        const mode = if (plan_mode) "plan" else "normal";
        if (!optionalStringEql(session.acked_mode, mode)) {
            if (!try self.sendControlAndWait(&rdr, &cw, conversation_id, request_id, if (plan_mode) "{\"type\":\"set_mode\",\"mode\":\"plan\"}" else "{\"type\":\"set_mode\",\"mode\":\"normal\"}", "mode", &protocol_warning_count, retry_on_setup_failure, true)) {
                if (retry_on_setup_failure and !self.requestHasMessageKind(conversation_id, request_id, .@"error")) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
                drop_session_on_return = true;
                return;
            }
            session.acked_mode = self.dupe(mode);
        }

        var user_req: std.Io.Writer.Allocating = .init(self.allocator);
        defer user_req.deinit();
        try user_req.writer.writeAll("{\"type\":\"user\",\"text\":");
        try writeString(&user_req.writer, prompt);
        try user_req.writer.writeByte('}');
        cw.interface.writeAll(user_req.written()) catch |err| {
            if (retry_on_setup_failure) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
            return err;
        };
        cw.interface.writeByte('\n') catch |err| {
            if (retry_on_setup_failure) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
            return err;
        };
        cw.interface.flush() catch |err| {
            if (retry_on_setup_failure) return self.retryGraffTurnAfterSetupFailure(conversation_id, request_id, session, session_name, workspace, prompt, agent_id, plan_mode);
            return err;
        };

        var assistant_seq: usize = 0;
        var reasoning_seq: usize = 0;
        var current_assistant: ?[]const u8 = null;
        var current_reasoning: ?[]const u8 = null;
        var event_count: usize = 0;
        var session_failed = false;
        var saw_turn = false;
        while (true) {
            const ev_line = rdr.interface.takeDelimiter('\n') catch |err| {
                self.mutex.lockUncancelable(io);
                const still_active = self.requestActiveLocked(conversation_id, request_id);
                self.mutex.unlock(io);
                if (still_active) log.warn("graff read ended with {}", .{err});
                session_failed = true;
                break;
            } orelse {
                self.mutex.lockUncancelable(io);
                const still_active = self.requestActiveLocked(conversation_id, request_id);
                self.mutex.unlock(io);
                if (still_active) log.warn("graff read ended with EOF", .{});
                session_failed = true;
                break;
            };
            const line = std.mem.trim(u8, ev_line, " \t\r\n");
            if (line.len == 0) continue;
            self.mutex.lockUncancelable(io);
            const still_active = self.requestActiveLocked(conversation_id, request_id);
            self.mutex.unlock(io);
            if (!still_active) break;
            var turn_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer turn_arena.deinit();
            const event = std.json.parseFromSliceLeaky(Value, turn_arena.allocator(), line, .{}) catch |err| {
                log.warn("graff event parse failed: {}", .{err});
                event_count += 1;
                protocol_warning_count = self.appendProtocolWarningLimited(conversation_id, request_id, protocol_warning_count, self.fmt("{s}-malformed-event-{d}", .{ request_id, event_count }), "Malformed graff JSONL event", line);
                continue;
            };
            const ty = stringField(event, "type") orelse {
                log.warn("graff event missing type", .{});
                event_count += 1;
                const raw = self.valueJson(event) catch line;
                protocol_warning_count = self.appendProtocolWarningLimited(conversation_id, request_id, protocol_warning_count, self.fmt("{s}-missing-type-event-{d}", .{ request_id, event_count }), "Graff JSONL event missing type", raw);
                continue;
            };
            event_count += 1;
            if (std.mem.eql(u8, ty, "text")) {
                const delta = stringField(event, "text") orelse "";
                if (delta.len == 0) continue;
                current_reasoning = null;
                if (current_assistant == null) {
                    current_assistant = self.fmt("{s}-assistant-{d}", .{ request_id, assistant_seq });
                    assistant_seq += 1;
                }
                self.appendDelta(conversation_id, request_id, current_assistant.?, .assistant, delta);
            } else if (std.mem.eql(u8, ty, "reasoning")) {
                const delta = stringField(event, "text") orelse "";
                if (delta.len == 0) continue;
                current_assistant = null;
                if (current_reasoning == null) {
                    current_reasoning = self.fmt("{s}-reasoning-{d}", .{ request_id, reasoning_seq });
                    reasoning_seq += 1;
                }
                self.appendDelta(conversation_id, request_id, current_reasoning.?, .reasoning, delta);
            } else if (std.mem.eql(u8, ty, "tool_call")) {
                current_assistant = null;
                const name = stringField(event, "name") orelse "tool";
                const input = objectField(event, "input") orelse event;
                const id = self.fmt("{s}-tool-{d}", .{ request_id, nowMillis() });
                const call_id = stringField(event, "call_id") orelse stringField(event, "id") orelse id;
                self.appendToolStart(conversation_id, request_id, id, name, call_id, stringField(input, "question") orelse "", input);
            } else if (std.mem.eql(u8, ty, "ask_user")) {
                current_assistant = null;
                const input = objectField(event, "input") orelse event;
                const call_id = stringField(event, "call_id") orelse self.uniqueId("ask-user");
                const question = stringField(input, "question") orelse "";
                const options = self.followupOptions(input);
                const kind = if (options.len > 0) "single" else "text";
                const id = self.fmt("{s}-tool-{d}", .{ request_id, nowMillis() });
                self.appendToolStart(conversation_id, request_id, id, "ask_user", call_id, question, input);
                self.setFollowup(conversation_id, request_id, workspace, call_id, question, kind, options);
            } else if (std.mem.eql(u8, ty, "tool_result")) {
                current_assistant = null;
                const name = stringField(event, "name") orelse "tool";
                const text = stringField(event, "text") orelse "";
                const is_error = boolField(event, "is_error") orelse false;
                const call_id = stringField(event, "call_id") orelse stringField(event, "id");
                self.appendToolEnd(conversation_id, request_id, self.fmt("{s}-toolend-{d}", .{ request_id, nowMillis() }), name, call_id, text, is_error);
            } else if (self.handleProtocolAck(conversation_id, request_id, ty, event)) {
                current_assistant = null;
            } else if (std.mem.eql(u8, ty, "error")) {
                const msg = stringField(event, "message") orelse "graff error";
                self.appendError(conversation_id, request_id, msg);
                session_failed = true;
                break;
            } else if (std.mem.eql(u8, ty, "turn")) {
                const final_text = stringField(event, "text") orelse "";
                if (final_text.len > 0 and !self.requestHasMessageKind(conversation_id, request_id, .assistant)) {
                    self.appendDelta(conversation_id, request_id, self.fmt("{s}-assistant-final", .{request_id}), .assistant, final_text);
                }
                saw_turn = true;
                break;
            } else {
                const raw = self.valueJson(event) catch line;
                self.appendStatusOutput(conversation_id, request_id, self.fmt("{s}-unknown-event-{d}", .{ request_id, event_count }), self.fmt("Unhandled graff event: {s}", .{ty}), raw);
            }
        }
        if (saw_turn and (session.acked_fast == null or session.acked_fast.? != fast_enabled)) {
            var post_turn_warnings: usize = protocol_warning_count;
            if (!try self.sendControlAndWait(&rdr, &cw, conversation_id, request_id, if (fast_enabled) "{\"type\":\"set_fast\",\"on\":true}" else "{\"type\":\"set_fast\",\"on\":false}", "fast", &post_turn_warnings, true, false)) {
                session_failed = true;
            } else {
                session.acked_fast = fast_enabled;
            }
        }

        self.mutex.lockUncancelable(io);
        const completed_still_active = self.requestActiveLocked(conversation_id, request_id);
        self.mutex.unlock(io);
        if (event_count == 0 and completed_still_active) {
            self.appendError(conversation_id, request_id, "graff exited before producing a response");
        }
        if (session_failed) drop_session_on_return = true;
    }

    fn appendDelta(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, kind: Message.Kind, delta: []const u8) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            if (!self.requestActiveLocked(cid, rid)) return;
            var i = conv.messages.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, conv.messages.items[i].id, id)) {
                    conv.messages.items[i].text = self.fmt("{s}{s}", .{ conv.messages.items[i].text, delta });
                    conv.updated_at = nowMillis();
                    self.emitMessageDeltaLocked(conv, rid, id, kind, delta);
                    return;
                }
            }
            conv.messages.append(self.arena, .{ .kind = kind, .id = id, .request_id = rid, .text = self.dupe(delta) }) catch {};
            conv.updated_at = nowMillis();
            self.emitMessageDeltaLocked(conv, rid, id, kind, delta);
        }
    }

    fn emitMessageDeltaLocked(self: *Runtime, conv: *Conversation, rid: []const u8, id: []const u8, kind: Message.Kind, delta: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"conversationId\":") catch return;
        writeString(&out.writer, conv.conversation_id) catch return;
        out.writer.writeAll(",\"workspacePath\":") catch return;
        writeString(&out.writer, conv.workspace_path) catch return;
        out.writer.writeAll(",\"requestId\":") catch return;
        writeString(&out.writer, rid) catch return;
        out.writer.writeAll(",\"messageId\":") catch return;
        writeString(&out.writer, id) catch return;
        out.writer.writeAll(",\"kind\":") catch return;
        writeString(&out.writer, @tagName(kind)) catch return;
        out.writer.writeAll(",\"text\":") catch return;
        writeString(&out.writer, delta) catch return;
        out.writer.writeByte('}') catch return;
        self.emitSseEvent("message-delta", out.written());
    }

    fn emitRequestEventLocked(self: *Runtime, event_name: []const u8, conv: *Conversation, rid: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"conversationId\":") catch return;
        writeString(&out.writer, conv.conversation_id) catch return;
        out.writer.writeAll(",\"workspacePath\":") catch return;
        writeString(&out.writer, conv.workspace_path) catch return;
        out.writer.writeAll(",\"requestId\":") catch return;
        writeString(&out.writer, rid) catch return;
        out.writer.writeByte('}') catch return;
        self.emitSseEvent(event_name, out.written());
    }

    fn appendToolStart(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, name: []const u8, call_id: ?[]const u8, question: []const u8, input: Value) void {
        const detail = self.toolCallDetailJson(name, question, input);
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            if (!self.requestActiveLocked(cid, rid)) return;
            conv.messages.append(self.arena, .{ .kind = .tool_start, .id = id, .request_id = rid, .name = self.dupe(name), .call_id = if (call_id) |c| self.dupe(c) else null, .question = self.dupe(question), .tool_detail_json = detail }) catch {};
            self.writeConversationSessionFileLocked(conv);
            self.bumpLocked();
        }
    }

    fn appendToolEnd(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, name: []const u8, call_id: ?[]const u8, text: []const u8, is_error: bool) void {
        const detail = self.toolResultDetailJson(name, text);
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            if (!self.requestActiveLocked(cid, rid)) return;
            conv.messages.append(self.arena, .{ .kind = .tool_end, .id = id, .request_id = rid, .name = self.dupe(name), .call_id = if (call_id) |c| self.dupe(c) else null, .summary = firstLine(self.arena, text), .text = self.dupe(text), .is_error = is_error, .result_detail_json = detail }) catch {};
            self.writeConversationSessionFileLocked(conv);
            self.bumpLocked();
        }
    }

    fn toolCallDetailJson(self: *Runtime, name: []const u8, question: []const u8, input: Value) []const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        const w = &out.writer;
        if (std.mem.eql(u8, name, "bash")) {
            w.writeAll("{\"kind\":\"shell\",\"command\":") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, stringField(input, "command") orelse stringField(input, "cmd") orelse "") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll(",\"cwd\":null,\"description\":null}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else if (std.mem.eql(u8, name, "read_file")) {
            w.writeAll("{\"kind\":\"file_read\",\"path\":") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, stringField(input, "path") orelse "") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll(",\"startLine\":null,\"endLine\":null}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else if (std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit_file")) {
            w.writeAll("{\"kind\":\"file_update\",\"path\":") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, stringField(input, "path") orelse "") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll(",\"operation\":") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, if (std.mem.eql(u8, name, "write_file")) "overwrite" else "replace") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll("}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else if (std.mem.eql(u8, name, "webfetch")) {
            w.writeAll("{\"kind\":\"fetch\",\"url\":") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, stringField(input, "url") orelse "") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll("}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else if (std.mem.eql(u8, name, "ask_user")) {
            w.writeAll("{\"kind\":\"followup\",\"question\":") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, question) catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll("}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else if (std.mem.eql(u8, name, "todo_read")) {
            w.writeAll("{\"kind\":\"todo_read\"}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else if (std.mem.eql(u8, name, "todo_write")) {
            w.writeAll("{\"kind\":\"todo_write\",\"count\":0}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else if (std.mem.eql(u8, name, "codedb")) {
            w.writeAll("{\"kind\":\"codebase_search\",\"queries\":[") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, stringField(input, "command") orelse "") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll("]}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        } else {
            w.writeAll("{\"kind\":\"unknown\",\"name\":") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            writeString(w, name) catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
            w.writeAll("}") catch return "{\"kind\":\"unknown\",\"name\":\"tool\"}";
        }
        return out.written();
    }

    fn toolResultDetailJson(self: *Runtime, name: []const u8, text: []const u8) []const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        const w = &out.writer;
        if (std.mem.eql(u8, name, "bash")) {
            w.writeAll("{\"kind\":\"shell_output\",\"command\":\"\",\"shell\":\"sh\",\"exitCode\":null,\"description\":null,\"stdout\":{\"content\":") catch return "{\"kind\":\"text\",\"text\":\"\"}";
            writeString(w, text) catch return "{\"kind\":\"text\",\"text\":\"\"}";
            w.writeAll(",\"totalLines\":0,\"headDisplayLines\":null,\"tailDisplayLines\":null,\"fullOutputPath\":null},\"stderr\":null}") catch return "{\"kind\":\"text\",\"text\":\"\"}";
        } else {
            w.writeAll("{\"kind\":\"text\",\"text\":") catch return "{\"kind\":\"text\",\"text\":\"\"}";
            writeString(w, text) catch return "{\"kind\":\"text\",\"text\":\"\"}";
            w.writeAll("}") catch return "{\"kind\":\"text\",\"text\":\"\"}";
        }
        return out.written();
    }

    fn appendStatusOutput(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, title: []const u8, output: []const u8) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            if (!self.requestActiveLocked(cid, rid)) return;
            conv.messages.append(self.arena, .{ .kind = .status, .id = id, .request_id = rid, .title = self.dupe(title), .subtitle = "Preserved raw event for protocol compatibility.", .category = "debug" }) catch {};
            conv.messages.append(self.arena, .{ .kind = .status_output, .id = self.fmt("{s}-output", .{id}), .request_id = rid, .text = self.dupe(output) }) catch {};
            self.writeConversationSessionFileLocked(conv);
            self.bumpLocked();
        }
    }

    fn appendProtocolWarning(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, title: []const u8, raw: []const u8) void {
        var allocated = false;
        const text = if (std.unicode.utf8ValidateSlice(raw)) raw else blk: {
            const sanitized = sanitizeTerminalOutput(self.allocator, raw) catch break :blk "<invalid protocol output>";
            allocated = true;
            break :blk sanitized;
        };
        defer if (allocated) self.allocator.free(text);
        self.appendStatusOutput(cid, rid, id, title, text);
    }

    fn appendProtocolWarningLimited(self: *Runtime, cid: []const u8, rid: []const u8, count: usize, id: []const u8, title: []const u8, raw: []const u8) usize {
        if (count < protocol_warning_limit_per_turn) {
            self.appendProtocolWarning(cid, rid, id, title, raw);
        } else if (count == protocol_warning_limit_per_turn) {
            self.appendProtocolWarning(cid, rid, id, "Additional graff protocol events suppressed", "Further malformed or untyped graff JSONL events were omitted to keep the GUI transcript bounded.");
        }
        return count + 1;
    }

    fn sendControlAndWait(self: *Runtime, rdr: anytype, cw: anytype, cid: []const u8, rid: []const u8, request_line: []const u8, ack_type: []const u8, warning_count: *usize, suppress_transport_errors: bool, handle_ack: bool) !bool {
        cw.interface.writeAll(request_line) catch |err| {
            log.warn("graff {s} control write failed with {}", .{ ack_type, err });
            if (!suppress_transport_errors) self.appendError(cid, rid, self.fmt("graff {s} control did not acknowledge", .{ack_type}));
            return false;
        };
        cw.interface.writeByte('\n') catch |err| {
            log.warn("graff {s} control write failed with {}", .{ ack_type, err });
            if (!suppress_transport_errors) self.appendError(cid, rid, self.fmt("graff {s} control did not acknowledge", .{ack_type}));
            return false;
        };
        cw.interface.flush() catch |err| {
            log.warn("graff {s} control flush failed with {}", .{ ack_type, err });
            if (!suppress_transport_errors) self.appendError(cid, rid, self.fmt("graff {s} control did not acknowledge", .{ack_type}));
            return false;
        };

        while (true) {
            const ev_line = rdr.interface.takeDelimiter('\n') catch |err| {
                log.warn("graff control read ended with {}", .{err});
                if (!suppress_transport_errors) self.appendError(cid, rid, self.fmt("graff {s} control did not acknowledge", .{ack_type}));
                return false;
            } orelse {
                if (!suppress_transport_errors) self.appendError(cid, rid, self.fmt("graff exited before {s} control acknowledged", .{ack_type}));
                return false;
            };
            const line = std.mem.trim(u8, ev_line, " \t\r\n");
            if (line.len == 0) continue;

            var control_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer control_arena.deinit();
            const event = std.json.parseFromSliceLeaky(Value, control_arena.allocator(), line, .{}) catch |err| {
                log.warn("graff control event parse failed: {}", .{err});
                warning_count.* = self.appendProtocolWarningLimited(cid, rid, warning_count.*, self.fmt("{s}-control-malformed-{d}", .{ rid, warning_count.* + 1 }), "Malformed graff JSONL event", line);
                continue;
            };
            const ty = stringField(event, "type") orelse {
                const raw = self.valueJson(event) catch line;
                warning_count.* = self.appendProtocolWarningLimited(cid, rid, warning_count.*, self.fmt("{s}-control-missing-type-{d}", .{ rid, warning_count.* + 1 }), "Graff JSONL event missing type", raw);
                continue;
            };
            if (std.mem.eql(u8, ty, "error")) {
                self.appendError(cid, rid, stringField(event, "message") orelse self.fmt("graff {s} control failed", .{ack_type}));
                return false;
            }
            if (std.mem.eql(u8, ty, ack_type)) {
                if (handle_ack) _ = self.handleProtocolAck(cid, rid, ty, event);
                return true;
            }
            const raw = self.valueJson(event) catch line;
            warning_count.* = self.appendProtocolWarningLimited(cid, rid, warning_count.*, self.fmt("{s}-control-unexpected-{d}", .{ rid, warning_count.* + 1 }), self.fmt("Unexpected graff setup event: {s}", .{ty}), raw);
        }
    }

    fn handleProtocolAck(self: *Runtime, cid: []const u8, rid: []const u8, ty: []const u8, event: Value) bool {
        if (!isProtocolAckEvent(ty)) return false;
        if (!(boolField(event, "ok") orelse true)) {
            self.appendError(cid, rid, self.fmt("graff {s} control failed", .{ty}));
            return true;
        }

        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        const conv = self.conversations.get(cid) orelse return true;
        if (!self.requestActiveLocked(cid, rid)) return true;
        if (std.mem.eql(u8, ty, "model")) {
            if (stringField(event, "provider")) |provider| conv.session_provider = self.dupe(provider);
            if (stringField(event, "model")) |model| conv.session_model = self.dupe(model);
        } else if (std.mem.eql(u8, ty, "mode")) {
            if (stringField(event, "mode")) |mode| conv.plan_mode = std.mem.eql(u8, mode, "plan");
        } else if (std.mem.eql(u8, ty, "ultracode")) {
            if (boolField(event, "on")) |on| conv.session_ultracode_mode = on;
        }
        conv.updated_at = nowMillis();
        self.writeConversationSessionFileLocked(conv);
        self.bumpLocked();
        return true;
    }

    fn appendError(self: *Runtime, cid: []const u8, rid: []const u8, msg: []const u8) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            if (!self.requestActiveLocked(cid, rid)) return;
            conv.messages.append(self.arena, .{ .kind = .@"error", .id = self.fmt("{s}-error-{d}", .{ rid, nowMillis() }), .request_id = rid, .error_message = self.dupe(msg) }) catch {};
            self.writeConversationSessionFileLocked(conv);
            self.bumpLocked();
        }
    }

    fn followupOptions(self: *Runtime, input: Value) []const FollowupOption {
        const raw_options = arrayField(input, "options") orelse return &.{};
        var options: std.ArrayList(FollowupOption) = .empty;
        for (raw_options.items, 0..) |item, idx| {
            const label = switch (item) {
                .string => |s| s,
                .object => |obj| strFieldObj(obj, "label") orelse strFieldObj(obj, "text") orelse strFieldObj(obj, "value") orelse continue,
                else => continue,
            };
            if (label.len == 0) continue;
            const id = switch (item) {
                .object => |obj| strFieldObj(obj, "id") orelse self.fmt("opt-{d}", .{idx + 1}),
                else => self.fmt("opt-{d}", .{idx + 1}),
            };
            options.append(self.arena, .{ .id = self.dupe(id), .label = self.dupe(label) }) catch {};
        }
        return options.toOwnedSlice(self.arena) catch &.{};
    }

    fn setFollowup(self: *Runtime, cid: []const u8, rid: []const u8, workspace: []const u8, call_id: []const u8, question: []const u8, kind: []const u8, options: []const FollowupOption) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            if (!self.requestActiveLocked(cid, rid)) return;
            const stored_options = self.arena.alloc(FollowupOption, options.len) catch @panic("oom");
            for (options, 0..) |option, idx| stored_options[idx] = .{ .id = self.dupe(option.id), .label = self.dupe(option.label) };
            conv.followup = .{ .followup_id = self.dupe(call_id), .workspace_path = self.dupe(workspace), .conversation_id = conv.conversation_id, .request_id = rid, .kind = self.dupe(kind), .question = self.dupe(question), .options = stored_options, .call_id = self.dupe(call_id) };
            self.writeConversationSessionFileLocked(conv);
            self.bumpLocked();
        }
    }

    fn snapshotJson(self: *Runtime, alloc: std.mem.Allocator) ![]const u8 {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        var out: std.Io.Writer.Allocating = .init(alloc);
        const w = &out.writer;
        try w.writeAll("{\"activeWorkspacePath\":");
        try writeNullableString(w, self.active_workspace_path);
        try w.writeAll(",\"activeConversationId\":");
        try writeNullableString(w, self.active_conversation_id);

        const visible = if (self.active_conversation_id) |cid| self.conversations.get(cid) else null;
        try w.writeAll(",\"visibleMessages\":");
        try self.writeMessages(w, if (visible) |v| v.messages.items else &.{});
        try w.writeAll(",\"visibleActiveRequestIds\":");
        try writeStringArray(w, if (visible) |v| v.active_request_ids.items else &.{});
        try w.writeAll(",\"visibleRequestAgentIds\":{},\"visibleTodos\":[]");
        if (visible) |v| {
            if (v.goal) |goal| {
                try w.writeAll(",\"visibleGoal\":");
                try writeString(w, goal);
            }
        }
        try w.writeAll(",\"visibleFollowup\":");
        if (visible) |v| try self.writeFollowup(w, v.followup) else try w.writeAll("null");
        try w.writeAll(",\"conversationViews\":[");
        if (visible) |v| try self.writeConversationView(w, v);
        try w.writeAll("],\"uiError\":null,\"workspaces\":[");
        for (self.workspaces.items, 0..) |workspace, idx| {
            if (idx > 0) try w.writeByte(',');
            try self.writeWorkspace(w, workspace);
        }
        try w.writeAll("],\"savedWorkspaces\":[]}");
        return out.written();
    }

    fn writeConversationView(self: *Runtime, w: *std.Io.Writer, conv: *Conversation) !void {
        try w.writeAll("{\"workspacePath\":");
        try writeString(w, conv.workspace_path);
        try w.writeAll(",\"conversationId\":");
        try writeString(w, conv.conversation_id);
        try w.writeAll(",\"messages\":");
        try self.writeMessages(w, conv.messages.items);
        try w.writeAll(",\"activeRequestIds\":");
        try writeStringArray(w, conv.active_request_ids.items);
        try w.writeAll(",\"requestAgentIds\":{},\"todos\":[]");
        if (conv.goal) |goal| {
            try w.writeAll(",\"goal\":");
            try writeString(w, goal);
        }
        try w.writeAll(",\"followup\":");
        try self.writeFollowup(w, conv.followup);
        try w.writeAll("}");
    }

    fn writeWorkspace(self: *Runtime, w: *std.Io.Writer, workspace: Workspace) !void {
        try w.writeAll("{\"kind\":");
        try writeString(w, workspace.kind);
        try w.writeAll(",\"workspacePath\":");
        try writeString(w, workspace.path);
        try w.writeAll(",\"workspaceName\":");
        try writeString(w, workspace.display_name orelse workspaceName(workspace.path));
        try w.writeAll(",\"configured\":true,\"configurationError\":null,\"selectedConversationId\":");
        try writeNullableString(w, self.selected_by_workspace.get(workspace.path));
        try w.writeAll(",\"conversations\":[");
        var first = true;
        var it = self.conversations.iterator();
        while (it.next()) |entry| {
            const conv = entry.value_ptr.*;
            if (!std.mem.eql(u8, conv.workspace_path, workspace.path)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"conversationId\":");
            try writeString(w, conv.conversation_id);
            try w.writeAll(",\"title\":");
            try writeString(w, conv.title);
            try w.writeAll(",\"updatedAt\":");
            if (conv.updated_at > 0) {
                var buf: [32]u8 = undefined;
                try writeString(w, try std.fmt.bufPrint(&buf, "{d}", .{conv.updated_at}));
            } else try w.writeAll("null");
            try w.writeAll(",\"isDraft\":");
            try w.writeAll(if (conv.messages.items.len == 0) "true" else "false");
            try w.writeAll(",\"isRunning\":");
            try w.writeAll(if (conv.active_request_ids.items.len > 0) "true" else "false");
            try w.writeAll(",\"hasPendingFollowup\":");
            try w.writeAll(if (conv.followup != null) "true" else "false");
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }

    fn writeMessages(self: *Runtime, w: *std.Io.Writer, messages: []const Message) !void {
        _ = self;
        try w.writeByte('[');
        for (messages, 0..) |message, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.writeAll("{\"kind\":");
            try writeString(w, @tagName(message.kind));
            try w.writeAll(",\"id\":");
            try writeString(w, message.id);
            try w.writeAll(",\"requestId\":");
            try writeString(w, message.request_id);
            switch (message.kind) {
                .user, .context_compacted, .assistant, .reasoning, .status_output => {
                    try w.writeAll(",\"text\":");
                    try writeString(w, message.text);
                },
                .status => {
                    try w.writeAll(",\"title\":");
                    try writeString(w, message.title);
                    try w.writeAll(",\"subtitle\":");
                    try writeNullableString(w, message.subtitle);
                    try w.writeAll(",\"category\":");
                    try writeString(w, message.category);
                },
                .tool_start => {
                    try w.writeAll(",\"name\":");
                    try writeString(w, message.name);
                    try w.writeAll(",\"callId\":");
                    try writeNullableString(w, message.call_id);
                    try w.writeAll(",\"detail\":");
                    if (message.tool_detail_json) |detail| try w.writeAll(detail) else {
                        try w.writeAll("{\"kind\":\"unknown\",\"name\":");
                        try writeString(w, message.name);
                        try w.writeAll("}");
                    }
                },
                .tool_end => {
                    try w.writeAll(",\"name\":");
                    try writeString(w, message.name);
                    try w.writeAll(",\"callId\":");
                    try writeNullableString(w, message.call_id);
                    try w.writeAll(",\"summary\":");
                    try writeNullableString(w, message.summary);
                    try w.writeAll(",\"isError\":");
                    try w.writeAll(if (message.is_error) "true" else "false");
                    try w.writeAll(",\"detail\":");
                    if (message.result_detail_json) |detail| try w.writeAll(detail) else if (message.text.len > 0) {
                        try w.writeAll("{\"kind\":\"text\",\"text\":");
                        try writeString(w, message.text);
                        try w.writeAll("}");
                    } else try w.writeAll("null");
                },
                .@"error" => {
                    try w.writeAll(",\"message\":");
                    try writeString(w, message.error_message);
                },
            }
            try w.writeAll("}");
        }
        try w.writeByte(']');
    }

    fn writeFollowup(_: *Runtime, w: *std.Io.Writer, followup: ?Followup) !void {
        const f = followup orelse {
            try w.writeAll("null");
            return;
        };
        try w.writeAll("{\"followupId\":");
        try writeString(w, f.followup_id);
        try w.writeAll(",\"workspacePath\":");
        try writeString(w, f.workspace_path);
        try w.writeAll(",\"conversationId\":");
        try writeString(w, f.conversation_id);
        try w.writeAll(",\"requestId\":");
        try writeString(w, f.request_id);
        try w.writeAll(",\"kind\":");
        try writeString(w, f.kind);
        try w.writeAll(",\"question\":");
        try writeString(w, f.question);
        try w.writeAll(",\"options\":[");
        for (f.options, 0..) |option, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try writeString(w, option.id);
            try w.writeAll(",\"label\":");
            try writeString(w, option.label);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }

    fn runtimeStatusJson(self: *Runtime, alloc: std.mem.Allocator, path: ?[]const u8) !mer.Response {
        const p = path orelse "";
        const now = nowMillis();
        self.mutex.lockUncancelable(mer_runtime.io);
        const generation = self.runtime_status_generation;
        if (self.runtime_status_cache.get(p)) |entry| {
            if (entry.expires_ms > now) {
                const cached = alloc.dupe(u8, entry.json) catch {
                    self.mutex.unlock(mer_runtime.io);
                    return error.OutOfMemory;
                };
                self.mutex.unlock(mer_runtime.io);
                return mer.json(cached);
            }
        }
        self.mutex.unlock(mer_runtime.io);

        const rendered = try renderRuntimeStatusJson(alloc, p);
        const key = try self.allocator.dupe(u8, p);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, rendered);
        errdefer self.allocator.free(value);

        self.mutex.lockUncancelable(mer_runtime.io);
        if (!self.storeRuntimeStatusCacheLocked(p, key, value, now + runtime_status_cache_ttl_ms, generation)) {
            self.mutex.unlock(mer_runtime.io);
            self.allocator.free(key);
            self.allocator.free(value);
            return mer.json(rendered);
        }
        self.mutex.unlock(mer_runtime.io);

        return mer.json(rendered);
    }

    fn storeRuntimeStatusCacheLocked(self: *Runtime, p: []const u8, key: []const u8, value: []const u8, expires_ms: i64, generation: u64) bool {
        if (self.runtime_status_generation != generation) return false;
        if (self.runtime_status_cache.fetchRemove(p)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.json);
        }
        self.runtime_status_cache.put(key, .{ .json = value, .expires_ms = expires_ms }) catch return false;
        return true;
    }

    fn invalidateRuntimeStatusLocked(self: *Runtime, path: ?[]const u8) void {
        self.runtime_status_generation +%= 1;
        if (path) |p| {
            if (self.runtime_status_cache.fetchRemove(p)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value.json);
            }
            return;
        }
        var it = self.runtime_status_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.json);
        }
        self.runtime_status_cache.clearRetainingCapacity();
    }

    fn promptSettingsJson(self: *Runtime, alloc: std.mem.Allocator) ![]const u8 {
        const schema = self.cachedSchemaValue(alloc);
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        const selected = resolvePromptSelection(schema, self.settings.selected_provider, self.settings.selected_model);
        var out: std.Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll("{\"availableModels\":");
        try writePromptModels(&out.writer, schema);
        try out.writer.writeAll(",\"selectedProviderId\":");
        try writeNullableString(&out.writer, selected.provider);
        try out.writer.writeAll(",\"selectedModelId\":");
        try writeNullableString(&out.writer, selected.model);
        try out.writer.writeAll(",\"selectedReasoningEffort\":");
        try writeNullableString(&out.writer, effectiveReasoningEffort(selected.provider, selected.model, self.settings.selected_effort));
        try out.writer.writeAll(",\"fastEnabled\":");
        try out.writer.writeAll(if (self.settings.fast_enabled) "true" else "false");
        try out.writer.writeAll(",\"fastApplies\":");
        try out.writer.writeAll(if (selected.provider != null and std.mem.eql(u8, selected.provider.?, "codex")) "true" else "false");
        try out.writer.writeAll("}");
        return out.written();
    }

    fn cachedSchemaValue(self: *Runtime, alloc: std.mem.Allocator) ?Value {
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.schema_loaded) {
            const raw = self.schema_raw;
            self.mutex.unlock(mer_runtime.io);
            if (raw) |data| return std.json.parseFromSliceLeaky(Value, alloc, data, .{ .allocate = .alloc_always }) catch null;
            return null;
        }
        self.mutex.unlock(mer_runtime.io);

        const raw_loaded = commandOutput(alloc, &.{ self.codegraffBinary(), "--schema" }) catch null;

        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (!self.schema_loaded) {
            if (raw_loaded) |raw| {
                self.schema_raw = self.arena.dupe(u8, raw) catch null;
                self.schema_loaded = self.schema_raw != null;
            }
        }
        const raw = self.schema_raw;
        if (raw) |data| return std.json.parseFromSliceLeaky(Value, alloc, data, .{ .allocate = .alloc_always }) catch null;
        return null;
    }

    fn createConversationLocked(self: *Runtime, workspace: []const u8, cid_raw: []const u8, title_raw: []const u8) *Conversation {
        const conv = self.createConversationWithSessionLocked(workspace, cid_raw, cid_raw, title_raw);
        self.setActiveWorkspaceLocked(conv.workspace_path);
        return conv;
    }

    fn createConversationWithSessionLocked(self: *Runtime, workspace: []const u8, cid_raw: []const u8, session_raw: []const u8, title_raw: []const u8) *Conversation {
        const wpath = self.dupe(workspace);
        const cid = self.dupe(cid_raw);
        const session_name = self.dupe(session_raw);
        const conv = self.arena.create(Conversation) catch @panic("oom");
        conv.* = .{
            .workspace_path = wpath,
            .conversation_id = cid,
            .session_name = session_name,
            .title = self.dupe(title_raw),
            .active_agent_id = self.active_agent_id,
            .updated_at = 0,
        };
        self.conversations.put(cid, conv) catch {};
        return conv;
    }

    fn setActiveWorkspaceLocked(self: *Runtime, path: []const u8) void {
        self.active_workspace_path = path;
        if (self.workspaceIndexLocked(path) == null) {
            self.workspaces.insert(self.arena, 0, .{ .path = path }) catch {};
        }
    }

    fn activateWorkspaceLocked(self: *Runtime, path: []const u8) void {
        self.setActiveWorkspaceLocked(path);
        self.active_conversation_id = self.selected_by_workspace.get(path);
    }

    fn workspaceIndexLocked(self: *Runtime, path: []const u8) ?usize {
        for (self.workspaces.items, 0..) |workspace, i| {
            if (std.mem.eql(u8, workspace.path, path)) return i;
        }
        return null;
    }

    fn turnPromptSelectionLocked(self: *Runtime, conversation_id: []const u8) TurnPromptSelection {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        const conv = self.conversations.get(conversation_id);
        const session_provider = if (conv) |c| c.session_provider else null;
        const session_model = if (conv) |c| c.session_model else null;
        const provider = self.settings.selected_provider orelse session_provider;
        const model = self.settings.selected_model orelse session_model;
        return .{
            .provider = provider,
            .model = model,
            .effort = effectiveReasoningEffort(provider, model, self.settings.selected_effort),
            .fast_enabled = self.settings.fast_enabled,
            .send_model_control = true,
        };
    }

    fn selectedModelLocked(self: *Runtime) ?[]const u8 {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        return self.settings.selected_model;
    }

    fn selectedProviderLocked(self: *Runtime) ?[]const u8 {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        return self.settings.selected_provider;
    }

    fn selectedEffortFor(self: *Runtime, provider: ?[]const u8, model: ?[]const u8) ?[]const u8 {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        return effectiveReasoningEffort(provider, model, self.settings.selected_effort);
    }

    fn codegraffBinary(_: *Runtime) []const u8 {
        const home = homeDir();
        const p1 = std.fmt.allocPrint(std.heap.page_allocator, "{s}/bin/graff", .{home}) catch return "graff";
        if (fileExists(p1)) return p1;
        const p2 = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.local/bin/graff", .{home}) catch return "graff";
        if (fileExists(p2)) return p2;
        inline for (.{ "/opt/homebrew/bin/graff", "/usr/local/bin/graff", "/usr/bin/graff" }) |p| {
            if (fileExists(p)) return p;
        }
        return "graff";
    }

    fn createManagedChatPath(self: *Runtime) []const u8 {
        const home = homeDir();
        const path = self.fmt("{s}/Library/Application Support/dev.codegraff.gui/managed-chats/chat_{d}", .{ home, nowMillis() });
        return path;
    }

    fn loadGuiState(self: *Runtime) void {
        const path = guiStatePath(self.allocator) catch return;
        defer self.allocator.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(data);

        var tmp = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp.deinit();
        const parsed = std.json.parseFromSliceLeaky(Value, tmp.allocator(), data, .{ .allocate = .alloc_always }) catch return;
        if (parsed != .object) return;

        if (arrayField(parsed, "workspaces")) |workspaces| {
            for (workspaces.items) |item| {
                if (item != .object) continue;
                const raw_path = stringField(item, "path") orelse stringField(item, "workspacePath") orelse continue;
                if (!self.stateWorkspaceAvailable(raw_path)) continue;
                const owned_path = self.dupe(raw_path);
                const kind = if (stringField(item, "kind")) |value| self.dupe(value) else "project";
                const display_name = if (stringField(item, "displayName")) |value| self.dupe(value) else null;
                if (self.workspaceIndexLocked(owned_path)) |idx| {
                    self.workspaces.items[idx].kind = kind;
                    self.workspaces.items[idx].display_name = display_name;
                } else {
                    self.workspaces.append(self.arena, .{ .path = owned_path, .kind = kind, .display_name = display_name }) catch {};
                }
                if (stringField(item, "selectedConversationId")) |selected| {
                    self.selected_by_workspace.put(owned_path, self.dupe(selected)) catch {};
                }
                self.scanWorkspaceSessionsLocked(owned_path, true);
                self.ensureWorkspaceSelectionLocked(owned_path);
            }
        }

        const active_workspace = stringField(parsed, "activeWorkspacePath");
        const active_conversation = stringField(parsed, "activeConversationId");
        if (active_workspace) |workspace| {
            if (self.workspaceIndexLocked(workspace) != null) {
                self.active_workspace_path = self.dupe(workspace);
                if (active_conversation) |cid| {
                    if (self.conversations.get(cid)) |conv| {
                        if (std.mem.eql(u8, conv.workspace_path, workspace)) {
                            self.active_conversation_id = conv.conversation_id;
                            self.selected_by_workspace.put(conv.workspace_path, conv.conversation_id) catch {};
                        }
                    }
                }
                if (self.active_conversation_id == null) {
                    self.active_conversation_id = self.selected_by_workspace.get(workspace);
                }
                return;
            }
        }

        if (self.workspaces.items.len > 0) {
            const workspace = self.workspaces.items[0].path;
            self.active_workspace_path = workspace;
            self.active_conversation_id = self.selected_by_workspace.get(workspace);
        }
    }

    fn ensureGuiStateLoaded(self: *Runtime) void {
        if (builtin.is_test) return;
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.gui_state_loaded) return;
        self.gui_state_loaded = true;
        self.loadGuiState();
    }

    fn saveGuiStateLocked(self: *Runtime) void {
        if (builtin.is_test) return;
        ensureSettingsDir(self.allocator);
        const path = guiStatePath(self.allocator) catch return;
        defer self.allocator.free(path);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"activeWorkspacePath\":") catch return;
        writeNullableString(w, self.active_workspace_path) catch return;
        w.writeAll(",\"activeConversationId\":") catch return;
        writeNullableString(w, self.active_conversation_id) catch return;
        w.writeAll(",\"workspaces\":[") catch return;
        for (self.workspaces.items, 0..) |workspace, idx| {
            if (idx > 0) w.writeByte(',') catch return;
            w.writeAll("{\"path\":") catch return;
            writeString(w, workspace.path) catch return;
            w.writeAll(",\"kind\":") catch return;
            writeString(w, workspace.kind) catch return;
            w.writeAll(",\"displayName\":") catch return;
            writeNullableString(w, workspace.display_name) catch return;
            w.writeAll(",\"selectedConversationId\":") catch return;
            writeNullableString(w, self.selected_by_workspace.get(workspace.path)) catch return;
            w.writeAll("}") catch return;
        }
        w.writeAll("]}") catch return;
        std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = out.written() }) catch {};
    }

    fn stateWorkspaceAvailable(self: *Runtime, path: []const u8) bool {
        if (fileExists(path)) return true;
        if (!isGeneratedManagedChatPath(self.allocator, path)) return false;
        ensureDirectory(self.allocator, path) catch return false;
        return true;
    }

    fn scanWorkspaceSessionsLocked(self: *Runtime, workspace_path: []const u8, force: bool) void {
        const now = nowMillis();
        if (!force) {
            if (self.session_scan_cache.get(workspace_path)) |entry| {
                if (entry.scanned_ms + session_scan_cache_ttl_ms > now) return;
            }
        }
        var dir = std.Io.Dir.cwd().openDir(mer_runtime.io, workspace_path, .{ .iterate = true }) catch return;
        defer dir.close(mer_runtime.io);
        var it = dir.iterate();
        while (it.next(mer_runtime.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, session_ext)) continue;
            const base = entry.name[0 .. entry.name.len - session_ext.len];
            if (base.len == 0 or std.mem.indexOfAny(u8, base, "/\\") != null) continue;
            const full_path = sessionFilePath(self.allocator, workspace_path, base) catch continue;
            self.importSessionFileLocked(workspace_path, base, full_path);
            self.allocator.free(full_path);
        }
        self.markSessionScanLocked(workspace_path, now);
        self.ensureWorkspaceSelectionLocked(workspace_path);
    }

    fn markSessionScanLocked(self: *Runtime, workspace_path: []const u8, scanned_ms: i64) void {
        const key = self.allocator.dupe(u8, workspace_path) catch return;
        if (self.session_scan_cache.fetchRemove(workspace_path)) |old| self.allocator.free(old.key);
        self.session_scan_cache.put(key, .{ .scanned_ms = scanned_ms }) catch self.allocator.free(key);
    }

    fn invalidateSessionScanLocked(self: *Runtime, workspace_path: []const u8) void {
        if (self.session_scan_cache.fetchRemove(workspace_path)) |old| self.allocator.free(old.key);
    }

    fn importSessionFileLocked(self: *Runtime, workspace_path: []const u8, session_name: []const u8, full_path: []const u8) void {
        var tmp = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp.deinit();
        const tmp_alloc = tmp.allocator();
        const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, full_path, tmp_alloc, .limited(8 * 1024 * 1024)) catch return;
        const parsed = std.json.parseFromSliceLeaky(Value, tmp_alloc, data, .{ .allocate = .alloc_always }) catch return;
        if (parsed != .object) return;
        self.importSessionValueLocked(workspace_path, session_name, parsed, tmp_alloc);
    }

    fn importSessionValueLocked(self: *Runtime, workspace_path: []const u8, session_name: []const u8, parsed: Value, parse_alloc: std.mem.Allocator) void {
        if (parsed != .object) return;
        const cid = self.conversationIdForSession(workspace_path, session_name);
        const title_value = stringField(parsed, "title");
        const initial_title = if (title_value) |title| (if (title.len > 0) title else session_name) else session_name;
        const title_needs_prompt = title_value == null or isDefaultConversationTitle(initial_title) or std.mem.eql(u8, initial_title, session_name);
        const conv = self.conversations.get(cid) orelse self.createConversationWithSessionLocked(workspace_path, cid, session_name, initial_title);
        conv.session_name = self.dupe(session_name);
        conv.title = self.dupe(initial_title);
        conv.updated_at = intField(parsed, "updated_ms", conv.updated_at);
        conv.goal = if (stringField(parsed, "goal")) |goal| (if (goal.len > 0) self.dupe(goal) else null) else null;
        conv.session_provider = if (stringField(parsed, "provider")) |provider| self.dupe(provider) else conv.session_provider;
        conv.session_model = if (stringField(parsed, "model")) |model| self.dupe(model) else conv.session_model;
        conv.session_strict = boolField(parsed, "strict") orelse conv.session_strict;
        conv.session_ultracode_mode = boolField(parsed, "ultracode_mode") orelse conv.session_ultracode_mode;
        if (parsed.object.get("messages")) |messages_value| {
            conv.cli_messages_json = self.valueJson(messages_value) catch null;
        }

        if (conv.active_request_ids.items.len > 0) return;
        conv.messages.clearRetainingCapacity();
        var first_user_title: ?[]const u8 = null;
        if (arrayField(parsed, "guiMessages")) |gui_messages| {
            for (gui_messages.items, 0..) |message, idx| {
                if (self.importGuiMessageLocked(conv, message, idx)) |user_title| {
                    if (first_user_title == null) first_user_title = user_title;
                }
            }
        } else if (arrayField(parsed, "messages")) |messages| {
            for (messages.items, 0..) |message, idx| {
                if (message != .object) continue;
                const role = stringField(message, "role") orelse continue;
                const raw_text = sessionMessageText(parse_alloc, message);
                const text = std.mem.trim(u8, raw_text, " \t\r\n");
                const reasoning_raw = sessionMessageReasoning(message);
                const reasoning = if (reasoning_raw) |value| std.mem.trim(u8, value, " \t\r\n") else "";
                const rid = self.fmt("{s}-loaded-{d}", .{ conv.conversation_id, idx });
                if (std.mem.eql(u8, role, "user")) {
                    if (text.len == 0) continue;
                    if (first_user_title == null) first_user_title = titleFromPrompt(self.arena, text);
                    conv.messages.append(self.arena, .{
                        .kind = .user,
                        .id = self.fmt("{s}-user", .{rid}),
                        .request_id = rid,
                        .text = self.dupe(text),
                    }) catch {};
                } else if (std.mem.eql(u8, role, "assistant")) {
                    if (reasoning.len > 0) {
                        conv.messages.append(self.arena, .{
                            .kind = .reasoning,
                            .id = self.fmt("{s}-reasoning", .{rid}),
                            .request_id = rid,
                            .text = self.dupe(reasoning),
                        }) catch {};
                    }
                    if (text.len > 0) {
                        conv.messages.append(self.arena, .{
                            .kind = .assistant,
                            .id = self.fmt("{s}-assistant", .{rid}),
                            .request_id = rid,
                            .text = self.dupe(text),
                        }) catch {};
                    }
                }
            }
        }
        if (objectField(parsed, "followup")) |followup| {
            conv.followup = self.importFollowupLocked(conv, followup);
        } else conv.followup = null;
        if (title_needs_prompt and first_user_title != null) {
            conv.title = first_user_title.?;
            self.renameManagedChatWorkspaceLocked(workspace_path, conv.title);
            self.writeConversationSessionFileLocked(conv);
        }
    }

    fn importGuiMessageLocked(self: *Runtime, conv: *Conversation, value: Value, idx: usize) ?[]const u8 {
        if (value != .object) return null;
        const kind_name = stringField(value, "kind") orelse return null;
        const kind = messageKindFromString(kind_name) orelse return null;
        const rid = if (stringField(value, "requestId")) |request_id| self.dupe(request_id) else self.fmt("{s}-loaded-{d}", .{ conv.conversation_id, idx });
        const id = if (stringField(value, "id")) |message_id| self.dupe(message_id) else self.fmt("{s}-{s}", .{ rid, kind_name });
        var message = Message{
            .kind = kind,
            .id = id,
            .request_id = rid,
        };
        switch (kind) {
            .user, .context_compacted, .assistant, .reasoning, .status_output => {
                message.text = if (stringField(value, "text")) |text| self.dupe(text) else "";
            },
            .status => {
                message.title = if (stringField(value, "title")) |title| self.dupe(title) else "Status";
                message.subtitle = if (stringField(value, "subtitle")) |subtitle| self.dupe(subtitle) else null;
                message.category = if (stringField(value, "category")) |category| self.dupe(category) else "info";
            },
            .tool_start => {
                message.name = if (stringField(value, "name")) |name| self.dupe(name) else "tool";
                message.call_id = if (stringField(value, "callId")) |call_id| self.dupe(call_id) else null;
                message.question = if (stringField(value, "question")) |question| self.dupe(question) else "";
                if (objectField(value, "detail")) |detail| message.tool_detail_json = self.valueJson(detail) catch null;
            },
            .tool_end => {
                message.name = if (stringField(value, "name")) |name| self.dupe(name) else "tool";
                message.call_id = if (stringField(value, "callId")) |call_id| self.dupe(call_id) else null;
                message.summary = if (stringField(value, "summary")) |summary| self.dupe(summary) else null;
                message.is_error = boolField(value, "isError") orelse false;
                message.text = if (stringField(value, "text")) |text| self.dupe(text) else "";
                if (objectField(value, "detail")) |detail| message.result_detail_json = self.valueJson(detail) catch null;
            },
            .@"error" => {
                message.error_message = if (stringField(value, "message")) |msg| self.dupe(msg) else "";
            },
        }
        conv.messages.append(self.arena, message) catch return null;
        if (kind == .user and message.text.len > 0) return titleFromPrompt(self.arena, message.text);
        return null;
    }

    fn importFollowupLocked(self: *Runtime, conv: *Conversation, value: Value) ?Followup {
        if (value != .object) return null;
        const followup_id = stringField(value, "followupId") orelse return null;
        const question = stringField(value, "question") orelse "";
        var options: std.ArrayList(FollowupOption) = .empty;
        if (arrayField(value, "options")) |raw_options| {
            for (raw_options.items) |item| {
                if (item != .object) continue;
                const id = stringField(item, "id") orelse continue;
                const label = stringField(item, "label") orelse continue;
                options.append(self.arena, .{ .id = self.dupe(id), .label = self.dupe(label) }) catch {};
            }
        }
        return .{
            .followup_id = self.dupe(followup_id),
            .workspace_path = self.dupe(stringField(value, "workspacePath") orelse conv.workspace_path),
            .conversation_id = conv.conversation_id,
            .request_id = self.dupe(stringField(value, "requestId") orelse ""),
            .kind = self.dupe(stringField(value, "kind") orelse "text"),
            .question = self.dupe(question),
            .options = options.toOwnedSlice(self.arena) catch &.{},
            .call_id = if (stringField(value, "callId")) |call_id| self.dupe(call_id) else self.dupe(followup_id),
        };
    }

    fn valueJson(self: *Runtime, value: Value) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.write(value);
        return out.written();
    }

    fn refreshWorkspaceSessionsLocked(self: *Runtime, force: bool) void {
        for (self.workspaces.items) |workspace| {
            self.scanWorkspaceSessionsLocked(workspace.path, force);
        }
    }

    fn renameManagedChatWorkspaceLocked(self: *Runtime, workspace_path: []const u8, title: []const u8) void {
        if (self.workspaceIndexLocked(workspace_path)) |idx| {
            if (std.mem.eql(u8, self.workspaces.items[idx].kind, "managed_chat")) {
                self.workspaces.items[idx].display_name = self.dupe(title);
            }
        }
    }

    fn ensureWorkspaceSelectionLocked(self: *Runtime, workspace_path: []const u8) void {
        if (self.selected_by_workspace.get(workspace_path)) |selected| {
            if (self.conversations.get(selected)) |conv| {
                if (std.mem.eql(u8, conv.workspace_path, workspace_path)) return;
            }
        }

        var best: ?*Conversation = null;
        var it = self.conversations.iterator();
        while (it.next()) |entry| {
            const conv = entry.value_ptr.*;
            if (!std.mem.eql(u8, conv.workspace_path, workspace_path)) continue;
            if (best == null or conv.updated_at > best.?.updated_at) best = conv;
        }
        if (best) |conv| {
            self.selected_by_workspace.put(workspace_path, conv.conversation_id) catch {};
            if (self.active_workspace_path != null and std.mem.eql(u8, self.active_workspace_path.?, workspace_path)) {
                self.active_conversation_id = conv.conversation_id;
            }
        } else {
            _ = self.selected_by_workspace.remove(workspace_path);
            if (self.active_workspace_path != null and std.mem.eql(u8, self.active_workspace_path.?, workspace_path)) {
                self.active_conversation_id = null;
            }
        }
    }

    fn conversationIdForSession(self: *Runtime, workspace_path: []const u8, session_name: []const u8) []const u8 {
        if (isGuiChatSessionName(session_name)) return self.dupe(session_name);
        const hash = std.hash.Wyhash.hash(0, workspace_path);
        return self.fmt("session-{x:0>16}-{s}", .{ hash, self.sanitizeIdPart(session_name) });
    }

    fn sanitizeIdPart(self: *Runtime, value: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (value) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
            out.append(self.arena, if (ok) c else '_') catch {};
        }
        if (out.items.len == 0) out.appendSlice(self.arena, "session") catch {};
        return out.toOwnedSlice(self.arena) catch self.dupe("session");
    }

    fn ensureConversationSessionFileLocked(self: *Runtime, conv: *Conversation) void {
        const path = sessionFilePath(self.allocator, conv.workspace_path, conv.session_name) catch return;
        defer self.allocator.free(path);
        if (fileExists(path)) return;
        self.writeConversationSessionFileLocked(conv);
    }

    fn refreshCanonicalSessionEnvelopeLocked(self: *Runtime, conv: *Conversation) void {
        if (conv.session_name.len == 0 or std.mem.indexOfAny(u8, conv.session_name, "/\\") != null) return;
        const path = sessionFilePath(self.allocator, conv.workspace_path, conv.session_name) catch return;
        defer self.allocator.free(path);
        var tmp = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp.deinit();
        const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, tmp.allocator(), .limited(8 * 1024 * 1024)) catch return;
        const parsed = std.json.parseFromSliceLeaky(Value, tmp.allocator(), data, .{ .allocate = .alloc_always }) catch return;
        if (parsed != .object) return;
        if (stringField(parsed, "provider")) |provider| conv.session_provider = self.dupe(provider);
        if (stringField(parsed, "model")) |model| conv.session_model = self.dupe(model);
        conv.session_strict = boolField(parsed, "strict") orelse conv.session_strict;
        conv.session_ultracode_mode = boolField(parsed, "ultracode_mode") orelse conv.session_ultracode_mode;
        const messages_value = parsed.object.get("messages") orelse return;
        if (messages_value != .array) return;
        conv.cli_messages_json = self.valueJson(messages_value) catch conv.cli_messages_json;
    }

    fn writeConversationSessionFileLocked(self: *Runtime, conv: *Conversation) void {
        if (conv.session_name.len == 0 or std.mem.indexOfAny(u8, conv.session_name, "/\\") != null) return;
        ensureDirectory(self.allocator, conv.workspace_path) catch {};
        const path = sessionFilePath(self.allocator, conv.workspace_path, conv.session_name) catch return;
        defer self.allocator.free(path);
        const provider = self.settings.selected_provider orelse conv.session_provider orelse "codegraff";
        const selected_model = self.settings.selected_model orelse conv.session_model orelse "deepseek-v4-pro";
        const model = if (selected_model.len == 0) "deepseek-v4-pro" else selected_model;
        const data = self.conversationSessionJsonLocked(conv, provider, model) catch return;
        defer self.allocator.free(data);

        std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = data }) catch {};
        self.invalidateSessionScanLocked(conv.workspace_path);
    }

    fn conversationSessionJsonLocked(self: *Runtime, conv: *Conversation, provider: []const u8, model: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"provider\":");
        try writeString(w, provider);
        try w.writeAll(",\"model\":");
        try writeString(w, model);
        try w.writeAll(",\"strict\":");
        try w.writeAll(if (conv.session_strict) "true" else "false");
        try w.writeAll(",\"ultracode_mode\":");
        try w.writeAll(if (conv.session_ultracode_mode) "true" else "false");
        try w.writeAll(",\"goal\":");
        try writeNullableString(w, conv.goal);
        try w.writeAll(",\"title\":");
        try writeString(w, conv.title);
        try w.writeAll(",\"updated_ms\":");
        try w.print("{d}", .{if (conv.updated_at > 0) conv.updated_at else nowMillis()});
        try w.writeAll(",\"messages\":");
        if (conv.cli_messages_json) |messages_json| {
            try w.writeAll(messages_json);
        } else {
            try w.writeByte('[');
            var first = true;
            for (conv.messages.items) |message| {
                const role: []const u8 = switch (message.kind) {
                    .user => "user",
                    .assistant => "assistant",
                    else => continue,
                };
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":");
                try writeString(w, role);
                try w.writeAll(",\"content\":");
                try writeString(w, message.text);
                try w.writeAll("}");
            }
            try w.writeByte(']');
        }
        try w.writeAll(",\"guiMessages\":");
        try self.writeMessages(w, conv.messages.items);
        try w.writeAll(",\"followup\":");
        try self.writeFollowup(w, conv.followup);
        try w.writeAll("}");
        return try self.allocator.dupe(u8, out.written());
    }

    fn deleteConversationSessionFileLocked(self: *Runtime, conv: *Conversation) void {
        const path = sessionFilePath(self.allocator, conv.workspace_path, conv.session_name) catch return;
        defer self.allocator.free(path);
        std.Io.Dir.cwd().deleteFile(mer_runtime.io, path) catch {};
        self.invalidateSessionScanLocked(conv.workspace_path);
    }

    fn loadPromptSettings(self: *Runtime) void {
        const path = promptSettingsPath(self.allocator) catch return;
        defer self.allocator.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, self.allocator, .limited(64 * 1024)) catch return;
        defer self.allocator.free(data);
        const parsed = std.json.parseFromSliceLeaky(Value, self.arena, data, .{ .allocate = .alloc_always }) catch return;
        if (parsed != .object) return;
        if (stringField(parsed, "selected_provider")) |provider| {
            self.settings.selected_provider = self.dupe(provider);
        }
        if (stringField(parsed, "selected_model")) |model| {
            self.settings.selected_model = self.dupe(model);
        }
        if (stringField(parsed, "selected_effort")) |effort| {
            if (validReasoningEffort(effort)) self.settings.selected_effort = self.dupe(effort);
        }
        if (boolField(parsed, "fast_enabled")) |fast| {
            self.settings.fast_enabled = fast;
        }
    }

    fn ensurePromptSettingsLoaded(self: *Runtime) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.settings_loaded) return;
        self.loadPromptSettings();
        self.settings_loaded = true;
    }

    fn savePromptSettingsLocked(self: *Runtime) void {
        ensureSettingsDir(self.allocator);
        const path = promptSettingsPath(self.allocator) catch return;
        defer self.allocator.free(path);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"selected_provider\":") catch return;
        writeNullableString(&out.writer, self.settings.selected_provider) catch return;
        out.writer.writeAll(",\"selected_model\":") catch return;
        writeNullableString(&out.writer, self.settings.selected_model) catch return;
        out.writer.writeAll(",\"selected_effort\":") catch return;
        writeNullableString(&out.writer, self.settings.selected_effort) catch return;
        out.writer.writeAll(",\"fast_enabled\":") catch return;
        out.writer.writeAll(if (self.settings.fast_enabled) "true" else "false") catch return;
        out.writer.writeAll("}") catch return;
        std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = out.written() }) catch {};
    }

    fn bumpLocked(self: *Runtime) void {
        _ = self.version.fetchAdd(1, .release);
    }

    fn dupe(self: *Runtime, s: []const u8) []const u8 {
        return self.arena.dupe(u8, s) catch @panic("oom");
    }

    fn fmt(self: *Runtime, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, format, args) catch @panic("oom");
    }

    fn uniqueId(self: *Runtime, prefix: []const u8) []const u8 {
        var raw: [8]u8 = undefined;
        mer_runtime.io.random(&raw);
        return self.fmt("{s}-{x:0>16}", .{ prefix, std.mem.readInt(u64, &raw, .big) });
    }
};

fn graffTurnThread(self: *Runtime, conversation_id: []const u8, request_id: []const u8, session_name: []const u8, workspace: []const u8, prompt: []const u8, agent_id: []const u8, plan_mode: bool) void {
    self.streamGraffTurn(conversation_id, request_id, session_name, workspace, prompt, agent_id, plan_mode, true) catch |err| {
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(conversation_id)) |conv| {
            if (self.requestActiveLocked(conversation_id, request_id)) {
                conv.messages.append(self.arena, .{
                    .kind = .@"error",
                    .id = self.fmt("{s}-error", .{request_id}),
                    .request_id = request_id,
                    .error_message = self.fmt("Failed to run graff: {s}", .{@errorName(err)}),
                }) catch {};
                self.writeConversationSessionFileLocked(conv);
            }
        }
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
    };

    self.mutex.lockUncancelable(mer_runtime.io);
    if (self.conversations.get(conversation_id)) |conv| {
        const was_active = self.requestActiveLocked(conversation_id, request_id);
        removeString(&conv.active_request_ids, request_id);
        conv.followup = null;
        self.refreshCanonicalSessionEnvelopeLocked(conv);
        self.writeConversationSessionFileLocked(conv);
        if (was_active) self.emitRequestEventLocked("request-finished", conv, request_id);
    }
    self.bumpLocked();
    self.mutex.unlock(mer_runtime.io);
}

fn commandName(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "/api/")) return path[5..];
    return path;
}

fn parse(req: mer.Request) !Value {
    const body = if (req.body.len == 0) "{}" else req.body;
    return std.json.parseFromSliceLeaky(Value, req.allocator, body, .{});
}

fn stringField(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const item = v.object.get(key) orelse return null;
    return switch (item) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(v: Value, key: []const u8) ?bool {
    if (v != .object) return null;
    const item = v.object.get(key) orelse return null;
    return switch (item) {
        .bool => |b| b,
        else => null,
    };
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |aa| {
        if (b) |bb| return std.mem.eql(u8, aa, bb);
        return false;
    }
    return b == null;
}

fn intField(v: Value, key: []const u8, default: i64) i64 {
    if (v != .object) return default;
    const item = v.object.get(key) orelse return default;
    return switch (item) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => default,
    };
}

fn objectField(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    const item = v.object.get(key) orelse return null;
    return if (item == .object) item else null;
}

fn arrayField(v: Value, key: []const u8) ?std.json.Array {
    if (v != .object) return null;
    const item = v.object.get(key) orelse return null;
    return if (item == .array) item.array else null;
}

fn hasParentPathComponent(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn pathIsWithinRoot(root: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, root, target)) return true;
    if (!std.mem.startsWith(u8, target, root)) return false;
    if (root.len == 0 or target.len <= root.len) return false;
    return target[root.len] == '/';
}

fn stripDataUrlBase64(value: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, value, "data:")) return value;
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return value;
    return value[comma + 1 ..];
}

fn isSafeAttachmentNameByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or
        c == '-' or
        c == '_';
}

fn safeAttachmentFileName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var start: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| start = @max(start, idx + 1);
    if (std.mem.lastIndexOfScalar(u8, name, '\\')) |idx| start = @max(start, idx + 1);
    const base = name[start..];

    var out: std.ArrayList(u8) = .empty;
    for (base) |c| {
        if (out.items.len >= 180) break;
        try out.append(alloc, if (isSafeAttachmentNameByte(c)) c else '_');
    }

    const result = std.mem.trim(u8, out.items, "._-");
    if (result.len == 0) return try alloc.dupe(u8, "attachment");
    return try alloc.dupe(u8, result);
}

fn joinArgs(alloc: std.mem.Allocator, v: Value) ![]const u8 {
    const args = arrayField(v, "args") orelse return "";
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (args.items, 0..) |item, idx| {
        if (item != .string) continue;
        if (idx > 0 and out.written().len > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(item.string);
    }
    return out.written();
}

fn commandText(req: mer.Request, title: []const u8, body: []const u8) mer.Response {
    var out: std.Io.Writer.Allocating = .init(req.allocator);
    out.writer.writeAll("{\"title\":") catch return oom();
    writeString(&out.writer, title) catch return oom();
    out.writer.writeAll(",\"body\":") catch return oom();
    writeString(&out.writer, body) catch return oom();
    out.writer.writeAll(",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"text\",\"payload\":null}") catch return oom();
    return mer.json(out.written());
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.write(s);
}

fn writeNullableString(w: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |value| try writeString(w, value) else try w.writeAll("null");
}

fn writeStringArray(w: *std.Io.Writer, values: []const []const u8) !void {
    try w.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, value);
    }
    try w.writeByte(']');
}

fn selectedOptionLabel(options: []const FollowupOption, id: []const u8) ?[]const u8 {
    for (options) |option| {
        if (std.mem.eql(u8, option.id, id)) return option.label;
    }
    return null;
}

fn answerText(alloc: std.mem.Allocator, followup: Followup, notes_raw: []const u8, selected_ids: ?std.json.Array) ![]const u8 {
    const notes = std.mem.trim(u8, notes_raw, " \t\r\n");
    var out: std.Io.Writer.Allocating = .init(alloc);
    if (selected_ids) |ids| {
        var wrote_option = false;
        for (ids.items) |item| {
            if (item != .string) continue;
            const label = selectedOptionLabel(followup.options, item.string) orelse continue;
            if (wrote_option) try out.writer.writeByte('\n');
            try out.writer.writeAll(label);
            wrote_option = true;
        }
        if (wrote_option and notes.len > 0) try out.writer.writeAll("\n\nNotes: ");
    }
    if (notes.len > 0) try out.writer.writeAll(notes);
    return out.toOwnedSlice();
}

fn answerLineJson(alloc: std.mem.Allocator, followup: Followup, notes: []const u8, selected_ids: ?std.json.Array, cancelled: bool) ![]const u8 {
    const text = if (cancelled) "" else try answerText(alloc, followup, notes, selected_ids);
    defer if (!cancelled) alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeAll("{\"type\":\"answer\",\"text\":");
    try writeString(&out.writer, text);
    try out.writer.writeAll(",\"cancelled\":");
    try out.writer.writeAll(if (cancelled) "true" else "false");
    try out.writer.writeAll(",\"call_id\":");
    try writeString(&out.writer, followup.call_id orelse followup.followup_id);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeAnswerLine(child: *std.process.Child, line: []const u8) !void {
    var wbuf: [4096]u8 = undefined;
    var cw = child.stdin.?.writerStreaming(mer_runtime.io, &wbuf);
    try cw.interface.writeAll(line);
    try cw.interface.writeByte('\n');
    try cw.interface.flush();
}

const PromptSelection = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
};

const TurnPromptSelection = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
    fast_enabled: bool,
    send_model_control: bool,
};

fn schemaValue(alloc: std.mem.Allocator, graff_bin: []const u8) !Value {
    const raw = try commandOutput(alloc, &.{ graff_bin, "--schema" });
    return try std.json.parseFromSliceLeaky(Value, alloc, raw, .{ .allocate = .alloc_always });
}

fn writePromptModels(w: *std.Io.Writer, schema: ?Value) !void {
    const s = schema orelse {
        try w.writeAll("[{\"providerId\":\"codegraff\",\"providerName\":\"Codegraff\",\"modelId\":\"default\",\"modelName\":\"Default\",\"contextLength\":null,\"supportsReasoning\":false,\"reasoningEfforts\":[]}]");
        return;
    };
    const providers = arrayField(s, "providers") orelse {
        try w.writeAll("[]");
        return;
    };
    const models = arrayField(s, "models") orelse {
        try w.writeAll("[]");
        return;
    };

    try w.writeByte('[');
    var first = true;
    for (0..2) |pass| {
        for (providers.items) |provider_value| {
            if (provider_value != .object) continue;
            const provider_id = strFieldObj(provider_value.object, "id") orelse continue;
            if ((pass == 0) != std.mem.eql(u8, provider_id, "codegraff")) continue;
            const env_key = strFieldObj(provider_value.object, "env_key");
            if (!providerConfiguredById(provider_id, env_key)) continue;
            const provider_name = strFieldObj(provider_value.object, "name") orelse provider_id;
            for (models.items) |model_value| {
                if (model_value != .object) continue;
                const model_provider = strFieldObj(model_value.object, "provider") orelse continue;
                if (!std.mem.eql(u8, model_provider, provider_id)) continue;
                const model_name = strFieldObj(model_value.object, "name") orelse continue;
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"providerId\":");
                try writeString(w, provider_id);
                try w.writeAll(",\"providerName\":");
                try writeString(w, provider_name);
                try w.writeAll(",\"modelId\":");
                try writeString(w, model_name);
                try w.writeAll(",\"modelName\":");
                try writeString(w, model_name);
                try w.writeAll(",\"contextLength\":");
                if (model_value.object.get("context")) |context| {
                    if (context == .integer) try w.print("{d}", .{context.integer}) else try w.writeAll("null");
                } else try w.writeAll("null");
                const reasoning = promptModelSupportsReasoning(provider_id, model_name);
                try w.writeAll(",\"supportsReasoning\":");
                try w.writeAll(if (reasoning) "true" else "false");
                try w.writeAll(",\"reasoningEfforts\":");
                try w.writeAll(if (reasoning) "[\"low\",\"medium\",\"high\"]" else "[]");
                try w.writeAll("}");
            }
        }
    }
    try w.writeByte(']');
}

fn resolvePromptSelection(schema: ?Value, selected_provider: ?[]const u8, selected_model: ?[]const u8) PromptSelection {
    const s = schema orelse return .{ .provider = selected_provider orelse "codegraff", .model = selected_model orelse "default" };
    if (selected_provider) |provider| {
        const model = selected_model orelse providerDefaultModel(s, provider);
        if (model) |m| {
            if (configuredModelExists(s, provider, m)) return .{ .provider = provider, .model = m };
        }
    }
    if (firstConfiguredProviderSelection(s, "codegraff")) |sel| return sel;
    const providers = arrayField(s, "providers") orelse return .{ .provider = "codegraff", .model = "default" };
    for (providers.items) |provider_value| {
        if (provider_value != .object) continue;
        const provider_id = strFieldObj(provider_value.object, "id") orelse continue;
        if (firstConfiguredProviderSelection(s, provider_id)) |sel| return sel;
    }
    return .{ .provider = "codegraff", .model = "default" };
}

fn firstConfiguredProviderSelection(schema: Value, provider_id: []const u8) ?PromptSelection {
    const env_key = schemaProviderEnvKey(schema, provider_id);
    if (!providerConfiguredById(provider_id, env_key)) return null;
    if (providerDefaultModel(schema, provider_id)) |default_model| {
        if (modelExists(schema, provider_id, default_model)) return .{ .provider = provider_id, .model = default_model };
    }
    const models = arrayField(schema, "models") orelse return null;
    for (models.items) |model_value| {
        if (model_value != .object) continue;
        const model_provider = strFieldObj(model_value.object, "provider") orelse continue;
        if (!std.mem.eql(u8, model_provider, provider_id)) continue;
        const model_name = strFieldObj(model_value.object, "name") orelse continue;
        return .{ .provider = provider_id, .model = model_name };
    }
    return null;
}

fn configuredModelExists(schema: Value, provider_id: []const u8, model: []const u8) bool {
    const env_key = schemaProviderEnvKey(schema, provider_id);
    return providerConfiguredById(provider_id, env_key) and modelExists(schema, provider_id, model);
}

fn modelExists(schema: Value, provider_id: []const u8, model: []const u8) bool {
    const models = arrayField(schema, "models") orelse return false;
    for (models.items) |model_value| {
        if (model_value != .object) continue;
        const model_provider = strFieldObj(model_value.object, "provider") orelse continue;
        const model_name = strFieldObj(model_value.object, "name") orelse continue;
        if (std.mem.eql(u8, model_provider, provider_id) and std.mem.eql(u8, model_name, model)) return true;
    }
    return false;
}

fn providerDefaultModel(schema: Value, provider_id: []const u8) ?[]const u8 {
    const providers = arrayField(schema, "providers") orelse return null;
    for (providers.items) |provider_value| {
        if (provider_value != .object) continue;
        const id = strFieldObj(provider_value.object, "id") orelse continue;
        if (std.mem.eql(u8, id, provider_id)) return strFieldObj(provider_value.object, "default_model");
    }
    return null;
}

fn schemaProviderEnvKey(schema: Value, provider_id: []const u8) ?[]const u8 {
    const providers = arrayField(schema, "providers") orelse return providerInfo(provider_id).env_key;
    for (providers.items) |provider_value| {
        if (provider_value != .object) continue;
        const id = strFieldObj(provider_value.object, "id") orelse continue;
        if (std.mem.eql(u8, id, provider_id)) return strFieldObj(provider_value.object, "env_key");
    }
    return providerInfo(provider_id).env_key;
}

fn promptModelSupportsReasoning(provider_id: []const u8, model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "grok")) return false;
    return std.mem.eql(u8, provider_id, "codegraff") or
        std.mem.eql(u8, provider_id, "deepseek") or
        std.mem.eql(u8, provider_id, "kimi") or
        std.mem.eql(u8, provider_id, "codex");
}

fn clampTerminalSize(value: i64, default: u16) u16 {
    if (value < 20 or value > 500) return default;
    return @intCast(value);
}

fn terminalSessionJson(alloc: std.mem.Allocator, terminal_id: []const u8, instance_id: []const u8, workspace: []const u8, shell: []const u8, cols: u16, rows: u16, scrollback: []const u8, scrollback_truncated: bool, scrollback_seq: u64) mer.Response {
    var out: std.Io.Writer.Allocating = .init(alloc);
    out.writer.writeAll("{\"terminalId\":") catch return oom();
    writeString(&out.writer, terminal_id) catch return oom();
    out.writer.writeAll(",\"terminalInstanceId\":") catch return oom();
    writeString(&out.writer, instance_id) catch return oom();
    out.writer.writeAll(",\"workspacePath\":") catch return oom();
    writeString(&out.writer, workspace) catch return oom();
    out.writer.writeAll(",\"shell\":") catch return oom();
    writeString(&out.writer, shell) catch return oom();
    out.writer.writeAll(",\"cols\":") catch return oom();
    out.writer.print("{d}", .{cols}) catch return oom();
    out.writer.writeAll(",\"rows\":") catch return oom();
    out.writer.print("{d}", .{rows}) catch return oom();
    out.writer.writeAll(",\"scrollback\":") catch return oom();
    writeString(&out.writer, scrollback) catch return oom();
    out.writer.writeAll(",\"scrollbackTruncated\":") catch return oom();
    out.writer.writeAll(if (scrollback_truncated) "true" else "false") catch return oom();
    out.writer.writeAll(",\"scrollbackSeq\":") catch return oom();
    out.writer.print("{d}", .{scrollback_seq}) catch return oom();
    out.writer.writeAll("}") catch return oom();
    return mer.json(out.written());
}

fn resolveShell() []const u8 {
    if (std.c.getenv("SHELL")) |ptr| {
        const shell = std.mem.span(ptr);
        if (shell.len > 0 and std.mem.startsWith(u8, shell, "/")) return shell;
    }
    if (builtin.os.tag == .macos) return "/bin/zsh";
    return "/bin/sh";
}

fn closeTerminalSession(session: *TerminalSessionState) void {
    if (session.closing.swap(true, .acq_rel)) return;
    session.io_mutex.lockUncancelable(mer_runtime.io);
    defer session.io_mutex.unlock(mer_runtime.io);
    session.proc.terminate();
    session.proc.close();
}

fn terminalReaderMain(rt: *Runtime, session: *TerminalSessionState) void {
    var buffer: [8192]u8 = undefined;
    while (!session.closing.load(.acquire)) {
        const n = session.proc.read(&buffer) catch break;
        if (n == 0) break;
        if (sanitizeTerminalChunk(rt.allocator, session, buffer[0..n])) |chunk| {
            defer rt.allocator.free(chunk);
            if (chunk.len > 0) rt.emitTerminalOutput(session, chunk);
        } else |_| rt.emitTerminalOutput(session, buffer[0..n]);
    }

    const exit_code = session.proc.wait() orelse 0;
    if (session.utf8_pending_len > 0) {
        session.utf8_pending_len = 0;
        rt.emitTerminalOutput(session, "�");
    }
    if (!session.exited.swap(true, .acq_rel)) {
        rt.emitTerminalExit(session, exit_code);
    }
    rt.mutex.lockUncancelable(mer_runtime.io);
    if (rt.terminals.get(session.terminal_id) == session) {
        _ = rt.terminals.remove(session.terminal_id);
    }
    rt.mutex.unlock(mer_runtime.io);
}

fn sanitizeTerminalChunk(alloc: std.mem.Allocator, session: *TerminalSessionState, bytes: []const u8) ![]const u8 {
    var combined: [8196]u8 = undefined;
    var len = session.utf8_pending_len;
    if (len > 0) @memcpy(combined[0..len], session.utf8_pending[0..len]);
    const copy_len = @min(bytes.len, combined.len - len);
    @memcpy(combined[len .. len + copy_len], bytes[0..copy_len]);
    len += copy_len;
    session.utf8_pending_len = 0;

    var complete_len = len;
    var i: usize = 0;
    while (i < len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(combined[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > len) {
            complete_len = i;
            const pending_len = len - i;
            if (pending_len <= session.utf8_pending.len) {
                @memcpy(session.utf8_pending[0..pending_len], combined[i..len]);
                session.utf8_pending_len = pending_len;
            }
            break;
        }
        i += seq_len;
    }
    return sanitizeTerminalOutput(alloc, combined[0..complete_len]);
}

fn sanitizeTerminalOutput(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return try alloc.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(alloc, "�");
            i += 1;
            continue;
        };
        if (i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(alloc, bytes[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(alloc, "�");
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn guiAgentReadOnly(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, "muse") or std.mem.eql(u8, agent_id, "sage");
}

fn guiAgentCoreAgent(agent_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, agent_id, "muse") or std.mem.eql(u8, agent_id, "sage")) return "researcher";
    return null;
}

fn isProtocolAckEvent(ty: []const u8) bool {
    inline for (.{ "system_prompt", "model", "compact", "mode", "agent", "effort", "fast", "ultracode", "score" }) |name| {
        if (std.mem.eql(u8, ty, name)) return true;
    }
    return false;
}

fn validReasoningEffort(level: []const u8) bool {
    return std.mem.eql(u8, level, "low") or
        std.mem.eql(u8, level, "medium") or
        std.mem.eql(u8, level, "high");
}

fn effectiveReasoningEffort(provider: ?[]const u8, model: ?[]const u8, selected: ?[]const u8) ?[]const u8 {
    if (selected) |level| {
        if (validReasoningEffort(level)) return level;
    }
    const provider_id = provider orelse return null;
    const model_id = model orelse return null;
    if (!promptModelSupportsReasoning(provider_id, model_id)) return null;
    return default_reasoning_effort;
}

fn isDefaultConversationTitle(title: []const u8) bool {
    return title.len == 0 or
        std.mem.eql(u8, title, "New chat") or
        std.mem.eql(u8, title, "Untitled session");
}

fn shouldAutoTitleConversation(conv: *const Conversation) bool {
    if (!isDefaultConversationTitle(conv.title)) return false;
    for (conv.messages.items) |message| {
        if (message.kind == .user) return false;
    }
    return true;
}

fn titleFromPrompt(alloc: std.mem.Allocator, prompt: []const u8) []const u8 {
    var words = std.mem.tokenizeAny(u8, prompt, " \t\r\n");
    var out: std.Io.Writer.Allocating = .init(alloc);
    var n: usize = 0;
    while (words.next()) |word| {
        if (n >= 8) break;
        if (n > 0) out.writer.writeByte(' ') catch break;
        out.writer.writeAll(word) catch break;
        n += 1;
    }
    if (out.written().len == 0) return alloc.dupe(u8, "New chat") catch "New chat";
    return out.written();
}

fn workspaceName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

const GitRuntimeStatus = struct {
    root_path: ?[]const u8 = null,
    repo_name: ?[]const u8 = null,
    branch_name: ?[]const u8 = null,
    workspace_kind: ?[]const u8 = null,
    branches: []const []const u8 = &.{},
};

const GitFileStatus = struct {
    path: []const u8,
    status: []const u8,
};

fn renderRuntimeStatusJson(alloc: std.mem.Allocator, p: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const git = gitRuntimeStatus(alloc, p);
    try out.writer.writeAll("{\"workspacePath\":");
    try writeNullableString(&out.writer, if (p.len == 0) null else p);
    try out.writer.writeAll(",\"workspaceName\":");
    try writeNullableString(&out.writer, if (p.len == 0) null else workspaceName(p));
    try out.writer.writeAll(",\"gitRepoName\":");
    try writeNullableString(&out.writer, git.repo_name);
    try out.writer.writeAll(",\"gitBranchName\":");
    try writeNullableString(&out.writer, git.branch_name);
    try out.writer.writeAll(",\"gitBranches\":");
    try writeStringArray(&out.writer, git.branches);
    try out.writer.writeAll(",\"gitWorkspaceKind\":");
    try writeNullableString(&out.writer, git.workspace_kind);
    try out.writer.writeAll(",\"gitMainWorkspacePath\":");
    try writeNullableString(&out.writer, git.root_path);
    try out.writer.writeAll(",\"availableOpenTargets\":[\"file-manager\"],\"configured\":true,\"configurationError\":null}");
    return out.written();
}

fn gitRuntimeStatus(alloc: std.mem.Allocator, workspace: []const u8) GitRuntimeStatus {
    if (workspace.len == 0) return .{};
    const root_raw = gitOutput(alloc, workspace, &.{ "git", "rev-parse", "--show-toplevel" }) catch return .{};
    const root = std.mem.trim(u8, root_raw, " \t\r\n");
    if (root.len == 0) return .{};
    const branch_raw = gitOutput(alloc, workspace, &.{ "git", "branch", "--show-current" }) catch "";
    const branch = std.mem.trim(u8, branch_raw, " \t\r\n");
    const common_raw = gitOutput(alloc, workspace, &.{ "git", "rev-parse", "--git-common-dir" }) catch "";
    const common = std.mem.trim(u8, common_raw, " \t\r\n");
    const is_linked_worktree = common.len > 0 and !std.mem.eql(u8, common, ".git");
    const main_root = if (is_linked_worktree and std.mem.eql(u8, std.fs.path.basename(common), ".git"))
        (std.fs.path.dirname(common) orelse root)
    else
        root;
    return .{
        .root_path = alloc.dupe(u8, main_root) catch main_root,
        .repo_name = alloc.dupe(u8, workspaceName(main_root)) catch workspaceName(main_root),
        .branch_name = if (branch.len == 0) null else alloc.dupe(u8, branch) catch branch,
        .workspace_kind = if (is_linked_worktree) "worktree" else "local",
        .branches = gitBranches(alloc, workspace) catch &.{},
    };
}

fn worktreePathForBranch(alloc: std.mem.Allocator, main_workspace: []const u8, branch: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(main_workspace) orelse ".";
    const base = workspaceName(main_workspace);
    var safe: std.ArrayList(u8) = .empty;
    defer safe.deinit(alloc);
    for (branch) |ch| {
        try safe.append(alloc, if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '-');
    }
    if (safe.items.len == 0) try safe.appendSlice(alloc, "branch");
    const dirname = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ base, safe.items });
    return std.fs.path.join(alloc, &.{ parent, dirname });
}

fn gitBranches(alloc: std.mem.Allocator, workspace: []const u8) ![]const []const u8 {
    const raw = try gitOutput(alloc, workspace, &.{ "git", "branch", "--format=%(refname:short)" });
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try list.append(alloc, try alloc.dupe(u8, trimmed));
    }
    return list.toOwnedSlice(alloc);
}

fn gitStatusFiles(alloc: std.mem.Allocator, workspace: []const u8) ![]const GitFileStatus {
    if (workspace.len == 0) return &.{};
    const raw = try gitOutput(alloc, workspace, &.{ "git", "status", "--short" });
    var list: std.ArrayList(GitFileStatus) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const status = std.mem.trim(u8, line[0..2], " \t\r\n");
        const path_part = std.mem.trim(u8, line[3..], " \t\r\n");
        if (path_part.len == 0) continue;
        const display_path = if (std.mem.lastIndexOf(u8, path_part, " -> ")) |idx| path_part[idx + 4 ..] else path_part;
        if (std.mem.eql(u8, display_path, ".claude/") or std.mem.startsWith(u8, display_path, ".claude/")) continue;
        try list.append(alloc, .{
            .path = try alloc.dupe(u8, display_path),
            .status = try alloc.dupe(u8, if (status.len == 0) "modified" else gitStatusLabel(status)),
        });
    }
    return list.toOwnedSlice(alloc);
}

fn runGitMutation(alloc: std.mem.Allocator, workspace: []const u8, cmd: []const u8, input: Value) !void {
    if (std.mem.eql(u8, cmd, "checkout_git_branch")) {
        const branch = validatedGitBranchName(input) catch |err| return err;
        _ = try gitOutput(alloc, workspace, &.{ "git", "switch", branch });
        return;
    }
    if (std.mem.eql(u8, cmd, "create_git_branch")) {
        const branch = validatedGitBranchName(input) catch |err| return err;
        _ = try gitOutput(alloc, workspace, &.{ "git", "switch", "-c", branch });
        return;
    }
    if (std.mem.eql(u8, cmd, "commit_git_changes")) {
        const message = stringField(input, "message") orelse return error.MissingCommitMessage;
        if (std.mem.trim(u8, message, " \t\r\n").len == 0) return error.MissingCommitMessage;
        return error.CommitRequiresExplicitStaging;
    }
    if (std.mem.eql(u8, cmd, "push_git_branch")) {
        const git = gitRuntimeStatus(alloc, workspace);
        const branch = git.branch_name orelse return error.MissingBranchName;
        if (!isSafeGitBranchName(branch)) return error.InvalidBranchName;
        const refspec = try std.fmt.allocPrint(alloc, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch });
        _ = try gitOutput(alloc, workspace, &.{ "git", "push", "-u", "origin", refspec });
        return;
    }
    return error.UnsupportedGitMutation;
}

fn validatedGitBranchName(input: Value) ![]const u8 {
    const branch = stringField(input, "branchName") orelse return error.MissingBranchName;
    if (!isSafeGitBranchName(branch)) return error.InvalidBranchName;
    return branch;
}

fn isSafeGitBranchName(branch: []const u8) bool {
    if (branch.len == 0 or branch[0] == '-' or branch[0] == '/' or branch[branch.len - 1] == '/' or branch[branch.len - 1] == '.') return false;
    if (std.mem.startsWith(u8, branch, ".") or std.mem.endsWith(u8, branch, ".lock")) return false;
    if (std.mem.indexOf(u8, branch, "..") != null or std.mem.indexOf(u8, branch, "@{") != null or std.mem.indexOf(u8, branch, "//") != null) return false;
    for (branch) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '/' or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn gitMutationErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingBranchName => "missing branchName",
        error.InvalidBranchName => "invalid branchName",
        error.MissingCommitMessage => "missing commit message",
        error.CommitRequiresExplicitStaging => "committing from the GUI backend is disabled until explicit reviewed-file staging is implemented",
        error.UnsupportedGitMutation => "unsupported git operation",
        else => "git operation failed",
    };
}

fn gitStatusLabel(status: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, status, '?') != null) return "untracked";
    if (std.mem.indexOfScalar(u8, status, 'A') != null) return "added";
    if (std.mem.indexOfScalar(u8, status, 'D') != null) return "deleted";
    if (std.mem.indexOfScalar(u8, status, 'R') != null) return "renamed";
    if (std.mem.indexOfScalar(u8, status, 'C') != null) return "copied";
    if (std.mem.indexOfScalar(u8, status, 'U') != null) return "conflict";
    return "modified";
}

fn gitOutput(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]const u8 {
    var resolved_argv: std.ArrayList([]const u8) = .empty;
    defer resolved_argv.deinit(alloc);
    try resolved_argv.append(alloc, "/usr/bin/env");
    try resolved_argv.append(alloc, try std.fmt.allocPrint(alloc, "HOME={s}", .{homeDir()}));
    try resolved_argv.append(alloc, try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}/.config", .{homeDir()}));
    try resolved_argv.append(alloc, "/usr/bin/git");
    const tail = if (argv.len > 0 and std.mem.eql(u8, argv[0], "git")) argv[1..] else argv;
    for (tail) |arg| try resolved_argv.append(alloc, arg);
    var child = try std.process.spawn(mer_runtime.io, .{
        .argv = resolved_argv.items,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const out_file = child.stdout orelse return error.GitFailed;
    var rbuf: [16 * 1024]u8 = undefined;
    var reader = out_file.readerStreaming(mer_runtime.io, &rbuf);
    const output = try reader.interface.allocRemaining(alloc, .limited(512 * 1024));
    const term = try child.wait(mer_runtime.io);
    if (term != .exited or term.exited != 0) return error.GitFailed;
    return output;
}

fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn nowSeconds() i64 {
    return @divTrunc(nowMillis(), 1000);
}

fn firstLine(alloc: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) return alloc.dupe(u8, trimmed[0..@min(trimmed.len, 160)]) catch null;
    }
    return null;
}

fn removeString(list: *std.ArrayList([]const u8), value: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], value)) {
            _ = list.swapRemove(i);
        } else i += 1;
    }
}

fn promptSettingsPath(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.codegraff-gui/prompt-settings.json", .{homeDir()});
}

fn guiStatePath(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.codegraff-gui/state.json", .{homeDir()});
}

fn themeSettingsPath(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.codegraff-gui/theme-settings.json", .{homeDir()});
}

fn legacyThemeSettingsPath(_: std.mem.Allocator) []const u8 {
    return "/tmp/.codegraff-gui/theme-settings.json";
}

fn ensureSettingsDir(alloc: std.mem.Allocator) void {
    ensureDirectory(alloc, std.fmt.allocPrint(alloc, "{s}/.codegraff-gui", .{homeDir()}) catch return) catch {};
}

fn ensureDirectory(_: std.mem.Allocator, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(mer_runtime.io, path);
}

fn validThemeMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "light") or std.mem.eql(u8, mode, "dark");
}

fn validThemePreset(preset: []const u8) bool {
    return std.mem.eql(u8, preset, "warm-graphite") or
        std.mem.eql(u8, preset, "slate") or
        std.mem.eql(u8, preset, "nord") or
        std.mem.eql(u8, preset, "forest");
}

fn readThemeSettings(alloc: std.mem.Allocator) ![]const u8 {
    const path = try themeSettingsPath(alloc);
    const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, alloc, .limited(16 * 1024)) catch {
        const legacy_path = legacyThemeSettingsPath(alloc);
        const legacy_data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, legacy_path, alloc, .limited(16 * 1024)) catch {
            return "{\"mode\":null,\"preset\":null}";
        };
        ensureSettingsDir(alloc);
        std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = legacy_data }) catch {};
        return normalizeThemeSettingsJson(alloc, legacy_data);
    };
    return normalizeThemeSettingsJson(alloc, data);
}

fn normalizeThemeSettingsJson(alloc: std.mem.Allocator, data: []const u8) ![]const u8 {
    const v = std.json.parseFromSliceLeaky(Value, alloc, data, .{ .allocate = .alloc_always }) catch {
        return "{\"mode\":null,\"preset\":null}";
    };
    if (v != .object) return "{\"mode\":null,\"preset\":null}";
    const mode = stringField(v, "mode");
    const preset = stringField(v, "preset");
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeAll("{\"mode\":");
    try writeNullableString(&out.writer, if (mode) |m| (if (validThemeMode(m)) m else null) else null);
    try out.writer.writeAll(",\"preset\":");
    try writeNullableString(&out.writer, if (preset) |p| (if (validThemePreset(p)) p else null) else null);
    try out.writer.writeAll("}");
    return out.written();
}

fn writeThemeSettings(alloc: std.mem.Allocator, mode: []const u8, preset: []const u8) !void {
    ensureSettingsDir(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeAll("{\"mode\":");
    try writeString(&out.writer, mode);
    try out.writer.writeAll(",\"preset\":");
    try writeString(&out.writer, preset);
    try out.writer.writeAll("}");
    try std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = try themeSettingsPath(alloc), .data = out.written() });
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(mer_runtime.io, path, .{}) catch return false;
    return true;
}

fn generatedManagedChatsRoot(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/dev.codegraff.gui/managed-chats/", .{homeDir()});
}

fn isGeneratedManagedChatPath(alloc: std.mem.Allocator, path: []const u8) bool {
    const root = generatedManagedChatsRoot(alloc) catch return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    const name = path[root.len..];
    if (!std.mem.startsWith(u8, name, "chat_")) return false;
    const suffix = name["chat_".len..];
    if (suffix.len == 0) return false;
    for (suffix) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn sessionFilePath(alloc: std.mem.Allocator, workspace_path: []const u8, session_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ workspace_path, session_name, session_ext });
}

fn mcpConfigPath(alloc: std.mem.Allocator, workspace_path: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ workspace_path, ".mcp.json" });
}

fn renderMcpSettingsJson(alloc: std.mem.Allocator, workspace: ?[]const u8) ![]const u8 {
    const path = if (workspace) |w| try mcpConfigPath(alloc, w) else null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeAll("{\"servers\":[");
    if (path) |config_path| {
        const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, config_path, alloc, .limited(1024 * 1024)) catch null;
        if (data) |json| {
            var tmp = std.heap.ArenaAllocator.init(alloc);
            defer tmp.deinit();
            const parsed = std.json.parseFromSliceLeaky(Value, tmp.allocator(), json, .{ .allocate = .alloc_always }) catch null;
            if (parsed) |value| if (objectField(value, "mcpServers")) |servers| {
                var first = true;
                var it = servers.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    if (!first) try out.writer.writeByte(',');
                    first = false;
                    try writeMcpServerSummary(&out.writer, entry.key_ptr.*, entry.value_ptr.*);
                }
            };
        }
    }
    try out.writer.writeAll("]}");
    return out.written();
}

fn writeMcpServerSummary(w: *std.Io.Writer, name: []const u8, server: Value) !void {
    const command = stringField(server, "command") orelse stringField(server, "url") orelse "";
    try w.writeAll("{\"name\":");
    try writeString(w, name);
    try w.writeAll(",\"serverType\":");
    try writeString(w, if (stringField(server, "url") != null) "http" else "stdio");
    try w.writeAll(",\"target\":");
    try writeString(w, command);
    try w.writeAll(",\"isDisabled\":");
    try w.writeAll(if (boolField(server, "disabled") orelse false) "true" else "false");
    try w.writeAll(",\"toolCount\":0,\"tools\":[],\"error\":null,\"authStatus\":null}");
}

fn writeMcpConfig(alloc: std.mem.Allocator, workspace: []const u8, json_text: []const u8) !void {
    const path = try mcpConfigPath(alloc, workspace);
    try std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = json_text });
}

fn removeMcpServerFromConfig(alloc: std.mem.Allocator, workspace: []const u8, name: []const u8) !void {
    const path = try mcpConfigPath(alloc, workspace);
    const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, alloc, .limited(1024 * 1024)) catch return error.McpConfigNotFound;
    var parsed = try std.json.parseFromSlice(Value, alloc, data, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpConfig;
    const servers_ptr = parsed.value.object.getPtr("mcpServers") orelse return error.InvalidMcpConfig;
    if (servers_ptr.* != .object) return error.InvalidMcpConfig;
    if (!servers_ptr.object.swapRemove(name)) return error.McpServerNotFound;
    var out: std.Io.Writer.Allocating = .init(alloc);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(parsed.value);
    try std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = out.written() });
}

fn messageKindFromString(value: []const u8) ?Message.Kind {
    inline for (.{ "user", "context_compacted", "assistant", "reasoning", "status", "status_output", "tool_start", "tool_end", "error" }) |name| {
        if (std.mem.eql(u8, value, name)) return std.meta.stringToEnum(Message.Kind, name).?;
    }
    return null;
}

fn isGuiChatSessionName(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "chat-")) return false;
    const suffix = value["chat-".len..];
    if (suffix.len != 16) return false;
    for (suffix) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!hex) return false;
    }
    return true;
}

fn sessionMessageReasoning(message: Value) ?[]const u8 {
    if (message != .object) return null;
    if (message.object.get("reasoning_content")) |value| if (value == .string) return value.string;
    if (message.object.get("reasoning")) |value| if (value == .string) return value.string;
    return null;
}

fn sessionMessageText(alloc: std.mem.Allocator, message: Value) []const u8 {
    if (message != .object) return "";
    const content = message.object.get("content") orelse return "";
    if (content == .string) return content.string;
    if (content != .array) return "";

    var out: std.ArrayList(u8) = .empty;
    for (content.array.items) |part| {
        if (part != .object) continue;
        const text = sessionContentText(part) orelse continue;
        if (text.len == 0) continue;
        if (out.items.len > 0) out.append(alloc, '\n') catch return out.items;
        out.appendSlice(alloc, text) catch return out.items;
    }
    return out.items;
}

fn sessionContentText(part: Value) ?[]const u8 {
    if (part != .object) return null;
    inline for (.{ "text", "input_text", "output_text" }) |field| {
        if (part.object.get(field)) |value| if (value == .string) return value.string;
    }
    return null;
}

const DeviceStart = struct {
    provider: []const u8,
    auth_session_id: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: []const u8,
    user_code: []const u8,
    expires_in_seconds: ?i64,
};

const codegraff_device_base = "https://gateway.codegraff.com";
const codegraff_key_file = ".simple-harness-codegraff.json";
const kimi_oauth_host = "https://auth.kimi.com";
const kimi_device_auth_url = kimi_oauth_host ++ "/api/oauth/device_authorization";
const kimi_token_url = kimi_oauth_host ++ "/api/oauth/token";
const kimi_client_id = "17e5f671-d194-4dfb-9706-5516cb48c098";
const keychain_service = "simple-harness";
const keys_file = ".simple-harness-keys.json";

fn deviceAuthResponse(req: mer.Request, provider: []const u8, started: DeviceStart) mer.Response {
    _ = provider;
    var out: std.Io.Writer.Allocating = .init(req.allocator);
    out.writer.writeAll("{\"kind\":\"device_code\",\"authSessionId\":") catch return oom();
    writeString(&out.writer, started.auth_session_id) catch return oom();
    out.writer.writeAll(",\"requiresApiKey\":false,\"apiKeyHint\":null,\"urlParameters\":[],\"verificationUri\":") catch return oom();
    writeNullableString(&out.writer, started.verification_uri) catch return oom();
    out.writer.writeAll(",\"verificationUriComplete\":") catch return oom();
    writeNullableString(&out.writer, started.verification_uri_complete) catch return oom();
    out.writer.writeAll(",\"userCode\":") catch return oom();
    writeNullableString(&out.writer, started.user_code) catch return oom();
    out.writer.writeAll(",\"expiresInSeconds\":") catch return oom();
    if (started.expires_in_seconds) |expires| out.writer.print("{d}", .{expires}) catch return oom() else out.writer.writeAll("null") catch return oom();
    out.writer.writeAll(",\"authorizationUrl\":null}") catch return oom();
    return mer.json(out.written());
}

fn authErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.AuthorizationPending => "Authorization is still pending. Approve the login in your browser, then click Finish setup again.",
        error.AuthorizationDenied => "Authorization was denied.",
        error.AuthorizationExpired => "The authorization code expired. Start setup again.",
        error.KeyStoreFailed => "Failed to store the provider key with graff key set.",
        error.BadAuthResponse => "The provider returned an unexpected auth response.",
        else => "Provider auth failed.",
    };
}

fn startCodegraffDevice(alloc: std.mem.Allocator) !DeviceStart {
    const resp = try httpPostJson(alloc, codegraff_device_base ++ "/v1/device/start", "{\"device_label\":\"codegraff-gui\"}", "application/json");
    const device_code = strFieldObj(resp, "device_code") orelse return error.BadAuthResponse;
    const user_code = strFieldObj(resp, "user_code") orelse "";
    const verification_uri = strFieldObj(resp, "verification_uri") orelse "https://codegraff.com/cli/auth";
    const verification_uri_complete = strFieldObj(resp, "verification_uri_complete") orelse verification_uri;
    return .{
        .provider = "codegraff",
        .auth_session_id = try std.fmt.allocPrint(alloc, "codegraff-device:{s}", .{device_code}),
        .verification_uri = verification_uri,
        .verification_uri_complete = verification_uri_complete,
        .user_code = user_code,
        .expires_in_seconds = intFieldObj(resp, "expires_in", 600),
    };
}

fn completeCodegraffDevice(alloc: std.mem.Allocator, device_code: []const u8) !void {
    const poll_body = try std.fmt.allocPrint(alloc, "{{\"device_code\":\"{s}\"}}", .{device_code});
    const poll = try httpPostJson(alloc, codegraff_device_base ++ "/v1/device/poll", poll_body, "application/json");
    const status = strFieldObj(poll, "status") orelse "pending";
    if (std.mem.eql(u8, status, "ok")) {
        const key = strFieldObj(poll, "api_key") orelse return error.BadAuthResponse;
        return writeCodegraffKey(alloc, key);
    }
    if (std.mem.eql(u8, status, "denied")) return error.AuthorizationDenied;
    if (std.mem.eql(u8, status, "expired")) return error.AuthorizationExpired;
    return error.AuthorizationPending;
}

fn startKimiDevice(alloc: std.mem.Allocator) !DeviceStart {
    const da_body = try std.fmt.allocPrint(alloc, "client_id={s}", .{kimi_client_id});
    const resp = try httpPostJson(alloc, kimi_device_auth_url, da_body, "application/x-www-form-urlencoded");
    const device_code = strFieldObj(resp, "device_code") orelse return error.BadAuthResponse;
    const user_code = strFieldObj(resp, "user_code") orelse "";
    const verify = strFieldObj(resp, "verification_uri_complete") orelse strFieldObj(resp, "verification_uri") orelse "";
    return .{
        .provider = "kimi",
        .auth_session_id = try std.fmt.allocPrint(alloc, "kimi-device:{s}", .{device_code}),
        .verification_uri = verify,
        .verification_uri_complete = verify,
        .user_code = user_code,
        .expires_in_seconds = intFieldObj(resp, "expires_in", 900),
    };
}

fn completeKimiDevice(alloc: std.mem.Allocator, device_code: []const u8) !void {
    const body = try std.fmt.allocPrint(alloc, "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code", .{ kimi_client_id, device_code });
    const resp = try httpPostJson(alloc, kimi_token_url, body, "application/x-www-form-urlencoded");
    if (resp.get("access_token")) |a| if (a == .string and a.string.len > 0) {
        const refresh = strFieldObj(resp, "refresh_token") orelse "";
        const expires_in = intFieldObj(resp, "expires_in", 900);
        return writeKimiAuth(alloc, a.string, refresh, nowSeconds() + expires_in);
    };
    const msg = strFieldObj(resp, "error") orelse "authorization_pending";
    if (std.mem.eql(u8, msg, "authorization_pending") or std.mem.eql(u8, msg, "slow_down")) return error.AuthorizationPending;
    if (std.mem.eql(u8, msg, "expired_token")) return error.AuthorizationExpired;
    return error.BadAuthResponse;
}

fn httpPostJson(alloc: std.mem.Allocator, url: []const u8, body: []const u8, content_type: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = alloc, .io = mer_runtime.io };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &out.writer,
        .headers = .{ .content_type = .{ .override = content_type } },
    });
    const v = try std.json.parseFromSliceLeaky(Value, alloc, out.written(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadAuthResponse;
    return v.object;
}

fn strFieldObj(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn intFieldObj(obj: std.json.ObjectMap, name: []const u8, default: i64) i64 {
    const v = obj.get(name) orelse return default;
    return if (v == .integer) v.integer else default;
}

fn homeDir() []const u8 {
    if (mer_runtime.threaded.environString("HOME")) |home| {
        if (home.len > 0 and !std.mem.eql(u8, home, "/tmp")) return home;
    }
    const alloc = std.heap.page_allocator;
    if (std.c.getenv("HOME")) |home_z| {
        const home = std.mem.span(home_z);
        if (home.len > 0 and !std.mem.eql(u8, home, "/tmp")) return home;
    }
    if (builtin.os.tag == .macos) {
        if (std.c.getenv("USER")) |user_z| {
            const user = std.mem.span(user_z);
            if (user.len > 0) return std.fmt.allocPrint(alloc, "/Users/{s}", .{user}) catch "/tmp";
        }
    }
    return "/tmp";
}

fn commandOutput(alloc: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var child = try std.process.spawn(mer_runtime.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const out_file = child.stdout orelse return error.CommandFailed;
    var rbuf: [8 * 1024]u8 = undefined;
    var reader = out_file.readerStreaming(mer_runtime.io, &rbuf);
    const output = try reader.interface.allocRemaining(alloc, .limited(64 * 1024));
    const term = try child.wait(mer_runtime.io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
    return output;
}

fn writeCodegraffKey(alloc: std.mem.Allocator, key: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ homeDir(), codegraff_key_file });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "api_key", .{ .string = key });
    var out: std.Io.Writer.Allocating = .init(alloc);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(Value{ .object = obj });
    try std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = out.written() });
}

fn kimiAuthPath(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.kimi/credentials/graff-oauth.json", .{homeDir()});
}

fn writeKimiAuth(alloc: std.mem.Allocator, access: []const u8, refresh: []const u8, expires_at: i64) !void {
    const home = homeDir();
    std.Io.Dir.cwd().createDir(mer_runtime.io, try std.fmt.allocPrint(alloc, "{s}/.kimi", .{home}), .default_dir) catch {};
    std.Io.Dir.cwd().createDir(mer_runtime.io, try std.fmt.allocPrint(alloc, "{s}/.kimi/credentials", .{home}), .default_dir) catch {};
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "access_token", .{ .string = access });
    try obj.put(alloc, "refresh_token", .{ .string = refresh });
    try obj.put(alloc, "expires_at", .{ .integer = expires_at });
    var out: std.Io.Writer.Allocating = .init(alloc);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(Value{ .object = obj });
    try std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = try kimiAuthPath(alloc), .data = out.written() });
}

fn storeProviderKey(alloc: std.mem.Allocator, provider: []const u8, key: []const u8) !void {
    const bin = codegraffBinaryPath(alloc);
    var child = try std.process.spawn(mer_runtime.io, .{
        .argv = &.{ bin, "key", "set", provider, key },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(mer_runtime.io);
    if (term != .exited or term.exited != 0) return error.KeyStoreFailed;
}

fn codegraffBinaryPath(alloc: std.mem.Allocator) []const u8 {
    const home = homeDir();
    const p1 = std.fmt.allocPrint(alloc, "{s}/bin/graff", .{home}) catch "graff";
    if (fileExists(p1)) return p1;
    const p2 = std.fmt.allocPrint(alloc, "{s}/.local/bin/graff", .{home}) catch "graff";
    if (fileExists(p2)) return p2;
    inline for (.{ "/opt/homebrew/bin/graff", "/usr/local/bin/graff", "/usr/bin/graff" }) |p| {
        if (fileExists(p)) return p;
    }
    return "graff";
}

fn providerConfigured(env_key: ?[]const u8) bool {
    if (env_key) |key| {
        const alloc = std.heap.page_allocator;
        const zkey = alloc.dupeZ(u8, key) catch return false;
        const value = std.c.getenv(zkey) orelse return false;
        return std.mem.span(value).len > 0;
    }
    return false;
}

fn writeEnvOverride(w: *std.Io.Writer, env_key: ?[]const u8) !void {
    const key = providerCredentialEnvKey(env_key) orelse {
        try w.writeAll("null");
        return;
    };
    if (!providerConfigured(key)) {
        try w.writeAll("null");
        return;
    }
    try w.writeAll("{\"envKey\":");
    try writeString(w, key);
    try w.writeAll(",\"filePath\":null,\"line\":null}");
}

fn providerCredentialEnvKey(env_key: ?[]const u8) ?[]const u8 {
    const key = env_key orelse return null;
    // Core schema exposes CODEX_DISABLED as an implementation sentinel, not a
    // credential source. Codex auth is read from ~/.codex/auth.json instead.
    if (std.mem.eql(u8, key, "CODEX_DISABLED")) return null;
    return key;
}

fn providerConfiguredById(id: []const u8, env_key: ?[]const u8) bool {
    if (providerConfigured(providerCredentialEnvKey(env_key))) return true;
    if (builtin.is_test) return false;
    const alloc = std.heap.page_allocator;
    if (std.mem.eql(u8, id, "codegraff")) return codegraffStored(alloc);
    if (std.mem.eql(u8, id, "codex")) return codexStored(alloc);
    if (std.mem.eql(u8, id, "kimi")) return fileExists(std.fmt.allocPrint(alloc, "{s}/.kimi/credentials/graff-oauth.json", .{homeDir()}) catch return false) or storedKeyExists(alloc, id);
    return storedKeyExists(alloc, id);
}

fn codexStored(alloc: std.mem.Allocator) bool {
    const path = std.fmt.allocPrint(alloc, "{s}/.codex/auth.json", .{homeDir()}) catch return false;
    const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, alloc, .limited(256 * 1024)) catch return false;
    const v = std.json.parseFromSliceLeaky(Value, alloc, data, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    const tokens = v.object.get("tokens") orelse return false;
    if (tokens != .object) return false;
    const access = tokens.object.get("access_token") orelse return false;
    return access == .string and access.string.len > 0;
}

fn codegraffStored(alloc: std.mem.Allocator) bool {
    if (fileExists(std.fmt.allocPrint(alloc, "{s}/{s}", .{ homeDir(), codegraff_key_file }) catch return false)) return true;
    const creds_path = std.fmt.allocPrint(alloc, "{s}/forge/.credentials.json", .{homeDir()}) catch return false;
    const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, creds_path, alloc, .limited(256 * 1024)) catch return false;
    const v = std.json.parseFromSliceLeaky(Value, alloc, data, .{ .allocate = .alloc_always }) catch return false;
    if (v != .array) return false;
    for (v.array.items) |entry| {
        if (entry != .object) continue;
        const provider_id = if (entry.object.get("id")) |p| (if (p == .string) p.string else "") else "";
        if (!std.mem.eql(u8, provider_id, "codegraff")) continue;
        if (entry.object.get("auth_details")) |auth| if (auth == .object)
            if (auth.object.get("api_key")) |key| if (key == .string and key.string.len > 0) return true;
    }
    return false;
}

fn storedKeyExists(alloc: std.mem.Allocator, provider: []const u8) bool {
    if (builtin.os.tag == .macos) {
        var child = std.process.spawn(mer_runtime.io, .{
            .argv = &.{ "security", "find-generic-password", "-s", keychain_service, "-a", provider, "-w" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return false;
        defer _ = child.wait(mer_runtime.io) catch {};
        const f = child.stdout orelse return false;
        var rbuf: [8 * 1024]u8 = undefined;
        var fr = f.readerStreaming(mer_runtime.io, &rbuf);
        const out = fr.interface.allocRemaining(alloc, .limited(64 * 1024)) catch return false;
        return std.mem.trim(u8, out, " \t\r\n").len > 0;
    }
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ homeDir(), keys_file }) catch return false;
    const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, alloc, .limited(64 * 1024)) catch return false;
    const v = std.json.parseFromSliceLeaky(Value, alloc, data, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    if (v.object.get(provider)) |key| return key == .string and key.string.len > 0;
    return false;
}

fn removeStoredProvider(alloc: std.mem.Allocator, provider: []const u8) !void {
    if (std.mem.eql(u8, provider, "codegraff")) {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ homeDir(), codegraff_key_file });
        std.Io.Dir.cwd().deleteFile(mer_runtime.io, path) catch {};
        return;
    }
    if (std.mem.eql(u8, provider, "codex")) {
        const path = try std.fmt.allocPrint(alloc, "{s}/.codex/auth.json", .{homeDir()});
        std.Io.Dir.cwd().deleteFile(mer_runtime.io, path) catch {};
        return;
    }
    if (std.mem.eql(u8, provider, "kimi")) {
        const path = try kimiAuthPath(alloc);
        std.Io.Dir.cwd().deleteFile(mer_runtime.io, path) catch {};
    }
    if (builtin.os.tag == .macos) {
        var child = std.process.spawn(mer_runtime.io, .{
            .argv = &.{ "security", "delete-generic-password", "-s", keychain_service, "-a", provider },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = child.wait(mer_runtime.io) catch {};
        return;
    }
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ homeDir(), keys_file }) catch return;
    const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, path, alloc, .limited(64 * 1024)) catch return;
    var parsed = std.json.parseFromSlice(Value, alloc, data, .{ .allocate = .alloc_always }) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    _ = parsed.value.object.swapRemove(provider);
    var out: std.Io.Writer.Allocating = .init(alloc);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(parsed.value);
    try std.Io.Dir.cwd().writeFile(mer_runtime.io, .{ .sub_path = path, .data = out.written() });
}

fn writeProviderSummariesFromSchema(w: *std.Io.Writer, schema: ?Value) bool {
    const s = schema orelse return false;
    const providers = arrayField(s, "providers") orelse return false;
    w.writeByte('[') catch return false;
    var first = true;
    for (providers.items) |provider_value| {
        if (provider_value != .object) continue;
        const id = strFieldObj(provider_value.object, "id") orelse continue;
        const name = strFieldObj(provider_value.object, "name") orelse id;
        const login = strFieldObj(provider_value.object, "login") orelse providerInfo(id).auth_kind;
        const env_key = strFieldObj(provider_value.object, "env_key");
        if (!first) w.writeByte(',') catch return false;
        first = false;
        writeProviderSummary(w, id, name, login, env_key) catch return false;
    }
    w.writeByte(']') catch return false;
    return true;
}

fn writeFallbackProviderSummaries(w: *std.Io.Writer) !void {
    try w.writeByte('[');
    for (fallback_providers, 0..) |p, idx| {
        if (idx > 0) try w.writeByte(',');
        try writeProviderSummary(w, p.id, p.name, p.auth_kind, p.env_key);
    }
    try w.writeByte(']');
}

fn writeProviderSummary(w: *std.Io.Writer, id: []const u8, name: []const u8, auth_kind: []const u8, env_key: ?[]const u8) !void {
    try w.writeAll("{\"id\":");
    try writeString(w, id);
    try w.writeAll(",\"name\":");
    try writeString(w, name);
    try w.writeAll(",\"configured\":");
    try w.writeAll(if (providerConfiguredById(id, env_key)) "true" else "false");
    try w.writeAll(",\"authMethods\":[{\"kind\":");
    try writeString(w, auth_kind);
    try w.writeAll(",\"label\":");
    try writeProviderAuthLabel(w, id, auth_kind, env_key);
    try w.writeAll("}],\"envOverride\":");
    try writeEnvOverride(w, env_key);
    try w.writeAll("}");
}

fn writeProviderAuthLabel(w: *std.Io.Writer, id: []const u8, auth_kind: []const u8, env_key: ?[]const u8) !void {
    if (std.mem.eql(u8, auth_kind, "codegraff_device")) return writeString(w, "Codegraff device login");
    if (std.mem.eql(u8, auth_kind, "kimi_device")) return writeString(w, "Kimi device login");
    if (std.mem.eql(u8, auth_kind, "codex_device")) return writeString(w, "Shared Codex CLI login (~/.codex/auth.json)");
    if (std.mem.eql(u8, auth_kind, "api_key")) {
        if (providerCredentialEnvKey(env_key)) |key| {
            var label: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer label.deinit();
            try label.writer.writeAll("API key (");
            try label.writer.writeAll(key);
            try label.writer.writeAll(" or graff key set ");
            try label.writer.writeAll(id);
            try label.writer.writeByte(')');
            return writeString(w, label.written());
        }
        return writeString(w, "API key (graff key set)");
    }
    return writeString(w, auth_kind);
}

fn providerSummaryResponse(req: mer.Request, provider: []const u8) mer.Response {
    var out: std.Io.Writer.Allocating = .init(req.allocator);
    const info = providerInfo(provider);
    writeProviderSummary(&out.writer, provider, info.name, info.auth_kind, info.env_key) catch return oom();
    return mer.json(out.written());
}

const Provider = struct { id: []const u8, name: []const u8, env_key: ?[]const u8, auth_kind: []const u8, auth_label: []const u8 };
const fallback_providers = [_]Provider{
    .{ .id = "codegraff", .name = "Codegraff", .env_key = "CODEGRAFF_API_KEY", .auth_kind = "codegraff_device", .auth_label = "Codegraff device login" },
    .{ .id = "anthropic", .name = "Anthropic", .env_key = "ANTHROPIC_API_KEY", .auth_kind = "api_key", .auth_label = "API key (ANTHROPIC_API_KEY or graff key set anthropic)" },
    .{ .id = "deepseek", .name = "DeepSeek", .env_key = "DEEPSEEK_API_KEY", .auth_kind = "api_key", .auth_label = "API key (DEEPSEEK_API_KEY or graff key set deepseek)" },
    .{ .id = "openai", .name = "OpenAI", .env_key = "OPENAI_API_KEY", .auth_kind = "api_key", .auth_label = "API key (OPENAI_API_KEY or graff key set openai)" },
    .{ .id = "minimax", .name = "MiniMax", .env_key = "MINIMAX_API_KEY", .auth_kind = "api_key", .auth_label = "API key (MINIMAX_API_KEY or graff key set minimax)" },
    .{ .id = "xiaomi", .name = "Xiaomi", .env_key = "XIAOMI_API_KEY", .auth_kind = "api_key", .auth_label = "API key (XIAOMI_API_KEY or graff key set xiaomi)" },
    .{ .id = "kimi", .name = "Kimi", .env_key = "KIMI_API_KEY", .auth_kind = "kimi_device", .auth_label = "Kimi device login" },
    .{ .id = "moonshot", .name = "Moonshot", .env_key = "MOONSHOT_API_KEY", .auth_kind = "api_key", .auth_label = "API key (MOONSHOT_API_KEY or graff key set moonshot)" },
    .{ .id = "xai", .name = "xAI", .env_key = "XAI_API_KEY", .auth_kind = "api_key", .auth_label = "API key (XAI_API_KEY or graff key set xai)" },
    .{ .id = "zai", .name = "Z.AI", .env_key = "ZAI_API_KEY", .auth_kind = "api_key", .auth_label = "API key (ZAI_API_KEY or graff key set zai)" },
    .{ .id = "codex", .name = "Codex / ChatGPT", .env_key = null, .auth_kind = "codex_device", .auth_label = "Shared Codex CLI login (~/.codex/auth.json)" },
};

fn providerInfo(id: []const u8) Provider {
    for (fallback_providers) |p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return .{ .id = id, .name = id, .env_key = null, .auth_kind = "api_key", .auth_label = "API key" };
}

fn bad(req: mer.Request, msg: []const u8) mer.Response {
    var out: std.Io.Writer.Allocating = .init(req.allocator);
    out.writer.writeAll("{\"error\":") catch return oom();
    writeString(&out.writer, msg) catch return oom();
    out.writer.writeAll("}") catch return oom();
    return mer.Response.init(.bad_request, .json, out.written());
}

fn badJson(req: mer.Request) mer.Response {
    return bad(req, "body must be JSON");
}

fn oom() mer.Response {
    return mer.Response.init(.internal_server_error, .json, "{\"error\":\"out of memory\"}");
}

const commands_json =
    \\[{"name":"help","usage":"Show available commands.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":false,"argumentHint":null,"resultKind":"text"},{"name":"agent","usage":"Show active agent.","aliases":["agents"],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":false,"argumentHint":null,"resultKind":"agents"},{"name":"bash","usage":"Show a shell command for terminal execution.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"terminalAssisted","requiresWorkspace":true,"requiresConversation":false,"argumentHint":"<command>","resultKind":"text"},{"name":"goal","usage":"Set/show the current objective.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":true,"argumentHint":"<objective|clear>","resultKind":"text"},{"name":"loop","usage":"Run an autonomous plan-act-verify pass.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":true,"argumentHint":"<prompt>","resultKind":"snapshot"},{"name":"compact","usage":"Compact current conversation.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":true,"argumentHint":null,"resultKind":"snapshot"},{"name":"workspace-status","usage":"Show git status.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":false,"argumentHint":null,"resultKind":"workspaceStatus"},{"name":"workspace-info","usage":"Show workspace metadata.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":false,"argumentHint":null,"resultKind":"workspaceInfo"},{"name":"workspace-query","usage":"Search workspace semantically.","aliases":["workspace-search"],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":false,"argumentHint":"<query>","resultKind":"workspaceSearch"},{"name":"workflow","usage":"Draft a reviewable workflow.","aliases":[],"kind":"workflow","value":null,"isAgentSwitch":false,"executionKind":"modal","requiresWorkspace":false,"requiresConversation":false,"argumentHint":"<goal>","resultKind":"workflowDraft"},{"name":"reasoning-effort","usage":"Set reasoning effort.","aliases":["effort","reasoning"],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":false,"argumentHint":"<low|medium|high>","resultKind":"text"},{"name":"mcp","usage":"Show MCP server status.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":false,"argumentHint":null,"resultKind":"mcp"}]
;

pub fn handleEvents(
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    io: std.Io,
) bool {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const target = std_req.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    if (!std.mem.eql(u8, path, "/events")) return false;
    if (std_req.head.method != .GET) return false;

    var header_buf: [512]u8 = undefined;
    var bw = std_req.respondStreaming(&header_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "connection", .value = "keep-alive" },
            },
        },
    }) catch return true;

    if (!writeFrame(&bw, ": connected\n\n")) return true;
    var seen = self.version.load(.acquire);
    var force_snapshot = false;
    var seen_event_seq: u64 = if (requestHeaderValue(std_req.head_buffer, "last-event-id")) |last_id| blk: {
        const requested = std.fmt.parseInt(u64, std.mem.trim(u8, last_id, " \t\r\n"), 10) catch 0;
        // Any reconnect may have missed version-only snapshot changes (tool_start,
        // followup, errors), because only native events carry SSE ids.
        force_snapshot = true;
        self.event_mutex.lockUncancelable(io);
        defer self.event_mutex.unlock(io);
        break :blk self.clampRequestedEventSeqLocked(requested);
    } else blk: {
        self.event_mutex.lockUncancelable(io);
        defer self.event_mutex.unlock(io);
        break :blk if (self.next_event_seq > 0) self.next_event_seq - 1 else 0;
    };
    while (true) {
        _ = io.sleep(.fromMilliseconds(16), .awake) catch break;

        var pending: std.ArrayList(SseEvent) = .empty;
        self.event_mutex.lockUncancelable(io);
        for (self.events.items) |ev| {
            if (ev.seq <= seen_event_seq) continue;
            const cloned_name = alloc.dupe(u8, ev.name) catch break;
            const cloned_data = alloc.dupe(u8, ev.data) catch {
                alloc.free(cloned_name);
                break;
            };
            pending.append(alloc, .{ .seq = ev.seq, .name = cloned_name, .data = cloned_data }) catch {
                alloc.free(cloned_name);
                alloc.free(cloned_data);
                break;
            };
        }
        self.event_mutex.unlock(io);
        var write_ok = true;
        for (pending.items) |ev| {
            if (!writeSseEventFrame(&bw, ev)) {
                write_ok = false;
                break;
            }
            seen_event_seq = ev.seq;
        }
        for (pending.items) |ev| {
            alloc.free(ev.name);
            alloc.free(ev.data);
        }
        pending.deinit(alloc);
        if (!write_ok) break;

        const current = self.version.load(.acquire);
        if (current == seen and !force_snapshot) continue;
        seen = current;
        force_snapshot = false;
        var snapshot_arena = std.heap.ArenaAllocator.init(alloc);
        defer snapshot_arena.deinit();
        const json = self.snapshotJson(snapshot_arena.allocator()) catch break;
        if (!writeSseNamedDataFrame(&bw, "session-updated", json)) break;
    }
    bw.end() catch {};
    return true;
}

fn requestHeaderValue(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head_buffer, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..sep], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[sep + 1 ..], " \t");
    }
    return null;
}

fn writeSseEventFrame(bw: *std.http.BodyWriter, ev: SseEvent) bool {
    bw.writer.print("id: {d}\nevent: {s}\ndata: {s}\n\n", .{ ev.seq, ev.name, ev.data }) catch return false;
    bw.writer.flush() catch return false;
    bw.http_protocol_output.flush() catch return false;
    return true;
}

fn writeSseNamedDataFrame(bw: *std.http.BodyWriter, name: []const u8, data: []const u8) bool {
    bw.writer.print("event: {s}\ndata: {s}\n\n", .{ name, data }) catch return false;
    bw.writer.flush() catch return false;
    bw.http_protocol_output.flush() catch return false;
    return true;
}

fn writeFrame(bw: *std.http.BodyWriter, frame: []const u8) bool {
    bw.writer.writeAll(frame) catch return false;
    bw.writer.flush() catch return false;
    bw.http_protocol_output.flush() catch return false;
    return true;
}

test "protocol ack events from core schema are consumed without unknown rows" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const conv = rt.createConversationLocked("/tmp/codegraff-gui-protocol-ack", "chat-protocol-ack", "Protocol ack");
    conv.session_name = "";
    try conv.active_request_ids.append(rt.arena, "request-1");

    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const model_ack = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"type\":\"model\",\"ok\":true,\"provider\":\"codex\",\"model\":\"gpt-5\",\"context\":1000}", .{ .allocate = .alloc_always });
    try std.testing.expect(rt.handleProtocolAck(conv.conversation_id, "request-1", "model", model_ack));
    try std.testing.expectEqual(@as(usize, 0), conv.messages.items.len);
    try std.testing.expectEqualStrings("codex", conv.session_provider.?);
    try std.testing.expectEqualStrings("gpt-5", conv.session_model.?);

    const mode_ack = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"type\":\"mode\",\"ok\":true,\"mode\":\"plan\"}", .{ .allocate = .alloc_always });
    try std.testing.expect(rt.handleProtocolAck(conv.conversation_id, "request-1", "mode", mode_ack));
    try std.testing.expect(conv.plan_mode);

    inline for (.{ "system_prompt", "compact", "agent", "effort", "fast", "ultracode", "score" }) |ty| {
        const event = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"type\":\"ack\",\"ok\":true}", .{ .allocate = .alloc_always });
        try std.testing.expect(rt.handleProtocolAck(conv.conversation_id, "request-1", ty, event));
    }
    try std.testing.expectEqual(@as(usize, 0), conv.messages.items.len);
    try std.testing.expect(!rt.handleProtocolAck(conv.conversation_id, "request-1", "future_event", model_ack));
}

test "appendProtocolWarning preserves malformed protocol rows" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const conv = rt.createConversationLocked("/tmp/codegraff-gui-protocol-warning", "chat-protocol", "Protocol warning");
    conv.session_name = "";
    try conv.active_request_ids.append(rt.arena, "request-1");

    rt.appendProtocolWarning(conv.conversation_id, "request-1", "warning-1", "Malformed graff JSONL event", "not json");

    try std.testing.expectEqual(@as(usize, 2), conv.messages.items.len);
    try std.testing.expectEqual(.status, conv.messages.items[0].kind);
    try std.testing.expectEqualStrings("Malformed graff JSONL event", conv.messages.items[0].title);
    try std.testing.expectEqualStrings("debug", conv.messages.items[0].category);
    try std.testing.expectEqual(.status_output, conv.messages.items[1].kind);
    try std.testing.expectEqualStrings("not json", conv.messages.items[1].text);

    const invalid = [_]u8{0xff};
    rt.appendProtocolWarning(conv.conversation_id, "request-1", "warning-2", "Malformed graff JSONL event", invalid[0..]);
    try std.testing.expectEqualStrings("�", conv.messages.items[3].text);

    const capped = rt.createConversationLocked("/tmp/codegraff-gui-protocol-warning-cap", "chat-protocol-cap", "Protocol warning cap");
    capped.session_name = "";
    try capped.active_request_ids.append(rt.arena, "request-2");
    var count: usize = 0;
    for (0..protocol_warning_limit_per_turn + 3) |idx| {
        count = rt.appendProtocolWarningLimited(capped.conversation_id, "request-2", count, rt.fmt("warning-{d}", .{idx}), "Malformed graff JSONL event", "bad line");
    }
    try std.testing.expectEqual(@as(usize, (protocol_warning_limit_per_turn + 1) * 2), capped.messages.items.len);
    try std.testing.expectEqualStrings("Additional graff protocol events suppressed", capped.messages.items[protocol_warning_limit_per_turn * 2].title);
}

test "git mutation validation fails before shelling out" {
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const empty = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{}", .{ .allocate = .alloc_always });
    const blank_branch = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"branchName\":\"  \"}", .{ .allocate = .alloc_always });
    const blank_message = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"message\":\"  \"}", .{ .allocate = .alloc_always });
    const commit_message = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"message\":\"commit reviewed changes\"}", .{ .allocate = .alloc_always });
    const option_branch = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"branchName\":\"-f\"}", .{ .allocate = .alloc_always });
    const refspec_branch = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"branchName\":\":main\"}", .{ .allocate = .alloc_always });

    try std.testing.expectError(error.MissingBranchName, runGitMutation(std.testing.allocator, "/tmp/workspace", "checkout_git_branch", empty));
    try std.testing.expectError(error.InvalidBranchName, runGitMutation(std.testing.allocator, "/tmp/workspace", "create_git_branch", blank_branch));
    try std.testing.expectError(error.MissingCommitMessage, runGitMutation(std.testing.allocator, "/tmp/workspace", "commit_git_changes", blank_message));
    try std.testing.expectError(error.CommitRequiresExplicitStaging, runGitMutation(std.testing.allocator, "/tmp/workspace", "commit_git_changes", commit_message));
    try std.testing.expectError(error.InvalidBranchName, runGitMutation(std.testing.allocator, "/tmp/workspace", "checkout_git_branch", option_branch));
    try std.testing.expectError(error.InvalidBranchName, runGitMutation(std.testing.allocator, "/tmp/workspace", "checkout_git_branch", refspec_branch));
    try std.testing.expect(isSafeGitBranchName("feature/safe-branch_1.2"));
    try std.testing.expectError(error.UnsupportedGitMutation, runGitMutation(std.testing.allocator, "/tmp/workspace", "unknown_git_command", empty));
}

test "provider summaries are generated from core schema" {
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, tmp.allocator(),
        \\{"providers":[
        \\{"id":"moonshot","name":"Moonshot","env_key":"MOONSHOT_API_KEY","login":"api_key"},
        \\{"id":"codex","name":"Codex (ChatGPT)","env_key":"CODEX_DISABLED","login":"codex_device"}
        \\]}
    , .{ .allocate = .alloc_always });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(writeProviderSummariesFromSchema(&out.writer, parsed));

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"moonshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "MOONSHOT_API_KEY or graff key set moonshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Shared Codex CLI login") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"envKey\":\"CODEX_DISABLED\"") == null);
}

test "activateWorkspaceLocked clears stale conversation and restores workspace selection" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const first_workspace = "/tmp/codegraff-gui-test-one";
    const second_workspace = "/tmp/codegraff-gui-test-two";
    const conv = rt.createConversationLocked(first_workspace, "chat-one", "First chat");
    rt.active_conversation_id = conv.conversation_id;
    try rt.selected_by_workspace.put(conv.workspace_path, conv.conversation_id);

    rt.activateWorkspaceLocked(rt.dupe(second_workspace));
    try std.testing.expectEqualStrings(second_workspace, rt.active_workspace_path.?);
    try std.testing.expect(rt.active_conversation_id == null);

    rt.activateWorkspaceLocked(conv.workspace_path);
    try std.testing.expectEqualStrings(first_workspace, rt.active_workspace_path.?);
    try std.testing.expectEqualStrings("chat-one", rt.active_conversation_id.?);
}

test "passive session import does not change active workspace" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const active = rt.createConversationLocked("/tmp/codegraff-active-workspace", "chat-active", "Active");
    rt.active_conversation_id = active.conversation_id;
    try rt.selected_by_workspace.put(active.workspace_path, active.conversation_id);

    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"provider\":\"codegraff\",\"model\":\"deepseek-v4-pro\",\"title\":\"Imported\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}", .{ .allocate = .alloc_always });
    rt.importSessionValueLocked("/tmp/codegraff-inactive-workspace", "imported", parsed, tmp.allocator());

    try std.testing.expectEqualStrings("/tmp/codegraff-active-workspace", rt.active_workspace_path.?);
    try std.testing.expectEqualStrings("chat-active", rt.active_conversation_id.?);
}

test "session scan cache throttles and invalidates workspace scans" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const workspace = "/tmp/codegraff-gui-scan-cache";
    try std.testing.expect(rt.session_scan_cache.get(workspace) == null);
    rt.markSessionScanLocked(workspace, 1000);
    try std.testing.expectEqual(@as(i64, 1000), rt.session_scan_cache.get(workspace).?.scanned_ms);
    rt.markSessionScanLocked(workspace, 2000);
    try std.testing.expectEqual(@as(usize, 1), rt.session_scan_cache.count());
    try std.testing.expectEqual(@as(i64, 2000), rt.session_scan_cache.get(workspace).?.scanned_ms);
    rt.invalidateSessionScanLocked(workspace);
    try std.testing.expect(rt.session_scan_cache.get(workspace) == null);
}

test "runtime status cache rejects stale stores after invalidation" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const generation = rt.runtime_status_generation;
    rt.invalidateRuntimeStatusLocked("/tmp/workspace");
    const stale_key = try rt.allocator.dupe(u8, "/tmp/workspace");
    const stale_value = try rt.allocator.dupe(u8, "{\"branch\":\"old\"}");
    defer rt.allocator.free(stale_key);
    defer rt.allocator.free(stale_value);
    try std.testing.expect(!rt.storeRuntimeStatusCacheLocked("/tmp/workspace", stale_key, stale_value, 100, generation));
    try std.testing.expect(rt.runtime_status_cache.get("/tmp/workspace") == null);
}

test "runtime status cache invalidates one workspace or all workspaces" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const key_a = try rt.allocator.dupe(u8, "/tmp/a");
    const key_b = try rt.allocator.dupe(u8, "/tmp/b");
    try rt.runtime_status_cache.put(key_a, .{ .json = try rt.allocator.dupe(u8, "{\"a\":true}"), .expires_ms = 10 });
    try rt.runtime_status_cache.put(key_b, .{ .json = try rt.allocator.dupe(u8, "{\"b\":true}"), .expires_ms = 10 });

    rt.invalidateRuntimeStatusLocked("/tmp/a");
    try std.testing.expect(rt.runtime_status_cache.get("/tmp/a") == null);
    try std.testing.expect(rt.runtime_status_cache.get("/tmp/b") != null);
    rt.invalidateRuntimeStatusLocked(null);
    try std.testing.expectEqual(@as(usize, 0), rt.runtime_status_cache.count());
}

test "emitSseEvent evicts and frees replay payloads" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const total = sse_event_replay_limit + 5;
    for (0..total) |idx| {
        rt.emitSseEvent("test-event", rt.fmt("payload-{d}", .{idx + 1}));
    }

    try std.testing.expectEqual(@as(usize, sse_event_replay_limit), rt.events.items.len);
    try std.testing.expectEqual(@as(u64, 6), rt.events.items[0].seq);
    try std.testing.expectEqual(@as(u64, total), rt.events.items[rt.events.items.len - 1].seq);
    try std.testing.expectEqualStrings("test-event", rt.events.items[0].name);
    try std.testing.expectEqualStrings("payload-6", rt.events.items[0].data);
    try std.testing.expectEqualStrings("payload-1005", rt.events.items[rt.events.items.len - 1].data);
}

test "clampRequestedEventSeqLocked handles stale future Last-Event-ID" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 0), rt.clampRequestedEventSeqLocked(500));
    rt.emitSseEvent("event", "one");
    try std.testing.expectEqual(@as(u64, 0), rt.clampRequestedEventSeqLocked(500));
    try std.testing.expectEqual(@as(u64, 0), rt.clampRequestedEventSeqLocked(0));

    for (0..sse_event_replay_limit + 5) |idx| {
        rt.emitSseEvent("event", rt.fmt("more-{d}", .{idx}));
    }
    try std.testing.expectEqual(@as(u64, 7), rt.events.items[0].seq);
    try std.testing.expectEqual(@as(u64, 6), rt.clampRequestedEventSeqLocked(0));
    try std.testing.expectEqual(@as(u64, 6), rt.clampRequestedEventSeqLocked(999_999));
}

test "importSessionValueLocked imports CLI session files" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const data =
        \\{"provider":"codegraff","model":"deepseek-v4-pro","strict":false,"ultracode_mode":false,"goal":"ship persistence","title":"CLI title","updated_ms":42,"messages":[
        \\{"role":"user","content":"hello from cli"},
        \\{"role":"assistant","reasoning_content":"thinking through it","content":[{"type":"text","text":"hello from gui"}]},
        \\{"role":"tool","content":"hidden"}
        \\]}
    ;
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), data, .{ .allocate = .alloc_always });

    const workspace = "/tmp/codegraff-gui-session-import";
    rt.importSessionValueLocked(workspace, "last", parsed, tmp.allocator());
    rt.ensureWorkspaceSelectionLocked(workspace);

    const cid = rt.conversationIdForSession(workspace, "last");
    const conv = rt.conversations.get(cid) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("last", conv.session_name);
    try std.testing.expectEqualStrings("CLI title", conv.title);
    try std.testing.expectEqualStrings("ship persistence", conv.goal.?);
    try std.testing.expectEqual(@as(usize, 3), conv.messages.items.len);
    try std.testing.expectEqual(.user, conv.messages.items[0].kind);
    try std.testing.expectEqualStrings("hello from cli", conv.messages.items[0].text);
    try std.testing.expectEqual(.reasoning, conv.messages.items[1].kind);
    try std.testing.expectEqualStrings("thinking through it", conv.messages.items[1].text);
    try std.testing.expectEqual(.assistant, conv.messages.items[2].kind);
    try std.testing.expectEqualStrings("hello from gui", conv.messages.items[2].text);
    try std.testing.expectEqualStrings(cid, rt.selected_by_workspace.get(workspace).?);
}

test "importSessionValueLocked preserves GUI chat ids from session filenames" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const session_name = "chat-0123456789abcdef";
    const workspace = "/tmp/codegraff-gui-session-id";
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"provider\":\"codegraff\",\"model\":\"deepseek-v4-pro\",\"messages\":[],\"updated_ms\":1}", .{ .allocate = .alloc_always });

    rt.importSessionValueLocked(workspace, session_name, parsed, tmp.allocator());
    const conv = rt.conversations.get(session_name) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(session_name, conv.conversation_id);
    try std.testing.expectEqualStrings(session_name, conv.session_name);
}

test "conversationSessionJsonLocked writes CLI-readable session JSON" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const workspace = "/tmp/codegraff-gui-session-write";
    const session_name = "chat-fedcba9876543210";

    const conv = rt.createConversationLocked(workspace, session_name, "New chat");
    conv.updated_at = 123;
    conv.messages.append(rt.arena, .{ .kind = .user, .id = "u", .request_id = "r", .text = "persist me" }) catch {};
    conv.messages.append(rt.arena, .{ .kind = .assistant, .id = "a", .request_id = "r", .text = "persisted" }) catch {};
    const data = try rt.conversationSessionJsonLocked(conv, "codegraff", "deepseek-v4-pro");
    defer rt.allocator.free(data);

    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), data, .{ .allocate = .alloc_always });
    try std.testing.expectEqualStrings("codegraff", stringField(parsed, "provider").?);
    try std.testing.expectEqualStrings("deepseek-v4-pro", stringField(parsed, "model").?);
    try std.testing.expectEqualStrings("New chat", stringField(parsed, "title").?);
    const messages = arrayField(parsed, "messages").?;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("user", stringField(messages.items[0], "role").?);
    try std.testing.expectEqualStrings("persist me", stringField(messages.items[0], "content").?);
    try std.testing.expectEqualStrings("assistant", stringField(messages.items[1], "role").?);
    try std.testing.expectEqualStrings("persisted", stringField(messages.items[1], "content").?);
}

test "turnPromptSelectionLocked reconciles selected model over imported CLI sessions" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    rt.settings.selected_provider = "codegraff";
    rt.settings.selected_model = "deepseek-v4-pro";
    const conv = rt.createConversationLocked("/tmp/codegraff-gui-turn-selection", "chat-3333333333333333", "Imported");
    conv.session_provider = "codex";
    conv.session_model = "gpt-5";

    const selection = rt.turnPromptSelectionLocked(conv.conversation_id);
    try std.testing.expectEqualStrings("codegraff", selection.provider.?);
    try std.testing.expectEqualStrings("deepseek-v4-pro", selection.model.?);
    try std.testing.expect(selection.send_model_control);
}

test "conversationSessionJsonLocked preserves imported CLI-native messages" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const data =
        \\{"provider":"codex","model":"gpt-5","strict":true,"ultracode_mode":true,"title":"Native","messages":[
        \\{"role":"user","content":"inspect"},
        \\{"role":"assistant","content":[{"type":"text","text":"I will read"},{"type":"tool_use","id":"call-1","name":"read_file","input":{"path":"src/main.zig"}}]},
        \\{"role":"tool","tool_call_id":"call-1","content":"file contents"}
        \\]}
    ;
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), data, .{ .allocate = .alloc_always });

    const workspace = "/tmp/codegraff-gui-native-preserve";
    rt.importSessionValueLocked(workspace, "native", parsed, tmp.allocator());
    const cid = rt.conversationIdForSession(workspace, "native");
    const conv = rt.conversations.get(cid) orelse return error.TestExpectedEqual;
    conv.messages.append(rt.arena, .{ .kind = .tool_start, .id = "gui-tool", .request_id = "r", .name = "read_file", .call_id = "call-1", .tool_detail_json = "{\"kind\":\"file_read\",\"path\":\"src/main.zig\",\"startLine\":null,\"endLine\":null}" }) catch {};

    const written = try rt.conversationSessionJsonLocked(conv, "codex", "gpt-5");
    defer rt.allocator.free(written);
    var check_tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer check_tmp.deinit();
    const saved = try std.json.parseFromSliceLeaky(Value, check_tmp.allocator(), written, .{ .allocate = .alloc_always });
    try std.testing.expectEqualStrings("codex", stringField(saved, "provider").?);
    try std.testing.expectEqualStrings("gpt-5", stringField(saved, "model").?);
    try std.testing.expect(boolField(saved, "strict").?);
    try std.testing.expect(boolField(saved, "ultracode_mode").?);
    const messages = arrayField(saved, "messages").?;
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqualStrings("tool", stringField(messages.items[2], "role").?);
    try std.testing.expectEqualStrings("call-1", stringField(messages.items[2], "tool_call_id").?);
    const gui_messages = arrayField(saved, "guiMessages").?;
    try std.testing.expect(gui_messages.items.len >= 1);
}

test "conversationSessionJsonLocked round-trips rich GUI messages" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const workspace = "/tmp/codegraff-gui-rich-session";
    const conv = rt.createConversationLocked(workspace, "chat-1111111111111111", "Rich chat");
    conv.updated_at = 456;
    conv.goal = "preserve display state";
    conv.messages.append(rt.arena, .{ .kind = .user, .id = "u", .request_id = "r", .text = "inspect" }) catch {};
    conv.messages.append(rt.arena, .{ .kind = .reasoning, .id = "reason", .request_id = "r", .text = "thinking" }) catch {};
    conv.messages.append(rt.arena, .{ .kind = .status, .id = "st", .request_id = "r", .title = "Unhandled graff event: protocol_extension", .subtitle = "Preserved raw event for protocol compatibility.", .category = "debug" }) catch {};
    conv.messages.append(rt.arena, .{ .kind = .status_output, .id = "sto", .request_id = "r", .text = "{\"type\":\"protocol_extension\",\"value\":1}" }) catch {};
    conv.messages.append(rt.arena, .{ .kind = .tool_start, .id = "ts", .request_id = "r", .name = "read_file", .call_id = "call-1", .tool_detail_json = "{\"kind\":\"file_read\",\"path\":\"src/main.zig\",\"startLine\":null,\"endLine\":null}" }) catch {};
    conv.messages.append(rt.arena, .{ .kind = .tool_end, .id = "te", .request_id = "r", .name = "read_file", .call_id = "call-1", .summary = "read file", .is_error = false, .result_detail_json = "{\"kind\":\"text\",\"text\":\"contents\"}" }) catch {};
    conv.messages.append(rt.arena, .{ .kind = .@"error", .id = "err", .request_id = "r", .error_message = "boom" }) catch {};

    const data = try rt.conversationSessionJsonLocked(conv, "codegraff", "deepseek-v4-pro");
    defer rt.allocator.free(data);

    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), data, .{ .allocate = .alloc_always });
    const cli_messages = arrayField(parsed, "messages").?;
    try std.testing.expectEqual(@as(usize, 1), cli_messages.items.len);
    const gui_messages = arrayField(parsed, "guiMessages").?;
    try std.testing.expectEqual(@as(usize, 7), gui_messages.items.len);
    try std.testing.expectEqualStrings("reasoning", stringField(gui_messages.items[1], "kind").?);
    try std.testing.expectEqualStrings("status", stringField(gui_messages.items[2], "kind").?);
    try std.testing.expectEqualStrings("debug", stringField(gui_messages.items[2], "category").?);
    try std.testing.expectEqualStrings("status_output", stringField(gui_messages.items[3], "kind").?);
    try std.testing.expectEqualStrings("tool_start", stringField(gui_messages.items[4], "kind").?);
    try std.testing.expectEqualStrings("call-1", stringField(gui_messages.items[4], "callId").?);
    try std.testing.expectEqualStrings("tool_end", stringField(gui_messages.items[5], "kind").?);
    try std.testing.expectEqualStrings("error", stringField(gui_messages.items[6], "kind").?);

    rt.importSessionValueLocked(workspace, "chat-2222222222222222", parsed, tmp.allocator());
    const restored = rt.conversations.get("chat-2222222222222222") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 7), restored.messages.items.len);
    try std.testing.expectEqual(.reasoning, restored.messages.items[1].kind);
    try std.testing.expectEqualStrings("thinking", restored.messages.items[1].text);
    try std.testing.expectEqual(.status, restored.messages.items[2].kind);
    try std.testing.expectEqualStrings("Unhandled graff event: protocol_extension", restored.messages.items[2].title);
    try std.testing.expectEqualStrings("debug", restored.messages.items[2].category);
    try std.testing.expectEqual(.status_output, restored.messages.items[3].kind);
    try std.testing.expectEqualStrings("{\"type\":\"protocol_extension\",\"value\":1}", restored.messages.items[3].text);
    try std.testing.expectEqual(.tool_start, restored.messages.items[4].kind);
    try std.testing.expectEqualStrings("read_file", restored.messages.items[4].name);
    try std.testing.expectEqualStrings("call-1", restored.messages.items[4].call_id.?);
    try std.testing.expect(restored.messages.items[4].tool_detail_json != null);
    try std.testing.expectEqual(.tool_end, restored.messages.items[5].kind);
    try std.testing.expectEqualStrings("read file", restored.messages.items[5].summary.?);
    try std.testing.expect(restored.messages.items[5].result_detail_json != null);
    try std.testing.expectEqual(.@"error", restored.messages.items[6].kind);
    try std.testing.expectEqualStrings("boom", restored.messages.items[6].error_message);
}

test "writeFollowup serializes options and kind" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const followup = Followup{
        .followup_id = "call-1",
        .workspace_path = "/tmp/workspace",
        .conversation_id = "chat-1",
        .request_id = "request-1",
        .kind = "single",
        .question = "Choose one",
        .options = &.{
            .{ .id = "opt-1", .label = "First" },
            .{ .id = "opt-2", .label = "Second" },
        },
        .call_id = "call-1",
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rt.writeFollowup(&out.writer, followup);

    try std.testing.expectEqualStrings(
        "{\"followupId\":\"call-1\",\"workspacePath\":\"/tmp/workspace\",\"conversationId\":\"chat-1\",\"requestId\":\"request-1\",\"kind\":\"single\",\"question\":\"Choose one\",\"options\":[{\"id\":\"opt-1\",\"label\":\"First\"},{\"id\":\"opt-2\",\"label\":\"Second\"}]}",
        out.written(),
    );
}

test "answerLineJson combines selected option labels and notes" {
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const selected = try std.json.parseFromSliceLeaky(Value, tmp.allocator(), "{\"selectedOptionIds\":[\"opt-2\"]}", .{ .allocate = .alloc_always });
    const followup = Followup{
        .followup_id = "call-1",
        .workspace_path = "/tmp/workspace",
        .conversation_id = "chat-1",
        .request_id = "request-1",
        .kind = "single",
        .question = "Choose one",
        .options = &.{
            .{ .id = "opt-1", .label = "First" },
            .{ .id = "opt-2", .label = "Second" },
        },
        .call_id = "call-1",
    };
    const line = try answerLineJson(std.testing.allocator, followup, "because it is safer", arrayField(selected, "selectedOptionIds"), false);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings(
        "{\"type\":\"answer\",\"text\":\"Second\\n\\nNotes: because it is safer\",\"cancelled\":false,\"call_id\":\"call-1\"}",
        line,
    );
}
