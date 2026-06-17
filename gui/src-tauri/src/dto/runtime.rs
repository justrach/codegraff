use std::collections::HashSet;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};
use ts_rs::TS;

use super::session::ChatBindingDto;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "RuntimeStatus")]
pub struct RuntimeStatusDto {
    pub workspace_path: Option<String>,
    pub workspace_name: Option<String>,
    pub git_repo_name: Option<String>,
    pub git_branch_name: Option<String>,
    pub git_branches: Vec<String>,
    pub git_workspace_kind: Option<GitWorkspaceKindDto>,
    pub git_main_workspace_path: Option<String>,
    pub available_open_targets: Vec<String>,
    pub configured: bool,
    pub configuration_error: Option<String>,
}

impl RuntimeStatusDto {
    pub fn new(
        workspace_path: Option<&Path>,
        configured: bool,
        configuration_error: Option<String>,
    ) -> Self {
        let git_details = workspace_path.and_then(read_git_workspace_details);

        Self {
            workspace_path: workspace_path.map(|path| path.to_string_lossy().into_owned()),
            workspace_name: workspace_path
                .and_then(|path| path.file_name())
                .map(|name| name.to_string_lossy().into_owned()),
            git_repo_name: git_details
                .as_ref()
                .and_then(|details| details.repo_name.clone()),
            git_branch_name: git_details
                .as_ref()
                .and_then(|details| details.branch_name.clone()),
            git_branches: git_details
                .as_ref()
                .map(|details| details.branch_names.clone())
                .unwrap_or_default(),
            git_workspace_kind: git_details
                .as_ref()
                .and_then(|details| details.workspace_kind.clone()),
            git_main_workspace_path: git_details
                .as_ref()
                .and_then(|details| details.main_workspace_path.clone()),
            available_open_targets: crate::desktop_open::detect_available_open_targets(),
            configured,
            configuration_error,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "GitWorkspaceKind")]
pub enum GitWorkspaceKindDto {
    Local,
    Worktree,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitWorkspaceDetails {
    pub(crate) repo_name: Option<String>,
    pub(crate) branch_name: Option<String>,
    pub(crate) branch_names: Vec<String>,
    pub(crate) workspace_kind: Option<GitWorkspaceKindDto>,
    pub(crate) main_workspace_path: Option<String>,
    pub(crate) workspace_root_path: Option<String>,
    pub(crate) head_commit: Option<String>,
}

pub(crate) fn read_git_workspace_details(workspace_path: &Path) -> Option<GitWorkspaceDetails> {
    let workspace_root_path =
        run_git_raw_command(workspace_path, &["rev-parse", "--show-toplevel"]);
    let head_commit = run_git_raw_command(workspace_path, &["rev-parse", "HEAD"]);
    let repo_name = run_git_command(workspace_path, &["remote", "get-url", "origin"])
        .and_then(|remote_url| parse_git_remote_name(&remote_url));
    let branch_name = run_git_command(workspace_path, &["rev-parse", "--abbrev-ref", "HEAD"])
        .or_else(|| {
            run_git_command(
                workspace_path,
                &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            )
        });
    let local_branch_names = run_git_lines_command(
        workspace_path,
        &["for-each-ref", "--format=%(refname:short)", "refs/heads"],
    )
    .unwrap_or_default();
    let local_branch_name_set = local_branch_names.iter().cloned().collect::<HashSet<_>>();
    let remote_branch_names = run_git_lines_command(
        workspace_path,
        &["for-each-ref", "--format=%(refname:short)", "refs/remotes"],
    )
    .unwrap_or_default()
    .into_iter()
    .filter(|candidate| candidate.contains('/') && !candidate.ends_with("/HEAD"))
    .filter(|candidate| {
        let local_equivalent = candidate
            .split_once('/')
            .map(|(_, remainder)| remainder)
            .unwrap_or(candidate.as_str());
        !local_branch_name_set.contains(local_equivalent)
    })
    .collect::<Vec<_>>();
    let mut seen_branch_names = HashSet::new();
    let branch_names = local_branch_names
        .into_iter()
        .chain(remote_branch_names)
        .filter(|candidate| seen_branch_names.insert(candidate.clone()))
        .collect::<Vec<_>>();
    let main_workspace_path =
        resolve_main_workspace_path(workspace_path, workspace_root_path.as_deref());
    let workspace_kind = match (
        workspace_root_path.as_deref(),
        main_workspace_path.as_deref(),
    ) {
        (Some(workspace_root_path), Some(main_workspace_path))
            if workspace_root_path == main_workspace_path =>
        {
            Some(GitWorkspaceKindDto::Local)
        }
        (Some(_), Some(_)) => Some(GitWorkspaceKindDto::Worktree),
        _ => None,
    };

    if repo_name.is_none()
        && branch_name.is_none()
        && branch_names.is_empty()
        && workspace_kind.is_none()
        && main_workspace_path.is_none()
        && workspace_root_path.is_none()
        && head_commit.is_none()
    {
        return None;
    }

    Some(GitWorkspaceDetails {
        repo_name,
        branch_name,
        branch_names,
        workspace_kind,
        main_workspace_path,
        workspace_root_path,
        head_commit,
    })
}

fn run_git_command(workspace_path: &Path, args: &[&str]) -> Option<String> {
    let mut values = run_git_lines_command(workspace_path, args)?;
    values.retain(|value| value != "HEAD");
    values.into_iter().next()
}

fn run_git_raw_command(workspace_path: &Path, args: &[&str]) -> Option<String> {
    run_git_lines_command(workspace_path, args)?
        .into_iter()
        .next()
}

fn run_git_lines_command(workspace_path: &Path, args: &[&str]) -> Option<Vec<String>> {
    let output = Command::new("git")
        .args(args)
        .current_dir(workspace_path)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let value = String::from_utf8(output.stdout).ok()?;
    let values = value
        .lines()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    if values.is_empty() {
        return None;
    }

    Some(values)
}

fn resolve_main_workspace_path(
    workspace_path: &Path,
    workspace_root_path: Option<&str>,
) -> Option<String> {
    let raw_common_dir = run_git_raw_command(
        workspace_path,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    .or_else(|| run_git_raw_command(workspace_path, &["rev-parse", "--git-common-dir"]))?;
    let common_dir_path = resolve_git_path(workspace_path, workspace_root_path, &raw_common_dir)?;
    let main_workspace_path = common_dir_path.parent()?.to_path_buf();
    canonicalize_or_normalize_path(main_workspace_path)
}

fn resolve_git_path(
    workspace_path: &Path,
    workspace_root_path: Option<&str>,
    raw_path: &str,
) -> Option<std::path::PathBuf> {
    let candidate = std::path::PathBuf::from(raw_path);
    if candidate.is_absolute() {
        return Some(candidate);
    }

    let base_path = workspace_root_path
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| workspace_path.to_path_buf());
    Some(base_path.join(candidate))
}

fn canonicalize_or_normalize_path(path: std::path::PathBuf) -> Option<String> {
    let resolved = path.canonicalize().unwrap_or(path);
    Some(resolved.to_string_lossy().into_owned())
}

fn parse_git_remote_name(remote_url: &str) -> Option<String> {
    let normalized = remote_url
        .trim()
        .trim_end_matches('/')
        .trim_end_matches(".git");
    let path = if let Some((_, remainder)) = normalized.split_once("://") {
        remainder.split_once('/').map(|(_, path)| path)?
    } else if normalized.contains('@') && normalized.contains(':') {
        normalized.rsplit_once(':').map(|(_, path)| path)?
    } else {
        normalized
    };

    let segments = path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>();

    if segments.len() < 2 {
        return None;
    }

    Some(format!(
        "{}/{}",
        segments[segments.len() - 2],
        segments[segments.len() - 1]
    ))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "PromptModelOption")]
pub struct PromptModelOptionDto {
    pub provider_id: String,
    pub provider_name: String,
    pub model_id: String,
    pub model_name: Option<String>,
    pub context_length: Option<u64>,
    pub supports_reasoning: bool,
    pub reasoning_efforts: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "PromptSettings")]
pub struct PromptSettingsDto {
    pub available_models: Vec<PromptModelOptionDto>,
    pub selected_provider_id: Option<String>,
    pub selected_model_id: Option<String>,
    pub selected_reasoning_effort: Option<String>,
    pub fast_enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "UpdatePromptSettingsInput")]
pub struct UpdatePromptSettingsInput {
    pub workspace_path: Option<String>,
    pub provider_id: String,
    pub model_id: String,
    pub reasoning_effort: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "ProviderAuthMethodKind")]
pub enum ProviderAuthMethodKindDto {
    ApiKey,
    OAuthDevice,
    OAuthCode,
    GoogleAdc,
    AwsProfile,
    CodexDevice,
    CodegraffDevice,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ProviderAuthMethod")]
pub struct ProviderAuthMethodDto {
    pub kind: ProviderAuthMethodKindDto,
    pub label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ProviderSummary")]
pub struct ProviderSummaryDto {
    pub id: String,
    pub name: String,
    pub configured: bool,
    pub auth_methods: Vec<ProviderAuthMethodDto>,
    /// Set when the provider is configured via an environment variable, so the
    /// UI can point at where it's defined (the app can't unset an env var).
    pub env_override: Option<ProviderEnvOverrideDto>,
}

/// Where a provider's `<PROVIDER>_API_KEY` environment variable comes from.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ProviderEnvOverride")]
pub struct ProviderEnvOverrideDto {
    /// The environment variable name (e.g. `OPENAI_API_KEY`).
    pub env_key: String,
    /// Shell config file that defines it, if found (e.g. `~/.zshrc`).
    pub file_path: Option<String>,
    /// 1-based line number of the definition, if found.
    pub line: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ProviderUrlParam")]
pub struct ProviderUrlParamDto {
    pub name: String,
    pub value: Option<String>,
    pub options: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ProviderUrlParamValue")]
pub struct ProviderUrlParamValueDto {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "ProviderAuthSessionKind")]
pub enum ProviderAuthSessionKindDto {
    ApiKey,
    DeviceCode,
    CliLogin,
    OAuthCode,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ProviderAuthSession")]
pub struct ProviderAuthSessionDto {
    pub kind: ProviderAuthSessionKindDto,
    pub auth_session_id: String,
    pub requires_api_key: bool,
    pub api_key_hint: Option<String>,
    pub url_parameters: Vec<ProviderUrlParamDto>,
    pub verification_uri: Option<String>,
    pub verification_uri_complete: Option<String>,
    pub user_code: Option<String>,
    pub expires_in_seconds: Option<u64>,
    pub authorization_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ProviderOAuthCallback")]
pub struct ProviderOAuthCallbackDto {
    pub auth_session_id: String,
    pub provider_id: String,
    pub authorization_code: Option<String>,
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "StartProviderAuthInput")]
pub struct StartProviderAuthInput {
    pub workspace_path: Option<String>,
    pub provider_id: String,
    pub auth_method: ProviderAuthMethodKindDto,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CompleteProviderAuthInput")]
pub struct CompleteProviderAuthInput {
    pub auth_session_id: String,
    pub api_key: Option<String>,
    pub authorization_code: Option<String>,
    pub url_parameters: Vec<ProviderUrlParamValueDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "RemoveProviderInput")]
pub struct RemoveProviderInput {
    pub workspace_path: Option<String>,
    pub provider_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
pub struct SendPromptInput {
    pub workspace_path: String,
    pub prompt: String,
    pub conversation_id: Option<String>,
    pub agent_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "ChatHandoffTarget")]
pub enum ChatHandoffTargetDto {
    Local,
    Worktree,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "HandoffChatInput")]
pub struct HandoffChatInput {
    pub source_workspace_path: String,
    pub conversation_id: Option<String>,
    pub target: ChatHandoffTargetDto,
    pub branch_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CloneRepositoryInput")]
pub struct CloneRepositoryInput {
    pub repository_url: String,
    pub parent_directory: String,
    pub directory_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "QuickStartVisibility")]
pub enum QuickStartVisibility {
    Public,
    Private,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "QuickStartProjectInput")]
pub struct QuickStartProjectInput {
    pub project_name: String,
    pub parent_directory: String,
    pub visibility: QuickStartVisibility,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CheckoutGitBranchInput")]
pub struct CheckoutGitBranchInput {
    pub workspace_path: String,
    pub branch_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CreateGitBranchInput")]
pub struct CreateGitBranchInput {
    pub workspace_path: String,
    pub branch_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CommitGitChangesInput")]
pub struct CommitGitChangesInput {
    pub workspace_path: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CreateSavedWorkspaceInput")]
pub struct CreateSavedWorkspaceInput {
    pub chats: Vec<ChatBindingDto>,
    pub layout_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "UpdateSavedWorkspaceLayoutInput")]
pub struct UpdateSavedWorkspaceLayoutInput {
    pub workspace_id: String,
    pub layout_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "SaveConversationLayoutInput")]
pub struct SaveConversationLayoutInput {
    pub conversation_id: String,
    pub layout_json: String,
}
