use std::path::{Path, PathBuf};

use bstr::ByteSlice;
use similar::TextDiff;
use tokio::fs;

use crate::dto::{ToolCallDetailDto, ToolResultDetailDto};

use super::{PendingFileUpdateState, RuntimeManager};

impl RuntimeManager {
    pub(super) async fn capture_pending_file_update(
        &self,
        conversation_id: &str,
        request_id: &str,
        call_id: Option<&str>,
        detail: &ToolCallDetailDto,
    ) {
        let ToolCallDetailDto::FileUpdate { path, .. } = detail else {
            return;
        };

        let workspace_path = {
            let state = self.state.lock().await;
            let Some(conversation) = state.conversations.get(conversation_id) else {
                return;
            };

            PathBuf::from(&conversation.workspace_path)
        };
        let resolved_path = resolve_file_path(&workspace_path, path);
        let before_text = read_file_text(&resolved_path).await;
        let display_path = display_path_for_patch(&workspace_path, path);

        let mut state = self.state.lock().await;
        let Some(conversation) = state.conversations.get_mut(conversation_id) else {
            return;
        };

        let pending = PendingFileUpdateState {
            before_text,
            display_path,
            path: path.clone(),
            request_id: request_id.to_string(),
            workspace_path,
        };

        if let Some(call_id) = call_id.filter(|call_id| !call_id.is_empty()) {
            conversation
                .pending_file_updates
                .insert(call_id.to_string(), pending);
        } else {
            conversation.pending_anonymous_file_updates.push(pending);
        }
    }

    pub(super) async fn attach_file_diff_to_result(
        &self,
        conversation_id: &str,
        request_id: &str,
        call_id: Option<&str>,
        is_error: bool,
        detail: &mut Option<ToolResultDetailDto>,
    ) {
        let pending = {
            let mut state = self.state.lock().await;
            let Some(conversation) = state.conversations.get_mut(conversation_id) else {
                return;
            };

            if let Some(call_id) = call_id.filter(|call_id| !call_id.is_empty()) {
                conversation.pending_file_updates.remove(call_id)
            } else {
                let pending_index = conversation
                    .pending_anonymous_file_updates
                    .iter()
                    .rposition(|pending| pending.request_id == request_id);

                pending_index.map(|index| conversation.pending_anonymous_file_updates.remove(index))
            }
        };
        let Some(pending) = pending else {
            return;
        };

        if pending.request_id != request_id || is_error {
            return;
        }

        let resolved_path = resolve_file_path(&pending.workspace_path, &pending.path);
        let after_text = read_file_text(&resolved_path).await;
        let Some(patch) = build_file_patch(&pending, after_text.as_deref()) else {
            return;
        };

        *detail = Some(ToolResultDetailDto::FileDiff { path: pending.display_path, patch });
    }
}

fn build_file_patch(pending: &PendingFileUpdateState, after_text: Option<&str>) -> Option<String> {
    let before_text = pending.before_text.as_deref();
    if before_text == after_text {
        return None;
    }

    let old_header = match before_text {
        Some(_) => format!("a/{}", pending.display_path),
        None => "/dev/null".to_string(),
    };
    let new_header = match after_text {
        Some(_) => format!("b/{}", pending.display_path),
        None => "/dev/null".to_string(),
    };
    let diff = TextDiff::from_lines(before_text.unwrap_or(""), after_text.unwrap_or(""));
    let unified = diff
        .unified_diff()
        .context_radius(3)
        .header(&old_header, &new_header)
        .to_string();

    if unified.trim().is_empty() {
        return None;
    }

    let mut patch = String::new();
    patch.push_str(&format!(
        "diff --git a/{path} b/{path}\n",
        path = pending.display_path
    ));

    if before_text.is_none() {
        patch.push_str("new file mode 100644\n");
    } else if after_text.is_none() {
        patch.push_str("deleted file mode 100644\n");
    }

    patch.push_str(&unified);
    Some(patch)
}

fn display_path_for_patch(workspace_path: &Path, path: &str) -> String {
    let raw_path = Path::new(path);
    if raw_path.is_absolute() {
        return raw_path
            .strip_prefix(workspace_path)
            .ok()
            .filter(|path| !path.as_os_str().is_empty())
            .map(normalize_patch_path)
            .unwrap_or_else(|| path.replace('\\', "/"));
    }

    path.replace('\\', "/")
}

async fn read_file_text(path: &Path) -> Option<String> {
    let bytes = fs::read(path).await.ok()?;
    if bytes.contains(&0) {
        return None;
    }

    Some(bytes.as_bstr().to_string())
}

fn resolve_file_path(workspace_path: &Path, path: &str) -> PathBuf {
    let raw_path = Path::new(path);
    if raw_path.is_absolute() {
        return raw_path.to_path_buf();
    }

    workspace_path.join(raw_path)
}

fn normalize_patch_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}
