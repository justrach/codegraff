use crate::dto::{
    AgentsPayloadDto, ChatBindingDto, CommandDescriptorDto, CommandRunResultDto,
    CompleteProviderAuthInput, FollowupResponseDto, HandoffChatInput, McpImportInput,
    McpServerActionInput, McpSettingsPayloadDto, PromptSettingsDto, ProviderAuthSessionDto,
    ProviderSummaryDto, RemoveProviderInput, RuntimeStatusDto, SendPromptInput, SessionSnapshotDto,
    StartProviderAuthInput, UpdatePromptSettingsInput, WorkflowDraftInput, WorkflowDraftPayloadDto,
    WorkspaceQueryInput, WorkspaceSearchPayloadDto, WorkspaceSyncPayloadDto,
};
use crate::runtime::{DesktopState, format_error_chain};
use tauri_plugin_dialog::{DialogExt, FilePath};

#[path = "commands_workspace.rs"]
mod workspace;
pub(crate) use workspace::*;

fn map_command_error(error: anyhow::Error) -> String {
    format_error_chain(&error)
}

#[tauri::command]
pub(crate) async fn pick_workspace(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let selected = app
        .dialog()
        .file()
        .set_title("Open project folder")
        .blocking_pick_folder();

    Ok(selected.and_then(file_path_to_string))
}

#[tauri::command]
pub(crate) async fn pick_directory(
    app: tauri::AppHandle,
    title: Option<String>,
) -> Result<Option<String>, String> {
    let mut dialog = app.dialog().file();
    if let Some(title) = title {
        dialog = dialog.set_title(&title);
    }

    Ok(dialog.blocking_pick_folder().and_then(file_path_to_string))
}

#[tauri::command]
pub(crate) async fn open_workspace(
    path: String,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .open_workspace(path.into())
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn get_runtime_status(
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<RuntimeStatusDto, String> {
    state
        .manager
        .get_runtime_status(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn get_session_snapshot(
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .get_session_snapshot()
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn get_prompt_settings(
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<PromptSettingsDto, String> {
    state
        .manager
        .get_prompt_settings(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn list_providers(
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<Vec<ProviderSummaryDto>, String> {
    state
        .manager
        .list_providers(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn start_provider_auth(
    input: StartProviderAuthInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<ProviderAuthSessionDto, String> {
    state
        .manager
        .start_provider_auth(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn complete_provider_auth(
    input: CompleteProviderAuthInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<ProviderSummaryDto, String> {
    state
        .manager
        .complete_provider_auth(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn remove_provider(
    input: RemoveProviderInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<ProviderSummaryDto, String> {
    state
        .manager
        .remove_provider(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn list_commands(
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<Vec<CommandDescriptorDto>, String> {
    state
        .manager
        .list_commands(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn send_prompt(
    input: SendPromptInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .send_prompt(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn run_slash_command(
    name: String,
    args: Vec<String>,
    workspace_path: Option<String>,
    conversation_id: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<CommandRunResultDto, String> {
    state
        .manager
        .run_command(name, args, workspace_path, conversation_id)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn workspace_sync(
    workspace_path: String,
    state: tauri::State<'_, DesktopState>,
) -> Result<WorkspaceSyncPayloadDto, String> {
    state
        .manager
        .workspace_sync(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn workspace_query(
    input: WorkspaceQueryInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<WorkspaceSearchPayloadDto, String> {
    state
        .manager
        .workspace_query(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn build_workflow_draft(
    input: WorkflowDraftInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<WorkflowDraftPayloadDto, String> {
    state
        .manager
        .build_workflow_draft(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) fn export_workflow_draft(
    draft: WorkflowDraftPayloadDto,
    state: tauri::State<'_, DesktopState>,
) -> String {
    state.manager.export_workflow_draft(draft)
}

#[tauri::command]
pub(crate) async fn set_effort(
    level: String,
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<(), String> {
    state
        .manager
        .set_effort(level, workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn set_fast(
    on: bool,
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<(), String> {
    state
        .manager
        .set_fast(on, workspace_path)
        .await
        .map_err(map_command_error)
}

/// Persists a clipboard-pasted image to a temp file and returns its path, so it
/// can flow through the same attachment pipeline as drag-dropped files (the
/// harness reads image attachments by path). Used by Cmd/Ctrl+V in the composer.
#[tauri::command]
pub(crate) async fn save_pasted_image(data: Vec<u8>, ext: String) -> Result<String, String> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let safe_ext = match ext.to_lowercase().as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "avif" => ext.to_lowercase(),
        _ => "png".to_string(),
    };
    let dir = std::env::temp_dir().join("codegraff-pasted");
    std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    let path = dir.join(format!("paste-{}-{n}.{safe_ext}", std::process::id()));
    std::fs::write(&path, &data).map_err(|error| error.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}

/// Decodes an image, downscales it to fit `max_dim` (default 96px, aspect
/// preserved), and re-encodes it as a compressed JPEG returned as a data URL —
/// so the composer can show a real thumbnail without loading the full file into
/// the webview. Runs the CPU-bound work off the async runtime.
#[tauri::command]
pub(crate) async fn image_thumbnail(path: String, max_dim: Option<u32>) -> Result<String, String> {
    let max = max_dim.unwrap_or(96).clamp(16, 512);
    tokio::task::spawn_blocking(move || {
        use base64::Engine as _;
        let img = image::open(&path).map_err(|error| error.to_string())?;
        // `thumbnail` is a fast box filter that preserves aspect ratio.
        let rgb = img.thumbnail(max, max).to_rgb8();
        let mut buf = std::io::Cursor::new(Vec::new());
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 70)
            .encode_image(&rgb)
            .map_err(|error| error.to_string())?;
        let b64 = base64::engine::general_purpose::STANDARD.encode(buf.get_ref());
        Ok::<String, String>(format!("data:image/jpeg;base64,{b64}"))
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
pub(crate) async fn set_active_agent(
    agent_id: String,
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<AgentsPayloadDto, String> {
    state
        .manager
        .set_active_agent(agent_id, workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn list_mcp_servers(
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<McpSettingsPayloadDto, String> {
    state
        .manager
        .list_mcp_servers(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn import_mcp_config(
    input: McpImportInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<McpSettingsPayloadDto, String> {
    state
        .manager
        .import_mcp_config(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn remove_mcp_server(
    input: McpServerActionInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<McpSettingsPayloadDto, String> {
    state
        .manager
        .remove_mcp_server(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn reload_mcp_servers(
    workspace_path: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<McpSettingsPayloadDto, String> {
    state
        .manager
        .reload_mcp_servers(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn login_mcp_server(
    input: McpServerActionInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<McpSettingsPayloadDto, String> {
    state
        .manager
        .login_mcp_server(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn logout_mcp_server(
    input: McpServerActionInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<McpSettingsPayloadDto, String> {
    state
        .manager
        .logout_mcp_server(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn compact_conversation(
    input: ChatBindingDto,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .compact_conversation(input.workspace_path, input.conversation_id)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn stop_prompt(
    input: ChatBindingDto,
    state: tauri::State<'_, DesktopState>,
) -> Result<(), String> {
    state
        .manager
        .stop_prompt(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn update_prompt_settings(
    input: UpdatePromptSettingsInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<PromptSettingsDto, String> {
    state
        .manager
        .update_prompt_settings(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn select_conversation(
    workspace_path: String,
    conversation_id: String,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .select_conversation(workspace_path, conversation_id)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn ensure_conversation_view(
    workspace_path: String,
    conversation_id: String,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .ensure_conversation_view(workspace_path, conversation_id)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn start_new_chat(
    workspace_path: String,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .start_new_chat(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn create_managed_chat(
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .create_managed_chat()
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn handoff_chat(
    input: HandoffChatInput,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .handoff_chat(input)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn respond_followup(
    response: FollowupResponseDto,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .respond_followup(response)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn archive_conversation(
    workspace_path: String,
    conversation_id: String,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .archive_conversation(workspace_path, conversation_id)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn archive_workspace(
    workspace_path: String,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .archive_workspace(workspace_path)
        .await
        .map_err(map_command_error)
}

#[tauri::command]
pub(crate) async fn rename_workspace(
    workspace_path: String,
    display_name: Option<String>,
    state: tauri::State<'_, DesktopState>,
) -> Result<SessionSnapshotDto, String> {
    state
        .manager
        .rename_workspace(workspace_path, display_name)
        .await
        .map_err(map_command_error)
}

fn file_path_to_string(path: FilePath) -> Option<String> {
    match path {
        FilePath::Path(path) => Some(path.to_string_lossy().into_owned()),
        FilePath::Url(url) => url
            .to_file_path()
            .ok()
            .map(|path| path.to_string_lossy().into_owned())
            .or_else(|| Some(url.to_string())),
    }
}
