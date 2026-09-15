use super::*;

impl RuntimeManager {
    /// Sends a prompt and streams the reply from a persistent `graff --json`
    /// session bound to the conversation. Incremental session snapshots are
    /// emitted as text/tool events arrive, so the UI renders tokens live.
    pub async fn send_prompt(&self, input: SendPromptInput) -> Result<SessionSnapshotDto> {
        crate::clipboard_files::retain_prompt(&input.prompt)?;
        let conversation_id = input
            .conversation_id
            .clone()
            .unwrap_or_else(|| format!("chat-{}", Uuid::new_v4().simple()));
        let request_id = format!("request-{}", Uuid::new_v4().simple());
        let plan_mode = input.agent_id.as_deref() == Some("muse");
        let loop_mode = input.agent_id.as_deref() == Some("loop");
        let usage_model_pair = self.selected_model_pair().await;
        let title_model_arg = usage_model_pair
            .as_ref()
            .map(|(provider, model)| prompt_model_arg(provider, model));
        let is_first_turn;
        let engine_prompt;
        let should_queue;
        {
            let mut state = self.state.lock().await;
            set_active_workspace(&mut state, &input.workspace_path);
            state.active_conversation_id = Some(conversation_id.clone());
            state
                .selected_by_workspace
                .insert(input.workspace_path.clone(), conversation_id.clone());
            let active_agent_id = state.active_agent_id.clone();
            let conversation = state
                .conversations
                .entry(conversation_id.clone())
                .or_insert_with(|| ConversationState {
                    workspace_path: input.workspace_path.clone(),
                    conversation_id: conversation_id.clone(),
                    title: title_from_prompt(&input.prompt),
                    messages: vec![],
                    active_request_ids: vec![],
                    request_agent_ids: HashMap::new(),
                    queued_prompts: VecDeque::new(),
                    active_agent_id,
                    plan_mode,
                    ultracode_enabled: false,
                    todos: Vec::new(),
                    goal: None,
                    recap: None,
                    updated_at: now_millis(),
                });
            conversation.plan_mode = plan_mode;
            conversation.updated_at = now_millis();
            let goal_prompt = conversation
                .goal
                .as_ref()
                .map(|goal| format!("{}\n\n[harness goal: {}]", input.prompt, goal))
                .unwrap_or_else(|| input.prompt.clone());
            engine_prompt = if loop_mode {
                format!(
                    "{goal_prompt}\n\n[harness note: /loop was used. Work autonomously until the prompt is satisfied: make a brief plan, execute it with tools, verify the result, and only stop when you can report completion or you need a required human decision. Keep iterations tight and avoid asking for confirmation between routine steps.]"
                )
            } else {
                goal_prompt
            };
            is_first_turn = conversation.messages.is_empty();
            if is_first_turn && is_placeholder_title(&conversation.title) {
                conversation.title = title_from_prompt(&input.prompt);
            }
            conversation.messages.push(SessionMessageDto::User {
                id: format!("{request_id}-user"),
                request_id: request_id.clone(),
                text: input.prompt.clone(),
            });
            // Remember which agent ("muse" planning / "forge" normal) this
            // request ran under so the GUI's plan-decision card can light up
            // after a planning-mode turn completes (gate keys off "muse").
            conversation.request_agent_ids.insert(
                request_id.clone(),
                input
                    .agent_id
                    .clone()
                    .unwrap_or_else(|| "forge".to_string()),
            );
            should_queue = !conversation.active_request_ids.is_empty();
            if should_queue {
                conversation.queued_prompts.push_back(QueuedPrompt {
                    agent_id: input.agent_id.clone(),
                    engine_prompt: engine_prompt.clone(),
                    request_id: request_id.clone(),
                });
            } else {
                conversation.active_request_ids.push(request_id.clone());
            }
        }

        if let Some((provider_id, model_id)) = usage_model_pair.as_ref() {
            self.record_model_usage(provider_id, model_id).await;
        }

        // Managed chats are auto-created `chat_<id>` folders; once a chat has a
        // prompt, give the workspace a readable name derived from it (unless the
        // user already named it). Projects keep their folder/display name.
        if let Ok(Some(registration)) = self
            .projects
            .get_workspace_registration(Path::new(&input.workspace_path))
        {
            if registration.kind == RegisteredWorkspaceKind::ManagedChat
                && registration.display_name.is_none()
            {
                let _ = self.projects.set_workspace_display_name(
                    Path::new(&input.workspace_path),
                    Some(&title_from_prompt(&input.prompt)),
                );
            }
        }

        self.emit().await?;

        if should_queue {
            return self.snapshot().await;
        }

        if is_first_turn {
            let manager = self.clone();
            let conversation_id = conversation_id.clone();
            let prompt = input.prompt.clone();
            tokio::spawn(async move {
                manager
                    .generate_and_set_title(conversation_id, prompt, title_model_arg)
                    .await;
            });
        }

        if self.session_exists(&conversation_id).await {
            self.send_control(
                &conversation_id,
                serde_json::json!({
                    "type": "set_mode",
                    "mode": if plan_mode { "plan" } else { "normal" },
                }),
            )
            .await?;
        }

        if let Err(error) = self
            .stream_turn(
                &conversation_id,
                &request_id,
                &input.workspace_path,
                &engine_prompt,
            )
            .await
        {
            let message = format_error_chain(&error);
            let id = format!("{request_id}-error");
            let rid = request_id.clone();
            self.mutate_conversation(&conversation_id, move |conversation| {
                conversation.messages.push(SessionMessageDto::Error {
                    id,
                    request_id: rid,
                    message,
                });
            })
            .await;
        }

        let mut completed_request_id = request_id;
        loop {
            let next_prompt = {
                let mut state = self.state.lock().await;
                let Some(conversation) = state.conversations.get_mut(&conversation_id) else {
                    break;
                };
                conversation
                    .active_request_ids
                    .retain(|id| id != &completed_request_id);
                let next = conversation.queued_prompts.pop_front();
                if let Some(next) = &next {
                    conversation.plan_mode = next.agent_id.as_deref() == Some("muse");
                    conversation.updated_at = now_millis();
                    conversation
                        .active_request_ids
                        .push(next.request_id.clone());
                }
                next
            };

            let Some(next_prompt) = next_prompt else {
                break;
            };

            self.emit().await?;

            let next_plan_mode = next_prompt.agent_id.as_deref() == Some("muse");
            if self.session_exists(&conversation_id).await {
                self.send_control(
                    &conversation_id,
                    serde_json::json!({
                        "type": "set_mode",
                        "mode": if next_plan_mode { "plan" } else { "normal" },
                    }),
                )
                .await?;
            }

            if let Err(error) = self
                .stream_turn(
                    &conversation_id,
                    &next_prompt.request_id,
                    &input.workspace_path,
                    &next_prompt.engine_prompt,
                )
                .await
            {
                let message = format_error_chain(&error);
                let id = format!("{}-error", next_prompt.request_id);
                let rid = next_prompt.request_id.clone();
                self.mutate_conversation(&conversation_id, move |conversation| {
                    conversation.messages.push(SessionMessageDto::Error {
                        id,
                        request_id: rid,
                        message,
                    });
                })
                .await;
            }

            completed_request_id = next_prompt.request_id;
        }

        let snapshot = self.snapshot().await?;
        let _ = self.emitter.emit_session_updated(snapshot.clone());
        self.persist_conversations().await;
        Ok(snapshot)
    }
}
