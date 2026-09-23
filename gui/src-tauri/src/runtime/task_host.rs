//! Task-workspace host methods, split out of runtime/simple.rs so that file
//! does not grow.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::dto::*;
use crate::persistence::project_store::TaskWorkspaceRecord;
use crate::task_workspace;

use super::{
    RuntimeManager, canonicalize_workspace_path, first_workspace_conversation_id, run_git,
    set_active_workspace,
};

pub(super) fn summary(record: &TaskWorkspaceRecord) -> TaskWorkspaceSummaryDto {
    let inspection = task_workspace::inspect(Path::new(&record.path), &record.base_commit);
    TaskWorkspaceSummaryDto {
        branch: record.branch.clone(),
        base_branch: record.base_branch.clone(),
        base_commit: record.base_commit.clone(),
        checkout_bytes: inspection.checkout_bytes,
        keep_reason: record
            .keep_reason
            .clone()
            .or_else(|| inspection.keep.text().map(str::to_string)),
        setup_script: record.setup_script.clone(),
        run_script: record.run_script.clone(),
        teardown_script: record.teardown_script.clone(),
        setup_error: record.setup_error.clone(),
        run_error: record.run_error.clone(),
        merged_back: record.merged_back != 0,
    }
}

impl RuntimeManager {
    pub(super) async fn archive_if_task(
        &self,
        path: &str,
    ) -> Result<Option<crate::dto::SessionSnapshotDto>> {
        if self.projects.get_task_workspace(Path::new(path))?.is_some() {
            return Ok(Some(self.finish_task_workspace(path, false, false).await?));
        }
        Ok(None)
    }

    pub(super) fn task_records(&self) -> HashMap<String, TaskWorkspaceRecord> {
        self.projects
            .list_task_workspaces()
            .unwrap_or_default()
            .into_iter()
            .map(|record| (record.path.clone(), record))
            .collect()
    }

    /// Moves a chat onto a fresh task worktree, or checks out a local branch.
    pub async fn handoff_chat(&self, input: HandoffChatInput) -> Result<SessionSnapshotDto> {
        match input.target {
            ChatHandoffTargetDto::Local => {
                if let Some(branch) = input
                    .branch_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|name| !name.is_empty())
                {
                    run_git(&input.source_workspace_path, &["checkout", "-b", branch])?;
                }
                if let Some(conversation_id) = input.conversation_id {
                    self.select_conversation(input.source_workspace_path, conversation_id)
                        .await
                } else {
                    self.start_new_chat(input.source_workspace_path).await
                }
            }
            ChatHandoffTargetDto::Worktree => {
                let branch = input
                    .branch_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|name| !name.is_empty())
                    .context("a branch name is required to start a worktree")?;
                self.create_task_workspace(
                    &input.source_workspace_path,
                    None,
                    branch,
                    None,
                    None,
                    None,
                    input.conversation_id,
                )
                .await
            }
        }
    }

    pub async fn task_workspace_action(
        &self,
        input: TaskWorkspaceActionInput,
    ) -> Result<SessionSnapshotDto> {
        match input.action {
            TaskWorkspaceActionDto::Create => {
                let source = input
                    .source_workspace_path
                    .as_deref()
                    .filter(|path| !path.is_empty())
                    .context("choose a repository to branch from")?;
                let branch = input
                    .branch_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|name| !name.is_empty())
                    .context("a branch name is required")?;
                self.create_task_workspace(
                    source,
                    input.base_branch.as_deref(),
                    branch,
                    input.setup_script.as_deref(),
                    input.run_script.as_deref(),
                    input.teardown_script.as_deref(),
                    None,
                )
                .await
            }
            TaskWorkspaceActionDto::Archive => {
                let path = input
                    .workspace_path
                    .as_deref()
                    .context("workspace path required")?;
                self.finish_task_workspace(path, false, input.delete_branch)
                    .await
            }
            TaskWorkspaceActionDto::Discard => {
                let path = input
                    .workspace_path
                    .as_deref()
                    .context("workspace path required")?;
                self.finish_task_workspace(path, true, input.delete_branch)
                    .await
            }
            TaskWorkspaceActionDto::MergeBack => self.merge_task_workspace(&input).await,
            TaskWorkspaceActionDto::UpdateFromBase => self.update_task_workspace(&input).await,
            TaskWorkspaceActionDto::SyncMerged => {
                self.auto_archive_merged_tasks(true).await;
                self.snapshot().await
            }
        }
    }

    pub async fn task_workspace_review(
        &self,
        workspace_path: String,
    ) -> Result<TaskWorkspaceReviewDto> {
        let record = self
            .projects
            .get_task_workspace(Path::new(&workspace_path))?
            .context("not a task workspace")?;
        match task_workspace::review_diff(Path::new(&record.path), &record.base_branch) {
            Ok(diff) => Ok(TaskWorkspaceReviewDto {
                workspace_path: record.path,
                branch: record.branch,
                base_branch: record.base_branch,
                stat: diff.stat,
                patch: diff.patch,
                error: None,
            }),
            Err(error) => Ok(TaskWorkspaceReviewDto {
                workspace_path: record.path,
                branch: record.branch,
                base_branch: record.base_branch,
                stat: String::new(),
                patch: String::new(),
                error: Some(error.to_string()),
            }),
        }
    }

    async fn create_task_workspace(
        &self,
        source: &str,
        base_branch: Option<&str>,
        branch: &str,
        setup_script: Option<&str>,
        run_script: Option<&str>,
        teardown_script: Option<&str>,
        conversation_id: Option<String>,
    ) -> Result<SessionSnapshotDto> {
        let created = task_workspace::create_task_worktree(Path::new(source), base_branch, branch)?;
        let path = canonicalize_workspace_path(created.path.clone())?;
        let blank = |value: Option<&str>| {
            value
                .map(str::trim)
                .filter(|script| !script.is_empty())
                .map(ToOwned::to_owned)
        };
        let record = TaskWorkspaceRecord {
            path: path.clone(),
            branch: created.branch,
            base_branch: created.base_branch,
            base_commit: created.base_commit,
            setup_script: blank(setup_script),
            run_script: blank(run_script),
            teardown_script: blank(teardown_script),
            setup_ran: 0,
            setup_error: None,
            run_error: None,
            keep_reason: None,
            merged_back: 0,
        };
        self.projects.upsert_task_workspace(&record)?;
        self.projects.add_project(Path::new(&path))?;
        let setup_error = if let Some(script) = record.setup_script.as_deref() {
            let outcome = task_workspace::run_script(Path::new(&path), script);
            let error = (!outcome.ok).then_some(outcome.output);
            self.projects
                .set_task_setup_result(&path, error.as_deref())?;
            error
        } else {
            None
        };
        if let Some(conversation_id) = conversation_id {
            let mut state = self.state.lock().await;
            if let Some(conversation) = state.conversations.get_mut(&conversation_id) {
                conversation.workspace_path = path.clone();
            }
            set_active_workspace(&mut state, &path);
            state.active_conversation_id = Some(conversation_id.clone());
            state
                .selected_by_workspace
                .insert(path.clone(), conversation_id);
            drop(state);
        } else {
            self.open_workspace(PathBuf::from(&path)).await?;
            self.start_new_chat(path.clone()).await?;
        }
        let mut snapshot = self.snapshot().await?;
        if let Some(error) = setup_error {
            snapshot.ui_error = Some(format!(
                "worktree created, but the setup script failed:\n{error}"
            ));
        }
        Ok(snapshot)
    }

    async fn finish_task_workspace(
        &self,
        workspace_path: &str,
        discard: bool,
        delete_branch: bool,
    ) -> Result<SessionSnapshotDto> {
        let record = self
            .projects
            .get_task_workspace(Path::new(workspace_path))?
            .context("not a task workspace")?;
        let inspection = task_workspace::inspect(Path::new(&record.path), &record.base_commit);
        if !discard {
            if let Some(reason) = inspection.keep.text() {
                self.projects
                    .set_task_keep_reason(&record.path, Some(reason))?;
                let mut snapshot = self.snapshot().await?;
                snapshot.ui_error = Some(format!("kept {} — {reason}", record.path));
                return Ok(snapshot);
            }
        }
        if let Some(script) = record
            .teardown_script
            .as_deref()
            .filter(|script| !script.trim().is_empty())
        {
            let outcome = task_workspace::run_script(Path::new(&record.path), script);
            if !outcome.ok && !discard {
                self.projects
                    .set_task_keep_reason(&record.path, Some(task_workspace::KEEP_TEARDOWN))?;
                let mut snapshot = self.snapshot().await?;
                snapshot.ui_error = Some(format!(
                    "kept {} — teardown hook failed\n{}",
                    record.path, outcome.output
                ));
                return Ok(snapshot);
            }
        }
        let repo = task_workspace::repo_root(Path::new(&record.path));
        task_workspace::remove_checkout(Path::new(&record.path), discard)?;
        let branch_note = if task_workspace::branch_delete_allowed(
            task_workspace::worktree_exists(Path::new(&record.path)),
            record.merged_back == 1,
            delete_branch,
        ) {
            match task_workspace::delete_branch(&repo, &record.branch, true) {
                Ok(()) => None,
                Err(error) => Some(format!("checkout removed, branch kept — {error}")),
            }
        } else {
            None
        };
        self.projects.delete_task_workspace(&record.path)?;
        self.projects.archive_workspace(Path::new(&record.path))?;
        self.forget_workspace(&record.path).await;
        self.persist_conversations().await;
        let snapshot = self.snapshot().await?;
        if let Some(note) = branch_note {
            let mut snapshot = snapshot;
            snapshot.ui_error = Some(note);
            return Ok(snapshot);
        }
        Ok(snapshot)
    }

    async fn merge_task_workspace(
        &self,
        input: &TaskWorkspaceActionInput,
    ) -> Result<SessionSnapshotDto> {
        let path = input
            .workspace_path
            .as_deref()
            .context("workspace path required")?;
        let record = self
            .projects
            .get_task_workspace(Path::new(path))?
            .context("not a task workspace")?;
        let repo = task_workspace::repo_root(Path::new(&record.path));
        if let Err(error) = task_workspace::merge_back(&repo, &record.branch) {
            let mut snapshot = self.snapshot().await?;
            snapshot.ui_error = Some(error.to_string());
            return Ok(snapshot);
        }
        self.projects.set_task_merged_back(&record.path)?;
        let mut snapshot = self.snapshot().await?;
        snapshot.ui_error = Some(format!(
            "landed {} onto {} as one commit",
            record.branch, record.base_branch
        ));
        Ok(snapshot)
    }

    async fn update_task_workspace(
        &self,
        input: &TaskWorkspaceActionInput,
    ) -> Result<SessionSnapshotDto> {
        let path = input
            .workspace_path
            .as_deref()
            .context("workspace path required")?;
        let record = self
            .projects
            .get_task_workspace(Path::new(path))?
            .context("not a task workspace")?;
        if let Err(error) =
            task_workspace::update_from_base(Path::new(&record.path), &record.base_branch)
        {
            let mut snapshot = self.snapshot().await?;
            snapshot.ui_error = Some(error.to_string());
            return Ok(snapshot);
        }
        self.projects.set_task_keep_reason(&record.path, None)?;
        let mut snapshot = self.snapshot().await?;
        snapshot.ui_error = Some(format!("updated from {}", record.base_branch));
        Ok(snapshot)
    }

    pub(super) async fn auto_archive_merged_tasks(&self, include_remote: bool) {
        let records = self.projects.list_task_workspaces().unwrap_or_default();
        for record in records {
            let proof = if include_remote {
                task_workspace::proven_merged(
                    Path::new(&record.path),
                    &record.branch,
                    &record.base_branch,
                )
            } else {
                task_workspace::proven_merged_local(
                    Path::new(&record.path),
                    &record.branch,
                    &record.base_branch,
                )
            };
            if proof != task_workspace::MergeProof::Merged {
                continue;
            }
            let inspection = task_workspace::inspect(Path::new(&record.path), &record.base_commit);
            if let Some(reason) = inspection.keep.text() {
                let _ = self
                    .projects
                    .set_task_keep_reason(&record.path, Some(reason));
                continue;
            }
            if let Some(script) = record
                .teardown_script
                .as_deref()
                .filter(|script| !script.trim().is_empty())
            {
                let outcome = task_workspace::run_script(Path::new(&record.path), script);
                if !outcome.ok {
                    let _ = self
                        .projects
                        .set_task_keep_reason(&record.path, Some(task_workspace::KEEP_TEARDOWN));
                    continue;
                }
            }
            if task_workspace::remove_checkout(Path::new(&record.path), false).is_err() {
                let _ = self.projects.set_task_keep_reason(
                    &record.path,
                    Some(task_workspace::KEEP_UNVERIFIABLE),
                );
                continue;
            }
            let _ = self.projects.delete_task_workspace(&record.path);
            let _ = self.projects.archive_workspace(Path::new(&record.path));
            self.forget_workspace(&record.path).await;
        }
    }

    async fn forget_workspace(&self, workspace_path: &str) {
        let conversation_ids: Vec<String> = {
            let state = self.state.lock().await;
            state
                .conversations
                .values()
                .filter(|conversation| conversation.workspace_path == workspace_path)
                .map(|conversation| conversation.conversation_id.clone())
                .collect()
        };
        for conversation_id in &conversation_ids {
            self.drop_session(conversation_id).await;
        }
        let removed: HashSet<String> = conversation_ids.into_iter().collect();
        let mut state = self.state.lock().await;
        state.workspaces.retain(|path| path != workspace_path);
        state
            .conversations
            .retain(|_, conversation| conversation.workspace_path != workspace_path);
        state.selected_by_workspace.remove(workspace_path);
        state
            .selected_by_workspace
            .retain(|_, conversation_id| !removed.contains(conversation_id));
        if state.active_workspace_path.as_deref() == Some(workspace_path) {
            state.active_workspace_path = state.workspaces.first().cloned();
            state.active_conversation_id = state
                .active_workspace_path
                .clone()
                .and_then(|path| first_workspace_conversation_id(&state, &path));
        } else if state
            .active_conversation_id
            .as_ref()
            .is_some_and(|conversation_id| removed.contains(conversation_id))
        {
            state.active_conversation_id = state
                .active_workspace_path
                .clone()
                .and_then(|path| first_workspace_conversation_id(&state, &path));
        }
    }
}
