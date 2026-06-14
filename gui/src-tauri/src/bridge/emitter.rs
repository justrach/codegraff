use anyhow::Result;
use tauri::Emitter;

use crate::dto::{
    ProviderOAuthCallbackDto, SessionSnapshotDto, TerminalErrorEventDto, TerminalExitEventDto,
    TerminalOutputEventDto,
};

pub const SESSION_UPDATED_EVENT_NAME: &str = "codegraff://session-updated";
pub const TERMINAL_OUTPUT_EVENT_NAME: &str = "codegraff://terminal-output";
pub const TERMINAL_EXIT_EVENT_NAME: &str = "codegraff://terminal-exit";
pub const TERMINAL_ERROR_EVENT_NAME: &str = "codegraff://terminal-error";
pub const PROVIDER_OAUTH_CALLBACK_EVENT_NAME: &str = "codegraff://provider-oauth-callback";

pub trait UiEventEmitter: Send + Sync {
    fn emit_session_updated(&self, payload: SessionSnapshotDto) -> Result<()>;
    fn emit_terminal_output(&self, payload: TerminalOutputEventDto) -> Result<()>;
    fn emit_terminal_exit(&self, payload: TerminalExitEventDto) -> Result<()>;
    fn emit_terminal_error(&self, payload: TerminalErrorEventDto) -> Result<()>;
    fn emit_provider_oauth_callback(&self, payload: ProviderOAuthCallbackDto) -> Result<()>;
}

#[derive(Clone)]
pub struct TauriEventEmitter {
    app: tauri::AppHandle,
}

impl TauriEventEmitter {
    pub fn new(app: tauri::AppHandle) -> Self {
        Self { app }
    }
}

impl UiEventEmitter for TauriEventEmitter {
    fn emit_session_updated(&self, payload: SessionSnapshotDto) -> Result<()> {
        self.app.emit(SESSION_UPDATED_EVENT_NAME, payload)?;
        Ok(())
    }

    fn emit_terminal_output(&self, payload: TerminalOutputEventDto) -> Result<()> {
        self.app.emit(TERMINAL_OUTPUT_EVENT_NAME, payload)?;
        Ok(())
    }

    fn emit_terminal_exit(&self, payload: TerminalExitEventDto) -> Result<()> {
        self.app.emit(TERMINAL_EXIT_EVENT_NAME, payload)?;
        Ok(())
    }

    fn emit_terminal_error(&self, payload: TerminalErrorEventDto) -> Result<()> {
        self.app.emit(TERMINAL_ERROR_EVENT_NAME, payload)?;
        Ok(())
    }

    fn emit_provider_oauth_callback(&self, payload: ProviderOAuthCallbackDto) -> Result<()> {
        self.app.emit(PROVIDER_OAUTH_CALLBACK_EVENT_NAME, payload)?;
        Ok(())
    }
}
