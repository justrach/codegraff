mod commands;
mod cli_install;
mod desktop_open;
pub mod dto;
mod forge_config_home;
mod runtime;
mod terminal;

mod bridge {
    pub mod emitter;
    // Copied OAuth/tonic follow-up bridge; unused by the simple adapter
    // (graff has no follow-up tool). Retained for future parity.
    #[allow(dead_code)]
    pub mod followup;
}

mod persistence {
    // Some registration/layout helpers are copied but not yet exercised by the
    // simple adapter. Retained for future parity.
    #[allow(dead_code)]
    pub mod project_store;
}

use std::sync::Arc;

use bridge::emitter::TauriEventEmitter;
use commands::{
    archive_conversation, archive_workspace, build_workflow_draft, checkout_git_branch,
    clone_repository, commit_git_changes, compact_conversation, complete_provider_auth,
    create_git_branch, create_managed_chat, create_saved_workspace, delete_saved_workspace,
    ensure_conversation_view, export_workflow_draft, get_conversation_layout, get_prompt_settings,
    get_runtime_status, get_saved_workspace, get_session_snapshot, handoff_chat, import_mcp_config,
    list_commands, list_mcp_servers, list_providers, login_mcp_server, logout_mcp_server,
    open_external_url, open_in_target, open_path_default, open_path_for_edit, open_path_in_target,
    open_workspace,
    pick_directory, pick_workspace, push_git_branch, quick_start_project, read_workspace_file,
    reload_mcp_servers,
    remove_mcp_server, remove_provider, rename_saved_workspace, rename_workspace, respond_followup,
    run_slash_command, save_conversation_layout, select_conversation, send_prompt,
    image_thumbnail, save_pasted_image, set_active_agent, set_effort, set_fast, start_new_chat, start_provider_auth, stop_prompt, terminal_close,
    terminal_open, terminal_resize, terminal_write, update_prompt_settings,
    update_saved_workspace_layout, workspace_query, workspace_sync,
};
use persistence::project_store::ProjectStore;
use runtime::DesktopState;
use tauri::{Emitter, Manager};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    install_rustls_crypto_provider();

    // single-instance must be registered first. A second `codegraff <path>`
    // invocation lands here: open the path in the running window and focus it.
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if let Some(path) = workspace_path_from_args(argv) {
                let _ = app.emit("open-workspace-path", path);
            }
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init());
    #[cfg(debug_assertions)]
    let builder = builder.plugin(
        tauri_plugin_log::Builder::default()
            .level(log::LevelFilter::Info)
            .build(),
    );

    builder
        .setup(|app| {
            let emitter = Arc::new(TauriEventEmitter::new(app.handle().clone()));
            let app_dir = app
                .path()
                .app_data_dir()
                .map_err(|error| anyhow::anyhow!(error.to_string()))?;
            let home_dir = app.path().home_dir().ok();
            forge_config_home::initialize_app_forge_config(&app_dir, home_dir.as_deref())?;
            let projects = Arc::new(ProjectStore::new(
                app_dir.join("projects.db"),
                app_dir.join("managed-chats"),
            )?);
            app.manage(DesktopState::new(emitter, projects));
            // Cold start: stash a `codegraff <path>` arg so the UI opens it once ready.
            app.manage(PendingOpen(std::sync::Mutex::new(workspace_path_from_args(
                std::env::args(),
            ))));
            // First run: install the `codegraff` launcher command on PATH (macOS).
            cli_install::ensure_cli_symlink(app);
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                let manager = window.state::<DesktopState>().manager.clone();
                tauri::async_runtime::spawn(async move {
                    manager.cancel_pending_followups().await;
                });
            }
        })
        .invoke_handler(tauri::generate_handler![
            pick_workspace,
            pick_directory,
            open_workspace,
            get_runtime_status,
            get_session_snapshot,
            get_prompt_settings,
            list_commands,
            list_providers,
            select_conversation,
            ensure_conversation_view,
            start_new_chat,
            create_managed_chat,
            handoff_chat,
            send_prompt,
            compact_conversation,
            run_slash_command,
            workspace_sync,
            workspace_query,
            build_workflow_draft,
            export_workflow_draft,
            set_active_agent,
            set_effort,
            set_fast,
            save_pasted_image,
            image_thumbnail,
            list_mcp_servers,
            import_mcp_config,
            remove_mcp_server,
            reload_mcp_servers,
            login_mcp_server,
            logout_mcp_server,
            stop_prompt,
            update_prompt_settings,
            start_provider_auth,
            complete_provider_auth,
            remove_provider,
            respond_followup,
            archive_conversation,
            archive_workspace,
            rename_workspace,
            clone_repository,
            quick_start_project,
            checkout_git_branch,
            create_git_branch,
            commit_git_changes,
            push_git_branch,
            open_in_target,
            open_path_in_target,
            open_external_url,
            open_path_default,
            open_path_for_edit,
            read_workspace_file,
            save_conversation_layout,
            get_conversation_layout,
            create_saved_workspace,
            update_saved_workspace_layout,
            get_saved_workspace,
            rename_saved_workspace,
            delete_saved_workspace,
            terminal_open,
            terminal_write,
            terminal_resize,
            terminal_close,
            drain_pending_open
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
/// Holds a workspace path passed on the command line before the UI was ready
/// (cold start). The frontend drains it via `drain_pending_open` once mounted.
struct PendingOpen(std::sync::Mutex<Option<String>>);

/// Resolve a `codegraff <path>` argument to an absolute workspace path. Skips
/// the executable (argv[0]) and any leading flags, then takes the first
/// argument that exists on disk and canonicalizes it.
fn workspace_path_from_args<I: IntoIterator<Item = String>>(args: I) -> Option<String> {
    for arg in args.into_iter().skip(1) {
        if arg.starts_with('-') {
            continue;
        }
        if let Ok(abs) = std::fs::canonicalize(&arg) {
            return Some(abs.to_string_lossy().into_owned());
        }
    }
    None
}

/// Hand the UI any path passed to `codegraff <path>` at cold start (consumed once).
#[tauri::command]
fn drain_pending_open(pending: tauri::State<'_, PendingOpen>) -> Option<String> {
    pending.0.lock().ok().and_then(|mut slot| slot.take())
}

fn install_rustls_crypto_provider() {
    if rustls::crypto::CryptoProvider::get_default().is_some() {
        return;
    }

    let _ = rustls::crypto::ring::default_provider().install_default();
}
