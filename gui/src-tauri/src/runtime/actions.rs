use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Context;
use bstr::ByteSlice;
use forge_api::API;
use forge_domain::ConversationId;
use url::Url;

use crate::desktop_open;
use crate::dto::{
    ChatHandoffTargetDto, HandoffChatInput, RuntimeStatusDto, read_git_workspace_details,
};

use super::RuntimeManager;

impl RuntimeManager {
    pub async fn checkout_git_branch(
        &self,
        workspace_path: String,
        branch_name: String,
    ) -> anyhow::Result<RuntimeStatusDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = self.workspace_path_for_action(&workspace_path).await?;
            let branch_name = validate_non_empty_value(&branch_name, "Branch name")?;

            if git_ref_exists(&workspace_path, &format!("refs/heads/{branch_name}"))? {
                run_git_command(&workspace_path, &["checkout", &branch_name], "git checkout")?;
            } else if git_ref_exists(&workspace_path, &format!("refs/remotes/{branch_name}"))? {
                let local_branch_name = branch_name
                    .rsplit('/')
                    .next()
                    .filter(|candidate| !candidate.is_empty())
                    .unwrap_or(branch_name.as_str());

                if git_ref_exists(&workspace_path, &format!("refs/heads/{local_branch_name}"))? {
                    run_git_command(
                        &workspace_path,
                        &["checkout", local_branch_name],
                        "git checkout",
                    )?;
                } else {
                    run_git_command(
                        &workspace_path,
                        &["checkout", "--track", &branch_name],
                        "git checkout --track",
                    )?;
                }
            } else {
                run_git_command(&workspace_path, &["checkout", &branch_name], "git checkout")?;
            }

            self.finish_runtime_status_action(Some(workspace_path.as_path()))
                .await
        })
        .await
    }

    pub async fn create_git_branch(
        &self,
        workspace_path: String,
        branch_name: String,
    ) -> anyhow::Result<RuntimeStatusDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = self.workspace_path_for_action(&workspace_path).await?;
            let branch_name = validate_non_empty_value(&branch_name, "Branch name")?;

            run_git_command(
                &workspace_path,
                &["check-ref-format", "--branch", &branch_name],
                "git check-ref-format",
            )?;
            run_git_command(
                &workspace_path,
                &["checkout", "-b", &branch_name],
                "git checkout -b",
            )?;

            self.finish_runtime_status_action(Some(workspace_path.as_path()))
                .await
        })
        .await
    }

    pub async fn commit_git_changes(
        &self,
        workspace_path: String,
        message: String,
    ) -> anyhow::Result<RuntimeStatusDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = self.workspace_path_for_action(&workspace_path).await?;
            let message = validate_non_empty_value(&message, "Commit message")?;

            run_git_command(&workspace_path, &["add", "-A"], "git add")?;
            run_git_command(&workspace_path, &["commit", "-m", &message], "git commit")?;

            self.finish_runtime_status_action(Some(workspace_path.as_path()))
                .await
        })
        .await
    }

    pub async fn push_git_branch(
        &self,
        workspace_path: String,
    ) -> anyhow::Result<RuntimeStatusDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = self.workspace_path_for_action(&workspace_path).await?;
            let current_branch = run_git_stdout(
                &workspace_path,
                &["rev-parse", "--abbrev-ref", "HEAD"],
                "git rev-parse",
            )?;

            if current_branch == "HEAD" {
                anyhow::bail!("Cannot push from a detached HEAD state.");
            }

            if git_command_succeeds(
                &workspace_path,
                &[
                    "rev-parse",
                    "--abbrev-ref",
                    "--symbolic-full-name",
                    "@{upstream}",
                ],
            )? {
                run_git_command(&workspace_path, &["push"], "git push")?;
            } else {
                run_git_command(
                    &workspace_path,
                    &["push", "-u", "origin", &current_branch],
                    "git push -u",
                )?;
            }

            self.finish_runtime_status_action(Some(workspace_path.as_path()))
                .await
        })
        .await
    }

    pub async fn handoff_chat(
        &self,
        input: HandoffChatInput,
    ) -> anyhow::Result<crate::dto::SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let source_workspace_path = self
                .workspace_path_for_action(&input.source_workspace_path)
                .await?;
            let source_git_details = read_git_workspace_details(&source_workspace_path)
                .context("Worktree handoff is only available inside a git workspace.")?;
            let conversation_id = normalize_optional_value(input.conversation_id);
            let target_workspace_path = match input.target {
                ChatHandoffTargetDto::Local => {
                    self.prepare_local_workspace_for_handoff(
                        &source_workspace_path,
                        &source_git_details,
                        input.branch_name.as_deref(),
                    )
                    .await?
                }
                ChatHandoffTargetDto::Worktree => {
                    let branch_name = validate_non_empty_value(
                        input.branch_name.as_deref().unwrap_or_default(),
                        "Branch name",
                    )?;
                    self.create_git_worktree_from_workspace(
                        &source_workspace_path,
                        &source_git_details,
                        &branch_name,
                    )?
                }
            };
            let target_workspace_path_string = target_workspace_path.to_string_lossy().into_owned();

            if let Some(conversation_id) = conversation_id {
                let parsed_conversation_id = ConversationId::parse(&conversation_id)?;
                let source_runtime = self
                    .ensure_workspace_runtime(source_workspace_path.to_string_lossy().as_ref())
                    .await?;
                let conversation = source_runtime
                    .api
                    .conversation(&parsed_conversation_id)
                    .await?;

                if let Some(conversation) = conversation {
                    self.prepare_workspace(&target_workspace_path_string)
                        .await?;
                    let target_runtime = self
                        .ensure_workspace_runtime(&target_workspace_path_string)
                        .await?;
                    target_runtime.api.upsert_conversation(conversation).await?;
                    self.refresh_workspace_conversations(&target_workspace_path_string)
                        .await?;
                    return self
                        .select_conversation(target_workspace_path_string, conversation_id)
                        .await;
                }
            }

            self.start_new_chat(target_workspace_path_string).await
        })
        .await
    }

    pub async fn open_in_target(
        &self,
        workspace_path: String,
        target_id: String,
    ) -> anyhow::Result<()> {
        self.with_recorded_ui_error(async {
            let workspace_path = self.workspace_path_for_action(&workspace_path).await?;
            let target_id = validate_non_empty_value(&target_id, "Open target")?;
            desktop_open::open_path_in_target(&target_id, workspace_path.as_path())?;
            self.clear_ui_error().await?;
            Ok(())
        })
        .await
    }

    pub async fn open_path_in_target(
        &self,
        workspace_path: String,
        target_id: String,
        path: String,
    ) -> anyhow::Result<()> {
        self.with_recorded_ui_error(async {
            let workspace_path = self.workspace_path_for_action(&workspace_path).await?;
            let target_id = validate_non_empty_value(&target_id, "Open target")?;
            let path = validate_non_empty_value(&path, "Path")?;
            let resolved_path = resolve_path_for_target(&workspace_path, &path);
            desktop_open::open_path_in_target(&target_id, resolved_path.as_path())?;
            self.clear_ui_error().await?;
            Ok(())
        })
        .await
    }

    async fn finish_runtime_status_action(
        &self,
        workspace_path: Option<&Path>,
    ) -> anyhow::Result<RuntimeStatusDto> {
        self.clear_ui_error().await?;
        self.get_runtime_status(workspace_path.map(|path| path.to_string_lossy().into_owned()))
            .await
    }

    async fn workspace_path_for_action(&self, workspace_path: &str) -> anyhow::Result<PathBuf> {
        let workspace_path = super::canonicalize_workspace_path(PathBuf::from(workspace_path))?;
        self.ensure_known_workspaces_loaded().await?;
        self.prepare_workspace(&workspace_path).await?;
        let state = self.state.lock().await;
        let has_running_request = state.conversations.values().any(|conversation| {
            conversation.workspace_path == workspace_path
                && !conversation.active_request_ids.is_empty()
        });
        if has_running_request {
            anyhow::bail!("Wait for the current run to finish before running git actions.");
        }

        Ok(PathBuf::from(workspace_path))
    }

    async fn prepare_local_workspace_for_handoff(
        &self,
        source_workspace_path: &Path,
        source_git_details: &crate::dto::GitWorkspaceDetails,
        branch_name: Option<&str>,
    ) -> anyhow::Result<PathBuf> {
        let local_workspace_path = source_git_details
            .main_workspace_path
            .as_deref()
            .or(source_git_details.workspace_root_path.as_deref())
            .context("Failed to resolve the local workspace for this repository.")?;
        let local_workspace_path = self.workspace_path_for_action(local_workspace_path).await?;
        let branch_name = normalize_optional_str(branch_name);

        if let Some(branch_name) = branch_name {
            create_or_checkout_branch(
                &local_workspace_path,
                &branch_name,
                source_git_details.head_commit.as_deref(),
            )?;
        }

        if local_workspace_path != source_workspace_path {
            self.projects.add_project(local_workspace_path.as_path())?;
        }

        Ok(local_workspace_path)
    }

    fn create_git_worktree_from_workspace(
        &self,
        _source_workspace_path: &Path,
        source_git_details: &crate::dto::GitWorkspaceDetails,
        branch_name: &str,
    ) -> anyhow::Result<PathBuf> {
        let repo_root = source_git_details
            .main_workspace_path
            .as_deref()
            .or(source_git_details.workspace_root_path.as_deref())
            .context("Failed to resolve the repository root for this workspace.")?;
        let repo_root = PathBuf::from(repo_root);
        let parent_dir = repo_root.parent().context(
            "Git repository is at the filesystem root. Cannot create a sibling worktree.",
        )?;
        let directory_name = worktree_directory_name(branch_name);
        let worktree_path = parent_dir.join(directory_name);

        run_git_command(
            &repo_root,
            &["check-ref-format", "--branch", branch_name],
            "git check-ref-format",
        )?;

        if worktree_path.exists() {
            if git_command_succeeds(&worktree_path, &["rev-parse", "--is-inside-work-tree"])? {
                let canonical = canonicalize_existing_path(worktree_path)?;
                self.projects.add_project(canonical.as_path())?;
                return Ok(canonical);
            }

            anyhow::bail!(
                "Directory '{}' already exists and is not a git worktree.",
                worktree_path.display()
            );
        }

        let worktree_path_string = worktree_path.to_string_lossy().into_owned();
        if git_ref_exists(&repo_root, &format!("refs/heads/{branch_name}"))? {
            run_git_command(
                &repo_root,
                &["worktree", "add", &worktree_path_string, branch_name],
                "git worktree add",
            )?;
        } else {
            run_git_command(
                &repo_root,
                &["worktree", "add", "-b", branch_name, &worktree_path_string],
                "git worktree add -b",
            )?;
        }

        let canonical = canonicalize_existing_path(worktree_path)?;
        self.projects.add_project(canonical.as_path())?;
        Ok(canonical)
    }
}

fn resolve_path_for_target(workspace_path: &Path, path: &str) -> PathBuf {
    let clean_path = strip_file_path_metadata(path.trim());
    let raw_path = Path::new(&clean_path);
    if raw_path.is_absolute() {
        raw_path.to_path_buf()
    } else {
        workspace_path.join(raw_path)
    }
}

fn strip_file_path_metadata(path: &str) -> String {
    let (without_scheme, file_url_hash) = parse_file_url_path(path).unwrap_or_else(|| {
        let without_file_scheme = path.strip_prefix("file://").unwrap_or(path).to_string();
        let hash = without_file_scheme
            .split_once('#')
            .map(|(_, hash)| format!("#{hash}"));
        (without_file_scheme, hash)
    });

    let without_fragment = without_scheme.split('#').next().unwrap_or(&without_scheme);
    let without_query = without_fragment
        .split('?')
        .next()
        .unwrap_or(without_fragment);
    let mut value = append_position_from_hash(without_query.to_string(), file_url_hash.as_deref());

    if let Some(index) = value.rfind(':')
        && value[index + 1..]
            .chars()
            .all(|character| character.is_ascii_digit())
        && !is_windows_drive_colon(&value, index)
    {
        value.truncate(index);
        if let Some(index) = value.rfind(':')
            && value[index + 1..]
                .chars()
                .all(|character| character.is_ascii_digit())
            && !is_windows_drive_colon(&value, index)
        {
            value.truncate(index);
        }
    }

    value
}

fn parse_file_url_path(path: &str) -> Option<(String, Option<String>)> {
    let parsed = Url::parse(path).ok()?;
    if parsed.scheme() != "file" {
        return None;
    }

    let mut parsed_path = parsed.path().to_string();
    if let Some(host) = parsed.host_str().filter(|host| *host != "localhost") {
        parsed_path = if host.len() == 2
            && host
                .as_bytes()
                .first()
                .is_some_and(|byte| byte.is_ascii_alphabetic())
            && host.ends_with(':')
        {
            format!("{host}{parsed_path}")
        } else {
            format!("//{host}{parsed_path}")
        };
    }

    if parsed_path.starts_with('/') && is_windows_drive_prefix_at(&parsed_path, 1) {
        parsed_path.remove(0);
    }

    Some((
        urlencoding::decode(&parsed_path)
            .map(|decoded| decoded.into_owned())
            .unwrap_or(parsed_path),
        parsed.fragment().map(|fragment| format!("#{fragment}")),
    ))
}

fn append_position_from_hash(mut path: String, hash: Option<&str>) -> String {
    if has_position_suffix(&path) {
        return path;
    }

    let Some(hash) = hash else {
        return path;
    };
    let Some(position) = hash.strip_prefix("#L") else {
        return path;
    };

    let mut parts = position.split('C');
    let Some(line) = parts.next().filter(|value| digits_only(value)) else {
        return path;
    };
    path.push(':');
    path.push_str(line);

    if let Some(column) = parts.next().filter(|value| digits_only(value)) {
        path.push(':');
        path.push_str(column);
    }

    path
}

fn has_position_suffix(path: &str) -> bool {
    let Some(index) = path.rfind(':') else {
        return false;
    };

    digits_only(&path[index + 1..]) && !is_windows_drive_colon(path, index)
}

fn digits_only(value: &str) -> bool {
    !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
}

fn is_windows_drive_prefix_at(value: &str, index: usize) -> bool {
    value
        .as_bytes()
        .get(index)
        .is_some_and(|byte| byte.is_ascii_alphabetic())
        && value
            .as_bytes()
            .get(index + 1)
            .is_some_and(|byte| *byte == b':')
        && value
            .as_bytes()
            .get(index + 2)
            .is_some_and(|byte| *byte == b'\\' || *byte == b'/')
}

fn is_windows_drive_colon(value: &str, index: usize) -> bool {
    index == 1 && is_windows_drive_prefix_at(value, 0)
}

fn validate_non_empty_value(value: &str, label: &str) -> anyhow::Result<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        anyhow::bail!("{label} cannot be empty.");
    }

    Ok(trimmed.to_string())
}

fn normalize_optional_value(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    })
}

fn normalize_optional_str(value: Option<&str>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    })
}

fn git_ref_exists(workspace_path: &Path, reference: &str) -> anyhow::Result<bool> {
    let output = Command::new("git")
        .args(["show-ref", "--verify", "--quiet", reference])
        .current_dir(workspace_path)
        .output()
        .with_context(|| "Failed to launch git. Make sure git is installed.")?;

    Ok(output.status.success())
}

fn git_command_succeeds(workspace_path: &Path, args: &[&str]) -> anyhow::Result<bool> {
    let output = Command::new("git")
        .args(args)
        .current_dir(workspace_path)
        .output()
        .with_context(|| "Failed to launch git. Make sure git is installed.")?;

    Ok(output.status.success())
}

fn run_git_stdout(
    workspace_path: &Path,
    args: &[&str],
    description: &str,
) -> anyhow::Result<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(workspace_path)
        .output()
        .with_context(|| format!("Failed to launch {description}. Make sure git is installed."))?;

    if output.status.success() {
        let value = output.stdout.as_bstr().trim().to_str_lossy().into_owned();
        if !value.is_empty() {
            return Ok(value);
        }
    }

    let stderr = output.stderr.as_bstr().trim().to_str_lossy().into_owned();
    if !stderr.is_empty() {
        anyhow::bail!("{stderr}");
    }

    anyhow::bail!("{description} failed.")
}

fn create_or_checkout_branch(
    workspace_path: &Path,
    branch_name: &str,
    start_point: Option<&str>,
) -> anyhow::Result<()> {
    run_git_command(
        workspace_path,
        &["check-ref-format", "--branch", branch_name],
        "git check-ref-format",
    )?;

    if git_ref_exists(workspace_path, &format!("refs/heads/{branch_name}"))? {
        run_git_command(workspace_path, &["checkout", branch_name], "git checkout")?;
        return Ok(());
    }

    if let Some(start_point) = start_point {
        run_git_command(
            workspace_path,
            &["checkout", "-b", branch_name, start_point],
            "git checkout -b",
        )?;
    } else {
        run_git_command(
            workspace_path,
            &["checkout", "-b", branch_name],
            "git checkout -b",
        )?;
    }

    Ok(())
}

fn worktree_directory_name(branch_name: &str) -> String {
    branch_name.replace('/', "-")
}

fn canonicalize_existing_path(path: PathBuf) -> anyhow::Result<PathBuf> {
    path.canonicalize()
        .with_context(|| format!("Failed to resolve {}", path.display()))
}

fn run_git_command(workspace_path: &Path, args: &[&str], description: &str) -> anyhow::Result<()> {
    let output = Command::new("git")
        .args(args)
        .current_dir(workspace_path)
        .output()
        .with_context(|| format!("Failed to launch {description}. Make sure git is installed."))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = output.stderr.as_bstr().trim().to_str_lossy().into_owned();
    let stdout = output.stdout.as_bstr().trim().to_str_lossy().into_owned();
    if !stderr.is_empty() {
        anyhow::bail!("{stderr}");
    }
    if !stdout.is_empty() {
        anyhow::bail!("{stdout}");
    }

    anyhow::bail!("{description} failed.")
}
