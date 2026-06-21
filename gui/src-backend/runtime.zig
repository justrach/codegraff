const std = @import("std");
const builtin = @import("builtin");
const mer = @import("mer");
const mer_runtime = @import("runtime");

const log = std.log.scoped(.backend);
const Value = std.json.Value;
const default_reasoning_effort = "medium";

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
    is_error: bool = false,
    error_message: []const u8 = "",

    const Kind = enum {
        user,
        context_compacted,
        assistant,
        reasoning,
        tool_start,
        tool_end,
        @"error",
    };
};

const Conversation = struct {
    workspace_path: []const u8,
    conversation_id: []const u8,
    title: []const u8,
    messages: std.ArrayList(Message) = .empty,
    active_request_ids: std.ArrayList([]const u8) = .empty,
    active_agent_id: ?[]const u8 = null,
    plan_mode: bool = false,
    goal: ?[]const u8 = null,
    updated_at: i64 = 0,
    followup: ?Followup = null,
};

const Followup = struct {
    followup_id: []const u8,
    workspace_path: []const u8,
    conversation_id: []const u8,
    request_id: []const u8,
    question: []const u8,
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
    workspace_path: []const u8,
    shell: []const u8,
    cols: u16,
    rows: u16,
    input: std.ArrayList(u8) = .empty,
};

const SseEvent = struct {
    seq: u64,
    name: []const u8,
    data: []const u8,
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
    event_mutex: std.Io.Mutex = .init,
    events: std.ArrayList(SseEvent) = .empty,
    next_event_seq: u64 = 1,
    active_workspace_path: ?[]const u8 = null,
    active_conversation_id: ?[]const u8 = null,
    active_agent_id: []const u8 = "forge",
    settings_loaded: bool = false,
    settings: PromptSettings = .{},

    pub fn init(allocator: std.mem.Allocator) !*Runtime {
        const rt = try allocator.create(Runtime);
        rt.* = .{
            .allocator = allocator,
            .arena_state = .init(allocator),
            .arena = undefined,
            .conversations = std.StringHashMap(*Conversation).init(allocator),
            .selected_by_workspace = std.StringHashMap([]const u8).init(allocator),
            .terminals = std.StringHashMap(*TerminalSessionState).init(allocator),
        };
        rt.arena = rt.arena_state.allocator();
        instance = rt;
        log.info("backend runtime initialized", .{});
        return rt;
    }

    pub fn deinit(self: *Runtime) void {
        self.terminals.deinit();
        self.events.deinit(self.allocator);
        self.conversations.deinit();
        self.selected_by_workspace.deinit();
        self.arena_state.deinit();
        self.allocator.destroy(self);
        instance = null;
    }

    pub fn handleApi(self: *Runtime, req: mer.Request) mer.Response {
        if (req.method != .POST) return mer.Response.init(.method_not_allowed, .json, "{\"error\":\"method not allowed\"}");
        const cmd = commandName(req.path);

        if (std.mem.eql(u8, cmd, "get_session_snapshot")) return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
        if (std.mem.eql(u8, cmd, "pick_workspace") or std.mem.eql(u8, cmd, "pick_directory")) return self.pickDirectory(req);
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
        if (std.mem.eql(u8, cmd, "handoff_chat")) return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
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
        if (std.mem.eql(u8, cmd, "open_external_url")) return self.openExternalUrl(req);
        if (std.mem.eql(u8, cmd, "checkout_git_branch") or std.mem.eql(u8, cmd, "create_git_branch") or std.mem.eql(u8, cmd, "commit_git_changes") or std.mem.eql(u8, cmd, "push_git_branch")) return self.gitMutation(req, cmd);
        if (std.mem.eql(u8, cmd, "clone_repository") or std.mem.eql(u8, cmd, "quick_start_project")) return mer.Response.init(.bad_request, .json, "{\"error\":\"repository creation is not implemented in the Zig backend yet\"}");

        return mer.Response.init(.not_found, .json, "{\"error\":\"unknown api command\"}");
    }

    fn jsonResponse(_: *Runtime, _: mer.Request, body: []const u8) mer.Response {
        return mer.Response.init(.ok, .json, body);
    }

    fn pickDirectory(_: *Runtime, req: mer.Request) mer.Response {
        if (builtin.os.tag != .macos) return mer.json("null");
        const root = parse(req) catch Value{ .object = .empty };
        const title = stringField(root, "title") orelse "Choose a folder";
        var quoted_title: std.Io.Writer.Allocating = .init(req.allocator);
        writeString(&quoted_title.writer, title) catch return oom();
        const script = std.fmt.allocPrint(req.allocator, "POSIX path of (choose folder with prompt {s})", .{quoted_title.written()}) catch return oom();
        const raw = commandOutput(req.allocator, &.{ "osascript", "-e", script }) catch return mer.json("null");
        var path = std.mem.trim(u8, raw, " \t\r\n");
        if (path.len == 0) return mer.json("null");
        while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        writeString(&out.writer, path) catch return oom();
        return mer.json(out.written());
    }

    fn openWorkspace(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const path = stringField(root, "path") orelse return bad(req, "missing path");
        self.mutex.lockUncancelable(mer_runtime.io);
        const owned = self.dupe(path);
        self.activateWorkspaceLocked(owned);
        self.bumpLocked();
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
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        const w = &out.writer;
        w.writeAll("[") catch return oom();
        var first = true;
        for (fallback_providers) |p| {
            if (!first) w.writeByte(',') catch return oom();
            first = false;
            w.writeAll("{\"id\":") catch return oom();
            writeString(w, p.id) catch return oom();
            w.writeAll(",\"name\":") catch return oom();
            writeString(w, p.name) catch return oom();
            w.writeAll(",\"configured\":") catch return oom();
            w.writeAll(if (providerConfiguredById(p.id, p.env_key)) "true" else "false") catch return oom();
            w.writeAll(",\"authMethods\":[{\"kind\":") catch return oom();
            writeString(w, p.auth_kind) catch return oom();
            w.writeAll(",\"label\":") catch return oom();
            writeString(w, p.auth_label) catch return oom();
            w.writeAll("}],\"envOverride\":") catch return oom();
            writeEnvOverride(w, p.env_key) catch return oom();
            w.writeAll("}") catch return oom();
        }
        w.writeAll("]") catch return oom();
        return self.jsonResponse(req, out.written());
    }

    fn selectConversation(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse return bad(req, "missing workspacePath");
        const conv_id = stringField(root, "conversationId") orelse return bad(req, "missing conversationId");
        self.mutex.lockUncancelable(mer_runtime.io);
        const wpath = self.dupe(workspace);
        self.setActiveWorkspaceLocked(wpath);
        if (self.conversations.get(conv_id)) |conversation| {
            self.active_conversation_id = conversation.conversation_id;
            self.selected_by_workspace.put(wpath, conversation.conversation_id) catch {};
        }
        self.bumpLocked();
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
        self.bumpLocked();
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

        self.mutex.lockUncancelable(mer_runtime.io);
        {
            const cid = provided_conversation orelse self.uniqueId("chat");
            const conv = self.conversations.get(cid) orelse self.createConversationLocked(workspace, cid, titleFromPrompt(self.arena, prompt));
            conversation_id = conv.conversation_id;
            self.setActiveWorkspaceLocked(conv.workspace_path);
            self.active_conversation_id = conv.conversation_id;
            self.selected_by_workspace.put(conv.workspace_path, conv.conversation_id) catch {};
            conv.plan_mode = agent_id != null and std.mem.eql(u8, agent_id.?, "muse");
            conv.active_agent_id = if (agent_id) |a| self.dupe(a) else conv.active_agent_id;
            conv.updated_at = nowMillis();
            conv.messages.append(self.arena, .{
                .kind = .user,
                .id = self.fmt("{s}-user", .{request_id}),
                .request_id = request_id,
                .text = self.dupe(prompt),
            }) catch {};
            conv.active_request_ids.append(self.arena, request_id) catch {};
            self.bumpLocked();
        }
        self.mutex.unlock(mer_runtime.io);

        self.streamGraffTurn(conversation_id, request_id, workspace, prompt) catch |err| {
            self.mutex.lockUncancelable(mer_runtime.io);
            if (self.conversations.get(conversation_id)) |conv| {
                conv.messages.append(self.arena, .{
                    .kind = .@"error",
                    .id = self.fmt("{s}-error", .{request_id}),
                    .request_id = request_id,
                    .error_message = self.fmt("Failed to run graff: {s}", .{@errorName(err)}),
                }) catch {};
            }
            self.bumpLocked();
            self.mutex.unlock(mer_runtime.io);
        };

        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(conversation_id)) |conv| {
            removeString(&conv.active_request_ids, request_id);
            conv.followup = null;
        }
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);

        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn stopPrompt(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const cid = stringField(input, "conversationId") orelse return mer.json("{}");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| conv.active_request_ids.clearRetainingCapacity();
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return mer.json("{}");
    }

    fn compactConversation(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const cid = stringField(input, "conversationId") orelse return bad(req, "missing conversationId");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            const rid = self.uniqueId("compact");
            conv.messages.append(self.arena, .{
                .kind = .context_compacted,
                .id = rid,
                .request_id = rid,
                .text = "Conversation compaction requested. The next prompt will continue in a fresh graff session.",
            }) catch {};
            conv.updated_at = nowMillis();
        }
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn respondFollowup(self: *Runtime, req: mer.Request) mer.Response {
        _ = parse(req) catch return badJson(req);
        self.mutex.lockUncancelable(mer_runtime.io);
        var it = self.conversations.iterator();
        while (it.next()) |entry| entry.value_ptr.*.followup = null;
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn archiveConversation(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const cid = stringField(root, "conversationId") orelse return bad(req, "missing conversationId");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            _ = self.conversations.remove(cid);
            if (self.active_conversation_id != null and std.mem.eql(u8, self.active_conversation_id.?, conv.conversation_id)) self.active_conversation_id = null;
        }
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn archiveWorkspace(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const workspace = stringField(root, "workspacePath") orelse return bad(req, "missing workspacePath");
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.workspaceIndexLocked(workspace)) |idx| _ = self.workspaces.swapRemove(idx);
        if (self.active_workspace_path != null and std.mem.eql(u8, self.active_workspace_path.?, workspace)) {
            self.active_workspace_path = null;
            self.active_conversation_id = null;
        }
        self.bumpLocked();
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
        self.mutex.unlock(mer_runtime.io);
        return self.jsonResponse(req, self.snapshotJson(req.allocator) catch return oom());
    }

    fn runSlashCommand(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const name = stringField(root, "name") orelse "help";
        const args_text = joinArgs(req.allocator, root) catch return oom();
        if (std.mem.eql(u8, name, "agent")) return mer.json("{\"title\":\"/agent\",\"body\":\"Active agent: Forge\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"agents\",\"payload\":{\"kind\":\"agents\",\"activeAgentId\":\"forge\",\"selectedProviderId\":\"codegraff\",\"selectedModelId\":\"default\",\"selectedReasoningEffort\":null,\"agents\":[{\"id\":\"forge\",\"title\":\"Forge\",\"description\":\"Default Codegraff assistant.\",\"isActive\":true,\"modelId\":\"default\"}]}}");
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
            const snap = self.snapshotJson(req.allocator) catch return oom();
            var out: std.Io.Writer.Allocating = .init(req.allocator);
            out.writer.writeAll("{\"title\":\"/compact\",\"body\":null,\"snapshot\":") catch return oom();
            out.writer.writeAll(snap) catch return oom();
            out.writer.writeAll(",\"savedPath\":null,\"resultKind\":\"snapshot\",\"payload\":null}") catch return oom();
            return mer.json(out.written());
        }
        if (std.mem.eql(u8, name, "workspace-status")) return self.workspaceStatusCommand(req, root);
        return mer.json("{\"title\":\"/help\",\"body\":\"Available MVP commands: /help, /agent, /goal, /loop, /bash <command>, /compact, /workspace-status.\",\"snapshot\":null,\"savedPath\":null,\"resultKind\":\"text\",\"payload\":null}");
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
                if (std.mem.eql(u8, args_text, "clear")) {
                    conv.goal = null;
                    self.bumpLocked();
                    self.mutex.unlock(mer_runtime.io);
                    return commandText(req, "/goal", "Goal cleared. Future turns will not get goal steering.");
                }
                conv.goal = self.dupe(args_text);
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
        self.bumpLocked();
        self.mutex.unlock(mer_runtime.io);

        const snap = self.snapshotJson(req.allocator) catch return oom();
        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"title\":\"/loop\",\"body\":\"Started an autonomous plan-act-verify pass.\",\"snapshot\":") catch return oom();
        out.writer.writeAll(snap) catch return oom();
        out.writer.writeAll(",\"savedPath\":null,\"resultKind\":\"snapshot\",\"payload\":null}") catch return oom();
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
        return mer.json("{\"activeAgentId\":\"forge\",\"selectedProviderId\":\"codegraff\",\"selectedModelId\":\"default\",\"selectedReasoningEffort\":null,\"agents\":[{\"id\":\"forge\",\"title\":\"Forge\",\"description\":\"Default Codegraff assistant.\",\"isActive\":true,\"modelId\":\"default\"}]}");
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

    fn listMcpServers(_: *Runtime, req: mer.Request) mer.Response {
        _ = req;
        return mer.json("{\"servers\":[]}");
    }

    fn importMcpConfig(self: *Runtime, req: mer.Request) mer.Response {
        _ = self;
        _ = parse(req) catch return badJson(req);
        return mer.json("{\"servers\":[]}");
    }

    fn removeMcpServer(self: *Runtime, req: mer.Request) mer.Response {
        _ = self;
        _ = parse(req) catch return badJson(req);
        return mer.json("{\"servers\":[]}");
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
            if (std.mem.eql(u8, method, "api_key")) "api_key"
            else if (std.mem.eql(u8, method, "o_auth_code")) "o_auth_code"
            else if (std.mem.eql(u8, method, "o_auth_device")) "device_code"
            else if (std.mem.eql(u8, method, "codex_device")) "cli_login"
            else "cli_login";
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
        if (workspace.len == 0 or std.mem.indexOf(u8, rel, "..") != null) return bad(req, "path is outside the workspace");
        const joined = std.fs.path.join(req.allocator, &.{ workspace, rel }) catch return oom();
        const data = std.Io.Dir.cwd().readFileAlloc(mer_runtime.io, joined, req.allocator, .limited(512 * 1024)) catch return bad(req, "failed to read file");
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
        _ = cmd;
        return self.runtimeStatusJson(req.allocator, workspace) catch oom();
    }

    fn openExternalUrl(_: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const url = stringField(root, "url") orelse return bad(req, "missing url");
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return bad(req, "unsupported URL scheme");
        var child = std.process.spawn(mer_runtime.io, .{
            .argv = &.{ "open", url },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return bad(req, "failed to open browser");
        const term = child.wait(mer_runtime.io) catch return bad(req, "failed to open browser");
        if (term != .exited or term.exited != 0) return bad(req, "failed to open browser");
        return mer.json("null");
    }

    fn terminalOpen(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        const workspace = stringField(input, "workspacePath") orelse return bad(req, "missing workspacePath");
        const cols = intField(input, "cols", 80);
        const rows = intField(input, "rows", 24);
        const shell = "/bin/zsh";

        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.terminals.get(terminal_id)) |existing| {
            existing.cols = clampTerminalSize(cols, 80);
            existing.rows = clampTerminalSize(rows, 24);
            existing.workspace_path = self.dupe(workspace);
        } else {
            const session = self.arena.create(TerminalSessionState) catch {
                self.mutex.unlock(mer_runtime.io);
                return oom();
            };
            session.* = .{
                .terminal_id = self.dupe(terminal_id),
                .workspace_path = self.dupe(workspace),
                .shell = shell,
                .cols = clampTerminalSize(cols, 80),
                .rows = clampTerminalSize(rows, 24),
            };
            self.terminals.put(session.terminal_id, session) catch {};
        }
        const session = self.terminals.get(terminal_id).?;
        self.mutex.unlock(mer_runtime.io);

        self.emitTerminalOutput(terminal_id, tryPromptText(req.allocator, session.workspace_path));

        var out: std.Io.Writer.Allocating = .init(req.allocator);
        out.writer.writeAll("{\"terminalId\":") catch return oom();
        writeString(&out.writer, terminal_id) catch return oom();
        out.writer.writeAll(",\"workspacePath\":") catch return oom();
        writeString(&out.writer, workspace) catch return oom();
        out.writer.writeAll(",\"shell\":") catch return oom();
        writeString(&out.writer, shell) catch return oom();
        out.writer.writeAll(",\"cols\":") catch return oom();
        out.writer.print("{d}", .{session.cols}) catch return oom();
        out.writer.writeAll(",\"rows\":") catch return oom();
        out.writer.print("{d}", .{session.rows}) catch return oom();
        out.writer.writeAll("}") catch return oom();
        return mer.json(out.written());
    }

    fn terminalWrite(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        const data = stringField(input, "data") orelse "";

        var command_to_run: ?[]const u8 = null;
        var workspace: ?[]const u8 = null;
        self.mutex.lockUncancelable(mer_runtime.io);
        const session = self.terminals.get(terminal_id) orelse {
            self.mutex.unlock(mer_runtime.io);
            return bad(req, "terminal session not found");
        };
        workspace = session.workspace_path;
        for (data) |byte| {
            switch (byte) {
                '\r', '\n' => {
                    if (command_to_run == null) {
                        command_to_run = self.arena.dupe(u8, std.mem.trim(u8, session.input.items, " \t\r\n")) catch "";
                        session.input.items.len = 0;
                    }
                },
                0x7f, 0x08 => {
                    if (session.input.items.len > 0) session.input.items.len -= 1;
                },
                0x1b => {},
                else => session.input.append(self.arena, byte) catch {},
            }
        }
        self.mutex.unlock(mer_runtime.io);

        self.emitTerminalOutput(terminal_id, data);
        if (command_to_run) |command| {
            self.emitTerminalOutput(terminal_id, "\r\n");
            if (command.len > 0) {
                const output = terminalCommandOutput(req.allocator, workspace orelse ".", command) catch blk: {
                    self.emitTerminalError(terminal_id, "command failed");
                    break :blk "";
                };
                if (output.len > 0) {
                    self.emitTerminalOutput(terminal_id, output);
                    if (!std.mem.endsWith(u8, output, "\n")) self.emitTerminalOutput(terminal_id, "\r\n");
                }
            }
            self.emitTerminalOutput(terminal_id, tryPromptText(req.allocator, workspace orelse "."));
        }
        return mer.json("null");
    }

    fn terminalResize(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        const cols = intField(input, "cols", 80);
        const rows = intField(input, "rows", 24);
        self.mutex.lockUncancelable(mer_runtime.io);
        if (self.terminals.get(terminal_id)) |session| {
            session.cols = clampTerminalSize(cols, 80);
            session.rows = clampTerminalSize(rows, 24);
        }
        self.mutex.unlock(mer_runtime.io);
        return mer.json("null");
    }

    fn terminalClose(self: *Runtime, req: mer.Request) mer.Response {
        const root = parse(req) catch return badJson(req);
        const input = objectField(root, "input") orelse root;
        const terminal_id = stringField(input, "terminalId") orelse return bad(req, "missing terminalId");
        self.mutex.lockUncancelable(mer_runtime.io);
        _ = self.terminals.remove(terminal_id);
        self.mutex.unlock(mer_runtime.io);
        self.emitTerminalExit(terminal_id, 0);
        return mer.json("null");
    }

    fn emitTerminalOutput(self: *Runtime, terminal_id: []const u8, data: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"terminalId\":") catch return;
        writeString(&out.writer, terminal_id) catch return;
        out.writer.writeAll(",\"data\":") catch return;
        writeString(&out.writer, data) catch return;
        out.writer.writeAll("}") catch return;
        self.emitSseEvent("terminal-output", out.written());
    }

    fn emitTerminalExit(self: *Runtime, terminal_id: []const u8, exit_code: i64) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"terminalId\":") catch return;
        writeString(&out.writer, terminal_id) catch return;
        out.writer.print(",\"exitCode\":{d},\"signal\":null}}", .{exit_code}) catch return;
        self.emitSseEvent("terminal-exit", out.written());
    }

    fn emitTerminalError(self: *Runtime, terminal_id: []const u8, message: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"terminalId\":") catch return;
        writeString(&out.writer, terminal_id) catch return;
        out.writer.writeAll(",\"message\":") catch return;
        writeString(&out.writer, message) catch return;
        out.writer.writeAll("}") catch return;
        self.emitSseEvent("terminal-error", out.written());
    }

    fn emitSseEvent(self: *Runtime, name: []const u8, data: []const u8) void {
        self.event_mutex.lockUncancelable(mer_runtime.io);
        defer self.event_mutex.unlock(mer_runtime.io);
        self.events.append(self.allocator, .{
            .seq = self.next_event_seq,
            .name = self.arena.dupe(u8, name) catch return,
            .data = self.arena.dupe(u8, data) catch return,
        }) catch return;
        self.next_event_seq += 1;
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

    fn streamGraffTurn(self: *Runtime, conversation_id: []const u8, request_id: []const u8, workspace: []const u8, prompt: []const u8) !void {
        const io = mer_runtime.io;
        const bin = self.codegraffBinary();
        self.ensurePromptSettingsLoaded();
        const model = self.selectedModelLocked();
        const provider = self.selectedProviderLocked();
        const effort = self.selectedEffortFor(provider, model);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.allocator, "/usr/bin/env");
        try argv.append(self.allocator, try std.fmt.allocPrint(self.allocator, "HOME={s}", .{homeDir()}));
        try argv.append(self.allocator, try std.fmt.allocPrint(self.allocator, "PATH={s}/bin:{s}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", .{ homeDir(), homeDir() }));
        try argv.append(self.allocator, bin);
        try argv.append(self.allocator, "--json");
        try argv.append(self.allocator, "--yolo");
        if (model) |m| {
            if (m.len > 0 and !std.mem.eql(u8, m, "default")) {
                try argv.append(self.allocator, "--model");
                try argv.append(self.allocator, m);
            }
        }
        defer argv.deinit(self.allocator);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = workspace },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        defer child.kill(io);

        var wbuf: [4096]u8 = undefined;
        var cw = child.stdin.?.writerStreaming(io, &wbuf);
        var req_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer req_buf.deinit();
        if (provider) |p| if (model) |m| {
            if (p.len > 0 and m.len > 0 and !std.mem.eql(u8, m, "default")) {
                try req_buf.writer.writeAll("{\"type\":\"set_model\",\"name\":");
                try writeString(&req_buf.writer, try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ p, m }));
                try req_buf.writer.writeAll("}\n");
            }
        };
        if (effort) |level| {
            try req_buf.writer.writeAll("{\"type\":\"set_effort\",\"level\":");
            try writeString(&req_buf.writer, level);
            try req_buf.writer.writeAll("}\n");
        }
        try req_buf.writer.writeAll("{\"type\":\"user\",\"text\":");
        try writeString(&req_buf.writer, prompt);
        try req_buf.writer.writeAll("}");
        try cw.interface.writeAll(req_buf.written());
        try cw.interface.writeByte('\n');
        try cw.interface.flush();

        const rbuf = try self.allocator.alloc(u8, 1024 * 1024);
        defer self.allocator.free(rbuf);
        var rdr = child.stdout.?.readerStreaming(io, rbuf);
        var assistant_seq: usize = 0;
        var reasoning_seq: usize = 0;
        var current_assistant: ?[]const u8 = null;
        var current_reasoning: ?[]const u8 = null;
        var event_count: usize = 0;
        while (true) {
            const ev_line = rdr.interface.takeDelimiter('\n') catch |err| {
                log.warn("graff read ended with {}", .{err});
                break;
            } orelse {
                log.warn("graff read ended with EOF", .{});
                break;
            };
            const line = std.mem.trim(u8, ev_line, " \t\r\n");
            if (line.len == 0) continue;
            var turn_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer turn_arena.deinit();
            const event = std.json.parseFromSliceLeaky(Value, turn_arena.allocator(), line, .{}) catch |err| {
                log.warn("graff event parse failed: {}", .{err});
                continue;
            };
            const ty = stringField(event, "type") orelse {
                log.warn("graff event missing type", .{});
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
                const id = self.fmt("{s}-tool-{d}", .{ request_id, nowMillis() });
                self.appendToolStart(conversation_id, request_id, id, name, null, stringField(objectField(event, "input") orelse event, "question") orelse "");
            } else if (std.mem.eql(u8, ty, "ask_user")) {
                current_assistant = null;
                const input = objectField(event, "input") orelse event;
                const call_id = stringField(event, "call_id") orelse self.uniqueId("ask-user");
                const question = stringField(input, "question") orelse "";
                const id = self.fmt("{s}-tool-{d}", .{ request_id, nowMillis() });
                self.appendToolStart(conversation_id, request_id, id, "ask_user", call_id, question);
                self.setFollowup(conversation_id, request_id, workspace, call_id, question);
            } else if (std.mem.eql(u8, ty, "tool_result")) {
                current_assistant = null;
                const name = stringField(event, "name") orelse "tool";
                const text = stringField(event, "text") orelse "";
                const is_error = boolField(event, "is_error") orelse false;
                self.appendToolEnd(conversation_id, request_id, self.fmt("{s}-toolend-{d}", .{ request_id, nowMillis() }), name, text, is_error);
            } else if (std.mem.eql(u8, ty, "error")) {
                const msg = stringField(event, "message") orelse "graff error";
                self.appendError(conversation_id, request_id, msg);
                break;
            } else if (std.mem.eql(u8, ty, "turn")) {
                break;
            }
        }
        if (event_count == 0) {
            self.appendError(conversation_id, request_id, "graff exited before producing a response");
        }
    }

    fn appendDelta(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, kind: Message.Kind, delta: []const u8) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            var i = conv.messages.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, conv.messages.items[i].id, id)) {
                    conv.messages.items[i].text = self.fmt("{s}{s}", .{ conv.messages.items[i].text, delta });
                    self.bumpLocked();
                    return;
                }
            }
            conv.messages.append(self.arena, .{ .kind = kind, .id = id, .request_id = rid, .text = self.dupe(delta) }) catch {};
            self.bumpLocked();
        }
    }

    fn appendToolStart(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, name: []const u8, call_id: ?[]const u8, question: []const u8) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            conv.messages.append(self.arena, .{ .kind = .tool_start, .id = id, .request_id = rid, .name = self.dupe(name), .call_id = if (call_id) |c| self.dupe(c) else null, .question = self.dupe(question) }) catch {};
            self.bumpLocked();
        }
    }

    fn appendToolEnd(self: *Runtime, cid: []const u8, rid: []const u8, id: []const u8, name: []const u8, text: []const u8, is_error: bool) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            conv.messages.append(self.arena, .{ .kind = .tool_end, .id = id, .request_id = rid, .name = self.dupe(name), .summary = firstLine(self.arena, text), .text = self.dupe(text), .is_error = is_error }) catch {};
            self.bumpLocked();
        }
    }

    fn appendError(self: *Runtime, cid: []const u8, rid: []const u8, msg: []const u8) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            conv.messages.append(self.arena, .{ .kind = .@"error", .id = self.fmt("{s}-error-{d}", .{ rid, nowMillis() }), .request_id = rid, .error_message = self.dupe(msg) }) catch {};
            self.bumpLocked();
        }
    }

    fn setFollowup(self: *Runtime, cid: []const u8, rid: []const u8, workspace: []const u8, call_id: []const u8, question: []const u8) void {
        self.mutex.lockUncancelable(mer_runtime.io);
        defer self.mutex.unlock(mer_runtime.io);
        if (self.conversations.get(cid)) |conv| {
            conv.followup = .{ .followup_id = self.dupe(call_id), .workspace_path = self.dupe(workspace), .conversation_id = conv.conversation_id, .request_id = rid, .question = self.dupe(question), .call_id = self.dupe(call_id) };
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
        var it = self.conversations.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeByte(',');
            first = false;
            try self.writeConversationView(w, entry.value_ptr.*);
        }
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
                .user, .context_compacted, .assistant, .reasoning => {
                    try w.writeAll(",\"text\":");
                    try writeString(w, message.text);
                },
                .tool_start => {
                    try w.writeAll(",\"name\":");
                    try writeString(w, message.name);
                    try w.writeAll(",\"callId\":");
                    try writeNullableString(w, message.call_id);
                    if (std.mem.eql(u8, message.name, "ask_user")) {
                        try w.writeAll(",\"detail\":{\"kind\":\"followup\",\"question\":");
                        try writeString(w, message.question);
                        try w.writeAll("}");
                    } else {
                        try w.writeAll(",\"detail\":{\"kind\":\"unknown\",\"name\":");
                        try writeString(w, message.name);
                        try w.writeAll("}");
                    }
                },
                .tool_end => {
                    try w.writeAll(",\"name\":");
                    try writeString(w, message.name);
                    try w.writeAll(",\"callId\":null,\"summary\":");
                    try writeNullableString(w, message.summary);
                    try w.writeAll(",\"isError\":");
                    try w.writeAll(if (message.is_error) "true" else "false");
                    try w.writeAll(",\"detail\":");
                    if (message.text.len > 0) {
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
        try w.writeAll(",\"kind\":\"text\",\"question\":");
        try writeString(w, f.question);
        try w.writeAll(",\"options\":null}");
    }

    fn runtimeStatusJson(self: *Runtime, alloc: std.mem.Allocator, path: ?[]const u8) !mer.Response {
        _ = self;
        var out: std.Io.Writer.Allocating = .init(alloc);
        const p = path orelse "";
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
        try writeNullableString(&out.writer, if (git.repo_name != null) "main" else null);
        try out.writer.writeAll(",\"gitMainWorkspacePath\":");
        try writeNullableString(&out.writer, git.root_path);
        try out.writer.writeAll(",\"availableOpenTargets\":[\"terminal\"],\"configured\":true,\"configurationError\":null}");
        return mer.json(out.written());
    }

    fn promptSettingsJson(self: *Runtime, alloc: std.mem.Allocator) ![]const u8 {
        const schema = schemaValue(alloc, self.codegraffBinary()) catch null;
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

    fn createConversationLocked(self: *Runtime, workspace: []const u8, cid_raw: []const u8, title_raw: []const u8) *Conversation {
        const wpath = self.dupe(workspace);
        const cid = self.dupe(cid_raw);
        self.setActiveWorkspaceLocked(wpath);
        const conv = self.arena.create(Conversation) catch @panic("oom");
        conv.* = .{ .workspace_path = wpath, .conversation_id = cid, .title = self.dupe(title_raw), .active_agent_id = self.active_agent_id, .updated_at = 0 };
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
        if (self.settings_loaded) {
            self.mutex.unlock(mer_runtime.io);
            return;
        }
        self.settings_loaded = true;
        self.mutex.unlock(mer_runtime.io);
        self.loadPromptSettings();
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

const PromptSelection = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
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
    if (value < 1 or value > 500) return default;
    return @intCast(value);
}

fn tryPromptText(alloc: std.mem.Allocator, workspace: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc, "{s} $ ", .{workspaceName(workspace)}) catch "$ ";
}

fn terminalCommandOutput(alloc: std.mem.Allocator, cwd: []const u8, command: []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "/usr/bin/env");
    try argv.append(alloc, try std.fmt.allocPrint(alloc, "HOME={s}", .{homeDir()}));
    try argv.append(alloc, try std.fmt.allocPrint(alloc, "PATH={s}/bin:{s}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", .{ homeDir(), homeDir() }));
    try argv.append(alloc, "/bin/zsh");
    try argv.append(alloc, "-lc");
    try argv.append(alloc, command);
    var child = try std.process.spawn(mer_runtime.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const out_file = child.stdout orelse return error.CommandFailed;
    var rbuf: [8 * 1024]u8 = undefined;
    var reader = out_file.readerStreaming(mer_runtime.io, &rbuf);
    const output = try reader.interface.allocRemaining(alloc, .limited(512 * 1024));
    const term = try child.wait(mer_runtime.io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
    return output;
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
    branches: []const []const u8 = &.{},
};

const GitFileStatus = struct {
    path: []const u8,
    status: []const u8,
};

fn gitRuntimeStatus(alloc: std.mem.Allocator, workspace: []const u8) GitRuntimeStatus {
    if (workspace.len == 0) return .{};
    const root_raw = gitOutput(alloc, workspace, &.{ "git", "rev-parse", "--show-toplevel" }) catch return .{};
    const root = std.mem.trim(u8, root_raw, " \t\r\n");
    if (root.len == 0) return .{};
    const branch_raw = gitOutput(alloc, workspace, &.{ "git", "branch", "--show-current" }) catch "";
    const branch = std.mem.trim(u8, branch_raw, " \t\r\n");
    return .{
        .root_path = alloc.dupe(u8, root) catch root,
        .repo_name = alloc.dupe(u8, workspaceName(root)) catch workspaceName(root),
        .branch_name = if (branch.len == 0) null else alloc.dupe(u8, branch) catch branch,
        .branches = gitBranches(alloc, workspace) catch &.{},
    };
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
    const key = env_key orelse {
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

fn providerConfiguredById(id: []const u8, env_key: ?[]const u8) bool {
    if (providerConfigured(env_key)) return true;
    const alloc = std.heap.page_allocator;
    if (std.mem.eql(u8, id, "codegraff")) return codegraffStored(alloc);
    if (std.mem.eql(u8, id, "codex")) return fileExists(std.fmt.allocPrint(alloc, "{s}/.codex/auth.json", .{homeDir()}) catch return false);
    if (std.mem.eql(u8, id, "kimi")) return fileExists(std.fmt.allocPrint(alloc, "{s}/.kimi/credentials/graff-oauth.json", .{homeDir()}) catch return false) or storedKeyExists(alloc, id);
    return storedKeyExists(alloc, id);
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

fn providerSummaryResponse(req: mer.Request, provider: []const u8) mer.Response {
    var out: std.Io.Writer.Allocating = .init(req.allocator);
    const info = providerInfo(provider);
    out.writer.writeAll("{\"id\":") catch return oom();
    writeString(&out.writer, provider) catch return oom();
    out.writer.writeAll(",\"name\":") catch return oom();
    writeString(&out.writer, info.name) catch return oom();
    out.writer.writeAll(",\"configured\":") catch return oom();
    out.writer.writeAll(if (providerConfiguredById(provider, info.env_key)) "true" else "false") catch return oom();
    out.writer.writeAll(",\"authMethods\":[{\"kind\":") catch return oom();
    writeString(&out.writer, info.auth_kind) catch return oom();
    out.writer.writeAll(",\"label\":") catch return oom();
    writeString(&out.writer, info.auth_label) catch return oom();
    out.writer.writeAll("}],\"envOverride\":") catch return oom();
    writeEnvOverride(&out.writer, info.env_key) catch return oom();
    out.writer.writeAll("}") catch return oom();
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
    \\[{"name":"help","usage":"Show available commands.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":false,"argumentHint":null,"resultKind":"text"},{"name":"agent","usage":"Show active agent.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":false,"argumentHint":null,"resultKind":"agents"},{"name":"bash","usage":"Run a shell command in the workspace.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":false,"argumentHint":"<command>","resultKind":"text"},{"name":"goal","usage":"Set/show the current objective.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":false,"requiresConversation":true,"argumentHint":"<objective|clear>","resultKind":"text"},{"name":"loop","usage":"Run an autonomous plan-act-verify pass.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":true,"argumentHint":"<prompt>","resultKind":"snapshot"},{"name":"compact","usage":"Compact current conversation.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":true,"argumentHint":null,"resultKind":"text"},{"name":"workspace-status","usage":"Show git status.","aliases":[],"kind":"builtin","value":null,"isAgentSwitch":false,"executionKind":"runnable","requiresWorkspace":true,"requiresConversation":false,"argumentHint":null,"resultKind":"workspaceStatus"}]
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

    writeFrame(&bw, ": connected\n\n");
    var seen = self.version.load(.acquire);
    var seen_event_seq: u64 = 0;
    while (true) {
        _ = io.sleep(.fromMilliseconds(100), .awake) catch break;
        var event_alloc_failed = false;
        self.event_mutex.lockUncancelable(io);
        for (self.events.items) |ev| {
            if (ev.seq <= seen_event_seq) continue;
            const frame = std.fmt.allocPrint(alloc, "event: {s}\ndata: {s}\n\n", .{ ev.name, ev.data }) catch {
                event_alloc_failed = true;
                break;
            };
            writeFrame(&bw, frame);
            seen_event_seq = ev.seq;
        }
        self.event_mutex.unlock(io);
        if (event_alloc_failed) break;

        const current = self.version.load(.acquire);
        if (current == seen) continue;
        seen = current;
        const json = self.snapshotJson(alloc) catch break;
        const frame = std.fmt.allocPrint(alloc, "event: session-updated\ndata: {s}\n\n", .{json}) catch break;
        writeFrame(&bw, frame);
    }
    bw.end() catch {};
    return true;
}

fn writeFrame(bw: *std.http.BodyWriter, frame: []const u8) void {
    bw.writer.writeAll(frame) catch return;
    bw.writer.flush() catch return;
    bw.http_protocol_output.flush() catch return;
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
